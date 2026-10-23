/**
 * 零星小记 · 状态栏投递服务
 *
 * 这个文件解决一个很实际的问题：
 * **「实况窗」要 AGC 权益才亮，但用户现在就想在状态栏看到待办。**
 *
 * 所以做成双通道，自动降级：
 *
 *   ┌ 用户打开开关
 *   │
 *   ├─ ① 试实况窗（@kit.LiveViewKit）── 成功 ─→ 状态栏胶囊「灵动岛」✅
 *   │                                    失败
 *   └─ ② 退到常驻通知（@ohos.notificationManager）─→ 通知中心常驻卡片 ✅
 *
 * 常驻通知**不需要任何申请**，装了就能用，只是形态不如胶囊灵动。
 * 等 AGC 权益批下来，同一个开关会自动升级成真灵动岛，不用改任何东西。
 *
 * 另外：两个通道不会同时开 —— 实况窗亮了就把通知撤掉，避免用户看两条重复信息。
 */

import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bubble } from '../../model/BubbleModel';
import { BubbleStore } from '../../model/BubbleStore';
import { toDateKey, todayDate } from '../../common/DateUtil';
import { LiveViewBridge, LiveViewPayload, LiveViewProbe } from './LiveViewBridge';

const DOMAIN: number = 0x0000;
const TAG: string = 'StatusBar';

/** 哪个通道在干活 */
export enum StatusChannel {
  /** 开关关着 */
  OFF = 0,
  /** 真·灵动岛 */
  LIVE_VIEW = 1,
  /** 兜底：常驻通知 */
  NOTIFY = 2
}

/** 通知 id，固定 */
const NOTIFY_ID: number = 20261010;
const PREF_NAME: string = 'lingxing_status_bar';
const KEY_SWITCH: string = 'enabled';

/** 给 UI 读的状态（AppStorage 键） */
export const STATUS_CHANNEL_KEY: string = 'statusBarChannel';
export const STATUS_TEXT_KEY: string = 'statusBarText';

export class StatusBarService {
  private static context: common.UIAbilityContext | null = null;
  private static prefs: preferences.Preferences | null = null;
  private static switchOn: boolean = false;
  private static channel: StatusChannel = StatusChannel.OFF;
  /** 上一次成功推送的内容指纹，内容没变就不重复打扰系统 */
  private static lastFingerprint: string = '';

  static init(context: common.UIAbilityContext): void {
    StatusBarService.context = context;
    LiveViewBridge.init(context);
    try {
      StatusBarService.prefs = preferences.getPreferencesSync(context, { name: PREF_NAME });
      StatusBarService.switchOn = StatusBarService.prefs.getSync(KEY_SWITCH, false) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open pref failed: %{public}s', JSON.stringify(err));
      StatusBarService.switchOn = false;
    }
    StatusBarService.publishState();
  }

  // ────────────────────────────────────────────────────────────
  //  开关
  // ────────────────────────────────────────────────────────────

  static isOn(): boolean {
    return StatusBarService.switchOn;
  }

  /** 打开/关闭。打开时会异步去点亮，返回后 UI 读 AppStorage 看结果 */
  static setOn(on: boolean): void {
    StatusBarService.switchOn = on;
    const p: preferences.Preferences | null = StatusBarService.prefs;
    if (p !== null) {
      try {
        p.putSync(KEY_SWITCH, on);
        p.flush();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'save switch failed: %{public}s', JSON.stringify(err));
      }
    }
    if (on) {
      StatusBarService.refresh();
    } else {
      StatusBarService.clear();
    }
  }

  // ────────────────────────────────────────────────────────────
  //  投递
  // ────────────────────────────────────────────────────────────

  /**
   * 按当前数据重算一次状态栏内容。
   * 泡泡增删、勾完一件、切日期之后都该调一次。
   */
  static refresh(): void {
    if (!StatusBarService.switchOn) {
      StatusBarService.publishState();
      return;
    }
    const payload: LiveViewPayload = StatusBarService.buildPayload();
    // 内容没变就别折腾系统
    const fingerprint: string = `${payload.title}|${payload.content}|${payload.capsuleTitle}`;
    if (fingerprint === StatusBarService.lastFingerprint
      && StatusBarService.channel !== StatusChannel.OFF) {
      return;
    }
    StatusBarService.lastFingerprint = fingerprint;

    StatusBarService.deliver(payload).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'deliver failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 先试灵动岛，不行就退通知 */
  private static async deliver(p: LiveViewPayload): Promise<void> {
    try {
      const probe: LiveViewProbe = await LiveViewBridge.probe(false);
      if (probe.supported && probe.enabled) {
        await LiveViewBridge.push(p);
        // 点亮成功 → 撤掉可能残留的常驻通知，避免两条重复
        await StatusBarService.cancelNotify();
        StatusBarService.channel = StatusChannel.LIVE_VIEW;
        StatusBarService.publishState('已开启 · 状态栏胶囊');
        return;
      }
      hilog.info(DOMAIN, TAG, 'live view unavailable: %{public}s', probe.message);
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'live view push failed, fallback to notification');
    }
    // 降级：常驻通知（不需要任何申请）
    const sent: boolean = await StatusBarService.pushNotify(p);
    StatusBarService.channel = sent ? StatusChannel.NOTIFY : StatusChannel.OFF;
    StatusBarService.publishState(sent ? '已开启 · 常驻通知（实况窗待开通）' : '通知未授权');
  }

  /** 全部收掉 */
  static clear(): void {
    StatusBarService.lastFingerprint = '';
    LiveViewBridge.stop().catch(() => {});
    StatusBarService.cancelNotify().catch(() => {});
    StatusBarService.channel = StatusChannel.OFF;
    StatusBarService.publishState();
  }

  // ────────────────────────────────────────────────────────────
  //  内容生成：从今天的泡泡算出"要显示什么"
  // ────────────────────────────────────────────────────────────

  private static buildPayload(): LiveViewPayload {
    const list: Bubble[] = BubbleStore.loadDate(toDateKey(todayDate()));
    const todo: Bubble[] = [];
    for (let i = 0; i < list.length; i++) {
      if (!list[i].done) {
        todo.push(list[i]);
      }
    }

    const total: number = list.length;
    const left: number = todo.length;

    // ① 全空
    if (total === 0) {
      return {
        title: '今天还没记什么',
        content: '想起来了就点开记一句',
        lockScreen: '今天还是空的',
        capsuleTitle: '空',
        capsuleContent: '今天还没记什么'
      };
    }

    // ② 全做完
    if (left === 0) {
      return {
        title: '今天都做完了',
        content: `一共 ${total} 件，一件没落下`,
        lockScreen: `今天 ${total} 件事全部完成`,
        capsuleTitle: '✓ 完成',
        capsuleContent: '今天的都做完了'
      };
    }

    // ③ 还有没做的
    const preview: string = StatusBarService.joinPreview(todo);
    return {
      title: `还有 ${left} 件没做`,
      content: preview,
      lockScreen: `还有 ${left} 件：${preview}`,
      // 胶囊能显示的字很少，只放数字
      capsuleTitle: `${left} 件`,
      capsuleContent: preview
    };
  }

  /** 把待办文字拼成一行预览，最多 3 条，超出用「等」收尾 */
  private static joinPreview(todo: Bubble[]): string {
    const max: number = 3;
    const parts: string[] = [];
    const n: number = todo.length < max ? todo.length : max;
    for (let i = 0; i < n; i++) {
      parts.push(todo[i].text);
    }
    let s: string = parts.join(' · ');
    if (todo.length > max) {
      s += ` 等 ${todo.length} 件`;
    }
    return s;
  }

  // ────────────────────────────────────────────────────────────
  //  兜底通道：常驻通知
  // ────────────────────────────────────────────────────────────

  private static async pushNotify(p: LiveViewPayload): Promise<boolean> {
    const ctx: common.UIAbilityContext | null = StatusBarService.context;
    if (ctx === null) {
      return false;
    }
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        // 拉一次授权弹窗；用户拒了就安静退出
        await notificationManager.requestEnableNotification(ctx);
      }

      const bundle: string = ctx.abilityInfo.bundleName;
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: bundle, abilityName: 'EntryAbility' } as Want],
        operationType: wantAgent.OperationType.START_ABILITIES,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };

      const request: notificationManager.NotificationRequest = {
        id: NOTIFY_ID,
        // 同一 id 重复 publish 是"更新"，所以不会堆一堆，也不用担心刷屏
        //
        // 这里**故意不指定 slotType**：
        //   · slotType 字段要求的是 @ohos.notification 里的旧 SlotType，而那个枚举
        //     整体自 API 9 起 deprecated；notificationManager.SlotType 是另一个类型，
        //     塞进去编译不过。为这个常驻提醒去引一个废弃 API 不划算。
        //   · 不指定时通知走系统默认槽 —— 恰恰是我们要的：安静地待在通知中心，
        //     不响铃、不弹横幅（待办是"提醒自己"，不是"被人呼叫"）。
        //   · 顺带说一句，SlotType.LIVE_VIEW 第三方也用不了，SDK 原话是
        //     "A third-party application cannot directly create a notification of this type"。
        isOngoing: true,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: p.title,
            text: p.content,
            additionalText: '零星小记'
          }
        },
        wantAgent: await wantAgent.getWantAgent(agentInfo)
      };

      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, 'notification published');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'publish notification failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private static async cancelNotify(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFY_ID);
    } catch (err) {
      // 本来就没有，忽略
    }
  }

  // ────────────────────────────────────────────────────────────
  //  给 UI 看的状态
  // ────────────────────────────────────────────────────────────

  private static publishState(override?: string): void {
    let text: string = '未开启';
    if (StatusBarService.switchOn) {
      if (override !== undefined) {
        text = override;
      } else if (StatusBarService.channel === StatusChannel.LIVE_VIEW) {
        text = '已开启 · 状态栏胶囊';
      } else if (StatusBarService.channel === StatusChannel.NOTIFY) {
        text = '已开启 · 常驻通知（实况窗待开通）';
      } else {
        text = '点一下启用';
      }
    }
    AppStorage.setOrCreate<number>(STATUS_CHANNEL_KEY, StatusBarService.channel as number);
    AppStorage.setOrCreate<string>(STATUS_TEXT_KEY, text);
  }

  /**
   * 「我的」页点开关时，想顺便告诉用户"为什么没变成灵动岛"。
   * 返回一句解释。
   */
  static async explainChannel(): Promise<string> {
    if (!StatusBarService.switchOn) {
      return '';
    }
    const probe: LiveViewProbe = await LiveViewBridge.probe(true);
    if (probe.supported && probe.enabled) {
      return '灵动岛已点亮';
    }
    return probe.message;
  }
}
