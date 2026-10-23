/**
 * 零星小记 · 截止提醒
 *
 * 紧急任务在截止前连提 7 次醒：
 *   3 小时 · 1 小时 · 30 分钟 · 10 分钟 · 5 分钟 · 3 分钟 · 1 分钟
 *
 * ── 为什么用「后台代理提醒」而不是自己起定时器 ──
 *
 * 应用内的 setTimeout / 定时器在 App 退到后台或被清理之后就不走了，
 * 而截止提醒恰恰最需要在"你没打开 App"的时候响。
 * `reminderAgentManager` 是把提醒**托管给系统**：登记完就可以退出，
 * 到点由系统弹通知，和 App 死活无关。这是不需要服务端推送的前提下，
 * 唯一能做到"关掉 App 也会提醒"的本地方案。
 *
 * ── 关于实况窗 ──
 *
 * 实况窗（LiveView）表达的是"持续存在的状态"（打车还有几分钟到、外卖在哪），
 * 它不是"定点打扰"的机制，而且第三方要 AGC 权益才亮。定时提醒这件事本来就该走通知。
 *
 * ── 失效策略：全量重算 ──
 *
 * 每次数据一变，先把本应用登记的提醒**全部撤掉**，再按当前数据重新登记一遍。
 * 不做增量 diff —— 提醒是"登记一次就托管出去"的东西，谁在系统里活着我们并不完全掌握，
 * 全量重算最不容易留下孤儿提醒（比如任务删了、提醒还在响）。
 */

import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BubbleRecord } from '../model/BubbleModel';
import { BubbleStore } from '../model/BubbleStore';
import { formatDueLabel } from '../common/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'DeadlineReminder';

/**
 * 截止前的提前量台阶（毫秒），**从远到近**。
 * 顺序就是用户列举的顺序，也决定了额度不够时谁先被登记 ——
 * 远的先来，保证每条任务至少拿到足够的提前量，而不是只剩最后 1 分钟。
 */
const LEAD_STEPS_MS: number[] = [
  3 * 60 * 60 * 1000,
  60 * 60 * 1000,
  30 * 60 * 1000,
  10 * 60 * 1000,
  5 * 60 * 1000,
  3 * 60 * 1000,
  60 * 1000
];

/** 台阶对应的中文，写进通知正文 */
const LEAD_LABELS: string[] = ['3 小时', '1 小时', '30 分钟', '10 分钟', '5 分钟', '3 分钟', '1 分钟'];

/**
 * 本应用能登记的提醒条数上限。
 * 系统对第三方应用有硬上限（超了报 1700002），取 28 留出余量。
 * 一条紧急任务最多占 7 条，所以同时能完整覆盖 4 条紧急任务；
 * 再多的话，靠上面的"从远到近"顺序保证每条都拿到最早的几档提醒。
 */
const MAX_REMINDERS: number = 28;

/**
 * 提醒通知的 notificationId 前缀。
 * 避开状态栏常驻通知的 id（20261010），两者不会互相覆盖。
 */
const NOTIFY_ID_BASE: number = 3000000;

/**
 * 登记结果（人话），给「我的」页显示。
 *
 * 为什么要把它露出来：提醒是托管给系统的，登记完看不见摸不着，
 * 而"提醒到底有没有生效"要等好几个小时才验证得了。
 * 把条数摆出来，用户当场就能确认，不用干等。
 */
export const DEADLINE_REMINDER_KEY: string = 'deadlineReminderText';

export class DeadlineReminderService {
  private static context: common.UIAbilityContext | null = null;
  /** 包名，构造"点通知回到 App"的目标时要用 */
  private static bundleName: string = '';
  /** 上一次同步时的内容指纹，没变就整个跳过 */
  private static lastFingerprint: string = '';
  /** 正在跑一轮全量重算 */
  private static busy: boolean = false;
  /** 排队中：跑的过程中数据又变了 */
  private static queued: boolean = false;

  static init(context: common.UIAbilityContext): void {
    DeadlineReminderService.context = context;
    DeadlineReminderService.bundleName = context.abilityInfo.bundleName;
    // 清掉指纹，保证本次启动第一次 sync 一定真的跑一遍
    // （系统里的提醒可能被清过，靠重算补齐）
    DeadlineReminderService.lastFingerprint = '';
  }

  // ────────────────────────────────────────────────────────────
  //  入口
  // ────────────────────────────────────────────────────────────

  /**
   * 按当前数据重算全部截止提醒。
   * 泡泡增删、勾完成、切天之后调一次就够 —— 内部先撤旧再登新。
   */
  static sync(): void {
    if (DeadlineReminderService.context === null) {
      return;
    }
    const fingerprint: string = DeadlineReminderService.buildFingerprint();
    if (fingerprint === DeadlineReminderService.lastFingerprint) {
      return;
    }
    DeadlineReminderService.lastFingerprint = fingerprint;
    DeadlineReminderService.queued = true;
    if (DeadlineReminderService.busy) {
      return;
    }
    DeadlineReminderService.busy = true;
    DeadlineReminderService.run();
  }

  /** 串行泵：一轮跑完如果期间又变了，接着再跑一轮（用的是最新数据） */
  private static async run(): Promise<void> {
    while (DeadlineReminderService.queued) {
      DeadlineReminderService.queued = false;
      await DeadlineReminderService.apply();
    }
    DeadlineReminderService.busy = false;
  }

  /**
   * 内容指纹：只由"哪几条紧急任务、各自几点截止"决定。
   * 用它挡住那些频繁但无意义的调用（拖一下泡泡就会触发一次 persist）。
   */
  private static buildFingerprint(): string {
    const records: BubbleRecord[] = BubbleStore.pendingUrgent(Date.now());
    const parts: string[] = [];
    for (let i = 0; i < records.length; i++) {
      parts.push(`${records[i].id}@${records[i].dueAt}`);
    }
    return parts.join(',');
  }

  // ────────────────────────────────────────────────────────────
  //  全量重算
  // ────────────────────────────────────────────────────────────

  private static async apply(): Promise<void> {
    const ctx: common.UIAbilityContext | null = DeadlineReminderService.context;
    if (ctx === null) {
      return;
    }
    // 没授权就先要授权 —— 否则 publishReminder 直接报 1700001，一声不响
    await DeadlineReminderService.ensureNotifyEnabled(ctx);

    await DeadlineReminderService.cancelAll();

    const now: number = Date.now();
    const pending: BubbleRecord[] = BubbleStore.pendingUrgent(now);
    if (pending.length === 0) {
      hilog.info(DOMAIN, TAG, 'no upcoming urgent task, nothing scheduled');
      DeadlineReminderService.publishState('暂无带截止的紧急任务');
      return;
    }

    let count: number = 0;
    let attempted: number = 0;
    let quotaFull: boolean = false;

    // 外层走台阶（从远到近）、内层走任务（截止最近的在最前）：
    // 额度不够时，每条任务先拿到"提前量最大"的那几档
    for (let s = 0; s < LEAD_STEPS_MS.length && !quotaFull; s++) {
      const lead: number = LEAD_STEPS_MS[s];
      for (let i = 0; i < pending.length; i++) {
        if (count >= MAX_REMINDERS) {
          hilog.info(DOMAIN, TAG, 'reminder quota reached (%{public}d), rest skipped', MAX_REMINDERS);
          quotaFull = true;
          break;
        }
        const rec: BubbleRecord = pending[i];
        const at: number = rec.dueAt - lead;
        // 这个提前量已经过去了 —— 现在建任务时很常见（离截止不足 3 小时）
        if (at <= now) {
          continue;
        }
        attempted++;
        const ok: boolean = await DeadlineReminderService.schedule(rec, at, LEAD_LABELS[s]);
        if (ok) {
          count++;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'scheduled %{public}d reminders for %{public}d urgent task(s)',
      count, pending.length);

    // 把结果翻成一句人话，让用户当场能确认（而不是等几小时去撞）
    if (count > 0) {
      const nearest: string = formatDueLabel(pending[0].dueAt);
      DeadlineReminderService.publishState(`${pending.length} 件 · 已登记 ${count} 条 · 最近 ${nearest}`);
    } else if (attempted === 0) {
      DeadlineReminderService.publishState(`${pending.length} 件 · 截止太近，来不及提醒`);
    } else {
      DeadlineReminderService.publishState(`${pending.length} 件 · 登记失败，检查通知权限`);
    }
  }

  private static publishState(text: string): void {
    AppStorage.setOrCreate<string>(DEADLINE_REMINDER_KEY, text);
  }

  /** 登记一条提醒。时刻已经算好（绝对时间戳） */
  private static async schedule(rec: BubbleRecord, at: number, leadLabel: string): Promise<boolean> {
    const d: Date = new Date(at);
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        // LocalDateTime 的月份是 1~12，不是 Date 的 0~11
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: d.getSeconds()
      },
      title: rec.text,
      content: `还有 ${leadLabel} 就到截止`,
      expiredContent: '截止时间已经过了',
      // 点通知回到 App。
      // 注意这里用的**不是** wantAgent.getWantAgent() 那个句柄 ——
      // reminderAgentManager 自带了同名但结构不同的 WantAgent（就俩字段：
      // pkgName + abilityName），SDK 只认这一个，塞句柄进去类型对不上。
      wantAgent: {
        pkgName: DeadlineReminderService.bundleName,
        abilityName: 'EntryAbility'
      },
      // 同一件事的 7 条提醒共用一个 notificationId：
      // 后一条弹出来时会顶掉前一条，通知中心不会被同一件事刷屏
      notificationId: NOTIFY_ID_BASE + rec.id,
      tapDismissed: true
    };

    try {
      const id: number = await reminderAgentManager.publishReminder(req);
      hilog.info(DOMAIN, TAG, 'reminder %{public}d set: bubble %{public}d, %{public}s before due',
        id, rec.id, leadLabel);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 1700001 通知没开 / 1700002 条数超限 / 201 没权限
      hilog.warn(DOMAIN, TAG, 'publish failed (code=%{public}d): %{public}s', e.code, e.message);
      return false;
    }
  }

  private static async cancelAll(): Promise<void> {
    try {
      // 本应用只用代理提醒做截止提醒，全撤是安全的
      await reminderAgentManager.cancelAllReminders();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'cancelAllReminders failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 通知没授权时拉一次系统弹窗；用户拒了就安静退出（publish 会失败，日志里有） */
  private static async ensureNotifyEnabled(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(ctx);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'request notification enable failed: %{public}s', JSON.stringify(err));
    }
  }
}
