/**
 * 桌面卡片 · 数据服务
 *
 * 桌面上的卡片是**另一个进程**在画：卡片进程里的 FormExtensionAbility 只负责"喂数据"，
 * 所以它拿不到 App 里的任何内存状态 —— 想要什么，只能自己去读那份 Preferences。
 * 这里就是"自己去读"的那段代码，被两边共用：
 *
 *   · form/TodoCardAbility.ets —— 卡片进程，添卡 / 系统定时刷新各算一遍
 *   · App 内（HomePage / EntryAbility）—— 数据一变就主动推一次，让卡片立刻跟上
 *
 * 为什么不让卡片去监听 Preferences 的进程间变更：卡片进程手里的 Preferences 实例
 * 带内存缓存，主进程写完它未必重新读盘。卡片这一侧每次**先清缓存再取**，
 * 代价是每 5 分钟一次读盘，换来"看到的永远是 App 最后一次落盘的样子"。
 * ⚠️ 清缓存只能由卡片进程做 —— App 进程清了会把 BubbleStore 手里那个实例一起作废。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BubbleRecord, LEVEL_URGENT, levelColor } from '../model/BubbleModel';
import { RepeatRule, ruleDueTimeMs, ruleHitsAt } from '../model/RepeatModel';
import { atTimeOfDay, formatTimeHMS, timeOfDayMs, toDateKey } from '../common/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'FormCardService';

/** 与 model/BubbleStore.ets 保持一致 —— 卡片读的就是 App 写的那一份 */
const PREF_NAME: string = 'lingxing_bubble';
const KEY_LIST: string = 'bubble_list';
const KEY_RULES: string = 'repeat_rules';

/** 2×2 的卡片就这么点地方，最多列两条 */
const CARD_SLOTS: number = 2;

/** 已添加到桌面的卡片 formId 清单（放 filesDir，卡片进程与 App 进程共用同一份） */
const FORM_ID_FILE: string = 'form_ids.json';

/** 下次自动刷新间隔（分钟）—— 系统给第三方卡片的硬下限就是 5 */
export const CARD_REFRESH_MINUTES: number = 5;

/** App 进程的 context，init 时挂进来，syncAll 才有得用 */
let appContext: common.Context | undefined = undefined;

/** 卡片上的一条待办（已经排版好，卡片 UI 直接摆） */
export interface CardItem {
  text: string;
  /** 等级色点 */
  color: string;
  /** 副信息：只有"已逾期"和"今天几点截止"才给，其余为空串 */
  note: string;
}

export interface CardSnapshot {
  /** 10/13 周一 */
  dateLabel: string;
  /** 还没办几件 */
  remain: number;
  /** 已经办完几件 */
  done: number;
  items: CardItem[];
}

/** 统计用的中间结构：把「已落库的记录」和「还没物化的循环规则影子」拉齐到同一个形状 */
interface PendingItem {
  text: string;
  level: number;
  dueAt: number;
  seq: number;
}

/** 从 Preferences 里一次读出来的两样东西（合并读，免得清两次缓存） */
interface RawStore {
  records: BubbleRecord[];
  rules: RepeatRule[];
}

/** 喂给卡片的扁平字段 —— 卡片那边只能用 @LocalStorageProp 一个字段一个字段接，所以全部摊平 */
interface CardPayload {
  dateLabel: string;
  remain: string;
  doneText: string;
  emptyText: string;
  /** 有几条列表项（'0' / '1' / '2'，当字符串传，卡片侧比较起来最稳） */
  slotCount: string;
  t0: string;
  c0: string;
  n0: string;
  t1: string;
  c1: string;
  n1: string;
}

const WEEK_CN: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export class FormCardService {

  /** App 进程启动时把自己挂进来 */
  static init(context: common.Context): void {
    appContext = context;
  }

  // ─────────────────────────────────────────────────────────────
  //  喂给卡片的数据
  // ─────────────────────────────────────────────────────────────

  /**
   * 算一份"今天"的快照。
   *
   * @param clearCache 只有**卡片进程**该传 true（清掉 Preferences 内存缓存，强制重新读盘）；
   *                   App 进程一律传 false —— 清了会把 BubbleStore 手里那个实例一并作废。
   */
  private static snapshot(ctx: common.Context, clearCache: boolean): CardSnapshot {
    const now: Date = new Date();
    const todayKey: string = toDateKey(now);
    const store: RawStore = FormCardService.readStore(ctx, clearCache);

    const pending: PendingItem[] = [];
    let done: number = 0;
    let seq: number = 0;

    for (let i = 0; i < store.records.length; i++) {
      const r: BubbleRecord = store.records[i];
      if (r.dateKey !== todayKey) {
        continue;
      }
      if (r.done) {
        done++;
        continue;
      }
      pending.push({
        text: r.text,
        level: r.level === undefined || r.level === null ? 0 : r.level,
        dueAt: r.dueAt === undefined || r.dueAt === null ? 0 : r.dueAt,
        seq: seq
      });
      seq++;
    }

    // 循环任务的泡泡是"App 打开时"物化出来的。今天要是压根没开过 App，
    // 卡片这边就只看得见规则、看不见泡泡 —— 于是补一层**只读的影子**：
    // 命中今天、且这一天的日期还不在 spawnedKeys 里的规则，按"未完成"计入。
    // 只读、不写盘，等 App 真打开时那次物化照旧（幂等）。
    for (let i = 0; i < store.rules.length; i++) {
      const rule: RepeatRule = store.rules[i];
      if (!ruleHitsAt(rule, todayKey)) {
        continue;
      }
      const spawned: string[] = rule.spawnedKeys === undefined || rule.spawnedKeys === null
        ? [] : rule.spawnedKeys;
      if (spawned.indexOf(todayKey) >= 0) {
        continue;
      }
      const level: number = rule.level === undefined || rule.level === null ? 0 : rule.level;
      const dueAt: number = level === LEVEL_URGENT
        ? atTimeOfDay(now, ruleDueTimeMs(rule))
        : 0;
      pending.push({ text: rule.text, level: level, dueAt: dueAt, seq: seq });
      seq++;
    }

    // 紧急的永远排最前，其次谁先到期谁在前，没设截止的按记录顺序垫底
    pending.sort((a: PendingItem, b: PendingItem): number => {
      if (a.level !== b.level) {
        return b.level - a.level;
      }
      const ad: number = a.dueAt > 0 ? a.dueAt : Number.MAX_SAFE_INTEGER;
      const bd: number = b.dueAt > 0 ? b.dueAt : Number.MAX_SAFE_INTEGER;
      if (ad !== bd) {
        return ad - bd;
      }
      return a.seq - b.seq;
    });

    const items: CardItem[] = [];
    const limit: number = pending.length < CARD_SLOTS ? pending.length : CARD_SLOTS;
    for (let i = 0; i < limit; i++) {
      const p: PendingItem = pending[i];
      items.push({
        text: p.text,
        color: levelColor(p.level),
        note: FormCardService.noteOf(p.level, p.dueAt)
      });
    }

    const snap: CardSnapshot = {
      dateLabel: `${now.getMonth() + 1}/${now.getDate()} ${WEEK_CN[now.getDay()]}`,
      remain: pending.length,
      done: done,
      items: items
    };
    return snap;
  }

  /**
   * 副信息：只报两种最要紧的 —— 已逾期、今天几点截止。
   * 泡泡上就是这个规矩，卡片比泡泡还小，明天后天的事不往这儿塞。
   */
  private static noteOf(level: number, dueAt: number): string {
    if (level !== LEVEL_URGENT || dueAt <= 0) {
      return '';
    }
    const now: number = Date.now();
    if (now > dueAt) {
      return '已逾期';
    }
    if (toDateKey(new Date(dueAt)) === toDateKey(new Date(now))) {
      return formatTimeHMS(timeOfDayMs(dueAt)).substring(0, 5);
    }
    return '';
  }

  /**
   * 组装卡片要用的绑定数据。
   *
   * 卡片 UI 那边一个字段一个 @LocalStorageProp 地接，所以这里把所有内容都摊平成字符串，
   * 不传数组、不传对象 —— 卡片进程对复杂类型的支持面比 App 窄，能简单就简单。
   */
  static buildData(ctx: common.Context, clearCache: boolean): formBindingData.FormBindingData {
    const snap: CardSnapshot = FormCardService.snapshot(ctx, clearCache);
    const has0: boolean = snap.items.length > 0;
    const has1: boolean = snap.items.length > 1;

    const payload: CardPayload = {
      dateLabel: snap.dateLabel,
      remain: `${snap.remain}`,
      doneText: snap.done > 0 ? `已完成 ${snap.done}` : '',
      emptyText: snap.remain === 0 && snap.done === 0 ? '今天还没记下什么' : '今天的都办完了',
      slotCount: `${snap.items.length}`,
      t0: has0 ? snap.items[0].text : '',
      c0: has0 ? snap.items[0].color : '#7E8CA0',
      n0: has0 ? snap.items[0].note : '',
      t1: has1 ? snap.items[1].text : '',
      c1: has1 ? snap.items[1].color : '#7E8CA0',
      n1: has1 ? snap.items[1].note : ''
    };
    return formBindingData.createFormBindingData(payload);
  }

  // ─────────────────────────────────────────────────────────────
  //  formId 账本 + App 侧主动推
  // ─────────────────────────────────────────────────────────────

  /** 卡片被加到桌面：记下它，之后 App 里一改数据就能立刻推过去 */
  static recordFormId(ctx: common.Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    const ids: string[] = FormCardService.readFormIds(ctx);
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    FormCardService.writeFormIds(ctx, ids);
  }

  /** 卡片被从桌面拿走 */
  static forgetFormId(ctx: common.Context, formId: string): void {
    const ids: string[] = FormCardService.readFormIds(ctx);
    const kept: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== formId) {
        kept.push(ids[i]);
      }
    }
    FormCardService.writeFormIds(ctx, kept);
  }

  /** 「我的」页进来时问一句：桌面上现在有几张 */
  static installedCount(): number {
    const ctx: common.Context | undefined = appContext;
    if (ctx === undefined) {
      return 0;
    }
    return FormCardService.readFormIds(ctx).length;
  }

  /**
   * App 里数据一变就调这个：把最新快照推给桌面上每一张卡片。
   *
   * 没加过卡片就直接返回（省一次读盘 + 一次数据组装）——
   * 这个函数挂在 persist 那种高频路径上，空转要便宜。
   * 推失败只记日志：卡片可能刚被用户从桌面拖走，下一次 onRemoveForm 会收尾。
   */
  static syncAll(): void {
    const ctx: common.Context | undefined = appContext;
    if (ctx === undefined) {
      return;
    }
    const ids: string[] = FormCardService.readFormIds(ctx);
    if (ids.length === 0) {
      return;
    }
    const data: formBindingData.FormBindingData = FormCardService.buildData(ctx, false);
    for (let i = 0; i < ids.length; i++) {
      const formId: string = ids[i];
      formProvider.updateForm(formId, data).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'updateForm %{public}s failed: %{public}s', formId, JSON.stringify(err));
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  底层读写
  // ─────────────────────────────────────────────────────────────

  private static readStore(ctx: common.Context, clearCache: boolean): RawStore {
    let pref: preferences.Preferences | undefined = undefined;
    if (clearCache) {
      try {
        preferences.removePreferencesFromCacheSync(ctx, { name: PREF_NAME });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'drop cache failed: %{public}s', JSON.stringify(err));
      }
    }
    try {
      pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'open preferences failed: %{public}s', JSON.stringify(err));
      return { records: [], rules: [] };
    }

    const records: BubbleRecord[] = [];
    const rules: RepeatRule[] = [];
    try {
      const rawList: string = pref.getSync(KEY_LIST, '') as string;
      if (rawList.length > 0) {
        const parsed: BubbleRecord[] = JSON.parse(rawList) as BubbleRecord[];
        if (parsed !== undefined && parsed !== null) {
          for (let i = 0; i < parsed.length; i++) {
            records.push(parsed[i]);
          }
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'parse bubble_list failed: %{public}s', JSON.stringify(err));
    }
    try {
      const rawRules: string = pref.getSync(KEY_RULES, '') as string;
      if (rawRules.length > 0) {
        const parsed: RepeatRule[] = JSON.parse(rawRules) as RepeatRule[];
        if (parsed !== undefined && parsed !== null) {
          for (let i = 0; i < parsed.length; i++) {
            rules.push(parsed[i]);
          }
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'parse repeat_rules failed: %{public}s', JSON.stringify(err));
    }
    return { records: records, rules: rules };
  }

  private static readFormIds(ctx: common.Context): string[] {
    const path: string = `${ctx.filesDir}/${FORM_ID_FILE}`;
    try {
      const raw: string = fs.readTextSync(path);
      if (raw.length === 0) {
        return [];
      }
      const parsed: string[] = JSON.parse(raw) as string[];
      return parsed === undefined || parsed === null ? [] : parsed;
    } catch (err) {
      // 文件还不存在 = 桌面上从来没加过卡片，是正常路径，不用报错
      return [];
    }
  }

  private static writeFormIds(ctx: common.Context, ids: string[]): void {
    const path: string = `${ctx.filesDir}/${FORM_ID_FILE}`;
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(ids));
      fs.closeSync(file);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'write form ids failed: %{public}s', JSON.stringify(err));
    }
  }
}
