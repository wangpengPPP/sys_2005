/**
 * 零星小记 · 实况窗（灵动岛）桥接层
 *
 * 鸿蒙把 iOS 那个「灵动岛」叫**实况窗（Live View）**，能力在 @kit.LiveViewKit。
 * 一个实况窗能同时出现在三个地方：
 *   - 状态栏胶囊（就是"岛"本身）→ 对应下面 payload 里的 capsule
 *   - 通知中心卡片
 *   - 锁屏卡片                    → 这两处对应 primary
 *
 * ⚠️ 必须先说清楚的一件事：**这不是"代码写完就能亮"的功能。**
 * 实况窗要先在 AppGallery Connect 开通权益，官方文档写得明白：
 *   · 调试阶段 —— 走「白名单设备」（把设备 Push Token 加进去，24 小时内生效），
 *     白名单设备**不做本地构建的权益校验**，所以能先看到效果；
 *   · 正式对外 —— 要求「应用已上架 **且月活 ≥ 1000**」才能点申请按钮。
 * 所以本文件只保证"调用姿势正确"，能不能亮由 AGC 说了算。
 * 调不通时，错误码会被翻成能看懂的中文（见 explain()）。
 */

import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, Want, WantAgent, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'LiveView';

/**
 * 实况窗 ID：自己定的，用来标识"这一条实况窗"。
 * 固定一个常数即可 —— 小记同时只会有一条实况窗。
 */
const LIVE_VIEW_ID: number = 20261010;

/**
 * 场景取值。官方只认这 15 个：
 * TAXI 打车 / DELIVERY 即时配送 / FLIGHT 航班 / TRAIN 火车 / QUEUE 排队 /
 * PICK_UP 取餐 / SCORE 比分 / RENT 共享租赁 / TIMER 计时 /
 * WORKOUT 运动 / NAVIGATION 导航 / CHECK_IN 打卡 / EXPRESS 快递 /
 * PROGRESS 进度 / TRADE 交易
 *
 * 待办提醒严格说不在这个列表里，最接近的是 TIMER（计时）。
 * 官方文档把 TIMER 标为「仅端侧」—— 只支持本地创建，不支持 Push 下发，
 * 这和我们的做法（本地更新，没有服务端）刚好对上。
 *
 * 👉 等你从 AGC 拿到批下来的场景后，**只需要改这一行**。
 * 取的值必须和申请时填的场景一致，否则实况窗会被判定为不合法而不显示。
 */
const LIVE_EVENT: string = 'TIMER';

/** 实况窗内容（和 UI 无关的纯数据，方便上层复用） */
export interface LiveViewPayload {
  /** 卡片主标题，如「今天 3 件事没做」 */
  title: string;
  /** 卡片正文，如「买苹果 · 取快递 · 带伞」 */
  content: string;
  /** 锁屏/通知中心的完整版正文 */
  lockScreen: string;
  /** 胶囊主文案（越短越好，官方建议中文字符 ≤3 个） */
  capsuleTitle: string;
  /** 胶囊副文案（展开后才看得到的补充） */
  capsuleContent: string;
}

/** 探测结果 */
export interface LiveViewProbe {
  /** 当前设备 + SDK 是否具备实况窗能力 */
  supported: boolean;
  /** 是否真的能亮（用户开关 + AGC 权益都满足） */
  enabled: boolean;
  /** 给人看的一句话结论 */
  message: string;
}

export class LiveViewBridge {
  private static context: common.UIAbilityContext | null = null;
  private static clickAgent: WantAgent | null = null;
  /** 版本号必须严格递增，否则报 1003500011 */
  private static sequence: number = 0;
  /** 当前是否有活着的实况窗，避免重复 start 报 1003500006 */
  private static alive: boolean = false;
  /** 上次探测结果，省得每次刷新都去问系统 */
  private static lastProbe: LiveViewProbe | null = null;

  static init(context: common.UIAbilityContext): void {
    LiveViewBridge.context = context;
  }

  // ────────────────────────────────────────────────────────────
  //  能力探测
  // ────────────────────────────────────────────────────────────

  /**
   * 先问系统：这台设备、这个应用，能不能亮实况窗。
   * 任何一步抛错都视为"不能"，并把错误码翻成人话。
   */
  static async probe(force: boolean): Promise<LiveViewProbe> {
    const cached: LiveViewProbe | null = LiveViewBridge.lastProbe;
    if (!force && cached !== null) {
      return cached;
    }

    let result: LiveViewProbe;
    try {
      const ok: boolean = await liveViewManager.isLiveViewEnabled();
      result = {
        supported: true,
        enabled: ok,
        message: ok ? '已开启 · 状态栏胶囊' : '系统未开启实况窗'
      };
    } catch (err) {
      result = {
        supported: false,
        enabled: false,
        message: LiveViewBridge.explain(err)
      };
    }
    LiveViewBridge.lastProbe = result;
    return result;
  }

  /**
   * 错误码 → 人话。
   * 这套码表取自本机 SDK 的 @hms.core.liveview.liveViewManager.d.ts：
   *   1003500004 LiveView is not enabled
   *   1003500005 The right of liveView is not enabled   ← 没开通 AGC 权益，最常见
   *   1003500006 already exists
   *   1003500011 sequence is incorrect
   */
  static explain(err: Object): string {
    const e: BusinessError = err as BusinessError;
    const code: number = e.code;
    if (code === 1003500004) {
      return '实况窗开关未打开（设置 → 通知 → 实况窗）';
    }
    if (code === 1003500005) {
      return '未开通实况窗权益，需在 AGC 申请';
    }
    if (code === 1003500006) {
      return '实况窗已存在，请先关掉再开';
    }
    if (code === 1003500011) {
      return '更新序号错乱，重新打开一次即可';
    }
    if (code === 801) {
      return '本机不支持实况窗';
    }
    const msg: string = e.message === undefined ? '' : e.message;
    return `实况窗不可用（${code}${msg.length > 0 ? ' ' + msg : ''}）`;
  }

  // ────────────────────────────────────────────────────────────
  //  创建 / 更新 / 结束
  // ────────────────────────────────────────────────────────────

  /** 内容结构完全一致，所以"首次创建"和"后续更新"共用一份构造逻辑 */
  private static async build(id: number, seq: number, p: LiveViewPayload): Promise<liveViewManager.LiveView> {
    const view: liveViewManager.LiveView = {
      id: id,
      event: LIVE_EVENT,
      sequence: seq,
      // 待办不是即时消息，别响铃震动
      isMute: true,
      // 进程被杀时自动收起，不留孤儿卡片
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: {
        primary: {
          title: p.title,
          content: [{ text: p.content }],
          // 结束后在通知中心再留 30 秒，给一眼回看的机会
          keepTime: 30,
          clickAction: await LiveViewBridge.buildClickAction()
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          // status: 1 显示、-1 结束
          status: 1,
          title: p.capsuleTitle,
          content: p.capsuleContent,
          backgroundColor: '#FF5B6EF5',
          isContentDisplayed: true
        }
      }
    };
    return view;
  }

  /** 点实况窗 → 回到 App */
  private static async buildClickAction(): Promise<WantAgent> {
    const cached: WantAgent | null = LiveViewBridge.clickAgent;
    if (cached !== null) {
      return cached;
    }
    const ctx: common.UIAbilityContext | null = LiveViewBridge.context;
    const bundle: string = ctx === null ? '' : ctx.abilityInfo.bundleName;

    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: bundle, abilityName: 'EntryAbility' } as Want],
      operationType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    LiveViewBridge.clickAgent = agent;
    return agent;
  }

  /**
   * 把内容推上状态栏。
   * 已经在亮 → 走 updateLiveView；还没亮 → 走 startLiveView。
   * 返回 true 表示"内容确实送出去了"。
   */
  static async push(p: LiveViewPayload): Promise<boolean> {
    try {
      LiveViewBridge.sequence += 1;
      const view: liveViewManager.LiveView =
        await LiveViewBridge.build(LIVE_VIEW_ID, LiveViewBridge.sequence, p);

      let result: liveViewManager.LiveViewResult;
      if (LiveViewBridge.alive) {
        result = await liveViewManager.updateLiveView(view);
      } else {
        result = await liveViewManager.startLiveView(view);
      }
      LiveViewBridge.alive = true;
      hilog.info(DOMAIN, TAG, 'live view pushed, resultCode=%{public}d', result.resultCode);
      // resultCode 非 0 表示某个分区被系统拒了，但整体还在，算成功
      return true;
    } catch (err) {
      LiveViewBridge.alive = false;
      // 已经亮着却报"已存在" —— 说明是我们状态没同步，纠正一下下次走 update
      const e: BusinessError = err as BusinessError;
      if (e.code === 1003500006) {
        LiveViewBridge.alive = true;
      }
      hilog.warn(DOMAIN, TAG, 'push live view failed: %{public}s', LiveViewBridge.explain(err));
      throw err as Error;
    }
  }

  /** 收起实况窗（用户关开关、或今天待办清空时） */
  static async stop(): Promise<void> {
    if (!LiveViewBridge.alive) {
      return;
    }
    try {
      LiveViewBridge.sequence += 1;
      const view: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        event: LIVE_EVENT,
        sequence: LiveViewBridge.sequence,
        liveViewData: {
          primary: {
            title: '今日待办已清空',
            content: [{ text: '点开看看，或者休息一下' }],
            keepTime: 10
          }
        }
      };
      await liveViewManager.stopLiveView(view);
      hilog.info(DOMAIN, TAG, 'live view stopped');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stop live view failed: %{public}s', LiveViewBridge.explain(err));
    }
    LiveViewBridge.alive = false;
    LiveViewBridge.lastProbe = null;
  }

  /** 当前是否有实况窗在亮 */
  static isAlive(): boolean {
    return LiveViewBridge.alive;
  }
}
