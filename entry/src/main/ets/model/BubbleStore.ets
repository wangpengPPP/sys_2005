import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bubble, BubbleRecord, LEVEL_URGENT, buildSeedRecords, createBubble, toRecord } from './BubbleModel';
import { RepeatRule, ruleDueTimeMs, ruleHitsAt } from './RepeatModel';
import { atTimeOfDay, DAY_END_MS, fromDateKey, toDateKey } from '../common/DateUtil';

const DOMAIN: number = 0x0001;
const TAG: string = 'BubbleStore';
const PREF_NAME: string = 'lingxing_bubble';
const KEY_LIST: string = 'bubble_list';
const KEY_RULES: string = 'repeat_rules';

/**
 * 零星小记 · 本地存储（Preferences）
 *
 * 全部记录放在一条 JSON 里，每条带自己的 dateKey（YYYY-MM-DD），
 * 页面按日期取哪一天的那一批 —— 一天一页，翻页就是换一批泡泡。
 *
 * 存的是极简记录（文字 + 是否完成 + 属于哪天），坐标速度这类物理状态不落盘，
 * 每次切页重新散布，反而更像"倒出来的一把泡泡"。
 *
 * 循环规则也放在这里（同一份 Preferences 的另一个键）：
 * 规则是"多久来一次"，泡泡是"当天那一枚"，规则按天物化成泡泡（见 materialize）。
 * 两者放在一个 store 里，是为了让 loadDate 能顺手完成物化——
 * 少一次调用就少一个"忘了调"的坑。
 */
export class BubbleStore {
  private static pref: preferences.Preferences | undefined = undefined;
  private static ready: boolean = false;
  /** 内存里的全量记录（所有日期） */
  private static records: BubbleRecord[] = [];
  /** 内存里的全部循环规则 */
  private static rules: RepeatRule[] = [];

  static init(context: common.Context): void {
    if (BubbleStore.ready) {
      return;
    }
    try {
      BubbleStore.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      BubbleStore.ready = true;
      BubbleStore.records = BubbleStore.readAll();
      BubbleStore.rules = BubbleStore.readRules();
      BubbleStore.publishCounts(BubbleStore.records);
      hilog.info(DOMAIN, TAG, 'BubbleStore ready, %{public}d records, %{public}d rules',
        BubbleStore.records.length, BubbleStore.rules.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 读盘；首次启动（或数据损坏）时把示例数据撒在今天 */
  private static readAll(): BubbleRecord[] {
    const pref: preferences.Preferences | undefined = BubbleStore.pref;
    const todayKey: string = toDateKey(new Date());
    if (!BubbleStore.ready || pref === undefined) {
      return buildSeedRecords(todayKey);
    }
    try {
      const raw: string = pref.getSync(KEY_LIST, '') as string;
      if (raw.length === 0) {
        const seeds: BubbleRecord[] = buildSeedRecords(todayKey);
        BubbleStore.writeAll(seeds);
        return seeds;
      }
      const parsed: BubbleRecord[] = JSON.parse(raw) as BubbleRecord[];
      // 兼容早期数据：缺什么补什么，老记录一律当"自己记的、算在今天"
      for (let i = 0; i < parsed.length; i++) {
        const r: BubbleRecord = parsed[i];
        if (r.dateKey === undefined || r.dateKey === null || r.dateKey.length === 0) {
          r.dateKey = todayKey;
        }
        if (r.fromUid === undefined || r.fromUid === null) {
          r.fromUid = '';
        }
        if (r.fromName === undefined || r.fromName === null) {
          r.fromName = '';
        }
        if (r.remoteId === undefined || r.remoteId === null) {
          r.remoteId = '';
        }
        if (r.level === undefined || r.level === null) {
          r.level = 0;
        }
        if (r.repeat === undefined || r.repeat === null) {
          r.repeat = 0;
        }
        if (r.weekdays === undefined || r.weekdays === null) {
          r.weekdays = 0;
        }
        if (r.ruleId === undefined || r.ruleId === null) {
          r.ruleId = '';
        }
        if (r.dueAt === undefined || r.dueAt === null) {
          r.dueAt = 0;
        }
      }
      return parsed;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(err));
      return buildSeedRecords(todayKey);
    }
  }

  /** 取某一天的泡泡（先把当天该出现的循环规则物化出来） */
  static loadDate(dateKey: string): Bubble[] {
    BubbleStore.materialize(dateKey);
    const list: Bubble[] = [];
    for (let i = 0; i < BubbleStore.records.length; i++) {
      const r: BubbleRecord = BubbleStore.records[i];
      if (r.dateKey === dateKey) {
        list.push(createBubble(r));
      }
    }
    return list;
  }

  /**
   * 某一天还欠几件事 —— 给日历打角标用。
   *
   * **只读，刻意不物化**。日历一翻就是几十天，如果顺手把命中的循环规则
   * 全物化成泡泡，等于替用户在未来铺了一地数据：累计记录数会被冲高，
   * 那些他根本没见过的日期也凭空多出记录。所以这里只做"如果翻到这天，
   * 会有几件没办完"的推算：
   *
   *   · 已存在的记录：没完成的照数；
   *   · 还没物化的循环规则：命中这天就算一件（物化后它会变成上面那种记录，
   *     所以两条路径不会重复计数）；
   *   · 规则命中过但泡泡被用户删了（spawnedKeys 里有）：不再算 —— 与
   *     "删掉今天的泡泡，今天不会自动复活"的语义保持一致。
   */
  static pendingCountOf(dateKey: string): number {
    let n: number = 0;
    for (let i = 0; i < BubbleStore.records.length; i++) {
      const r: BubbleRecord = BubbleStore.records[i];
      if (!r.done && r.dateKey === dateKey) {
        n++;
      }
    }
    for (let i = 0; i < BubbleStore.rules.length; i++) {
      const rule: RepeatRule = BubbleStore.rules[i];
      if (!ruleHitsAt(rule, dateKey)) {
        continue;
      }
      const spawned: string[] = rule.spawnedKeys;
      if (spawned === undefined || spawned === null || spawned.indexOf(dateKey) < 0) {
        n++;
      }
    }
    return n;
  }

  // ─────────────────────────────────────────────────────────────
  //  循环规则 → 当天泡泡（按天物化）
  // ─────────────────────────────────────────────────────────────

  /**
   * 把「命中这一天、且还没在这一天生成过」的规则落成当天的泡泡。
   *
   * 幂等：spawnedKeys 记着已经生成过的日期，重复调用不会多冒泡泡；
   * 删除语义：用户删掉今天那枚泡泡后，spawnedKeys 里仍有今天 → 不会复活。
   * 返回值 = 本次新生成的泡泡（调用方想"就地让它冒出来"时用得上）。
   */
  static materialize(dateKey: string): Bubble[] {
    const created: Bubble[] = [];
    let changed: boolean = false;
    for (let i = 0; i < BubbleStore.rules.length; i++) {
      const rule: RepeatRule = BubbleStore.rules[i];
      if (!ruleHitsAt(rule, dateKey)) {
        continue;
      }
      if (rule.spawnedKeys === undefined || rule.spawnedKeys === null) {
        rule.spawnedKeys = [];
      }
      if (rule.spawnedKeys.indexOf(dateKey) >= 0) {
        continue;
      }
      // 紧急的循环任务：截止 = 这一天的零点 + 规则里挑好的时刻。
      // 「每天 9:00 截止」于是每天都落在那天的 9:00；规则里只存时刻，日期由 dateKey 给。
      const dueAt: number = rule.level === LEVEL_URGENT
        ? atTimeOfDay(fromDateKey(dateKey), ruleDueTimeMs(rule))
        : 0;
      const record: BubbleRecord = {
        id: BubbleStore.nextId(),
        text: rule.text,
        done: false,
        createdAt: Date.now(),
        dateKey: dateKey,
        fromUid: '',
        fromName: '',
        remoteId: '',
        level: rule.level,
        repeat: rule.mode,
        weekdays: rule.weekdays,
        ruleId: `${rule.id}`,
        dueAt: dueAt
      };
      BubbleStore.records.push(record);
      rule.spawnedKeys.push(dateKey);
      created.push(createBubble(record));
      changed = true;
    }
    if (changed) {
      BubbleStore.writeAll(BubbleStore.records);
      BubbleStore.writeRules(BubbleStore.rules);
    }
    return created;
  }

  /** 全部循环规则（「我的」页与设置用） */
  static loadRules(): RepeatRule[] {
    return BubbleStore.rules;
  }

  /**
   * 所有"还没办完、设了截止、且截止还没到"的紧急记录，**截止最近的排最前**。
   *
   * 给截止提醒用的：这些才是需要登记系统提醒的条目。
   * 已经办完的不提（做完了还催什么），截止已经过的不提
   * （系统提醒是给未来某个时刻登记的，过去的登记不了）。
   *
   * 跨日期扫全量 —— 明天的紧急任务今晚就该提醒，不能只看今天。
   */
  static pendingUrgent(now: number): BubbleRecord[] {
    const list: BubbleRecord[] = [];
    for (let i = 0; i < BubbleStore.records.length; i++) {
      const r: BubbleRecord = BubbleStore.records[i];
      if (r.done || r.level !== LEVEL_URGENT) {
        continue;
      }
      if (r.dueAt === undefined || r.dueAt === null || r.dueAt <= now) {
        continue;
      }
      list.push(r);
    }
    list.sort((a: BubbleRecord, b: BubbleRecord) => a.dueAt - b.dueAt);
    return list;
  }

  /** 新加一条规则，返回它的 id */
  static addRule(rule: RepeatRule): void {
    BubbleStore.rules.push(rule);
    BubbleStore.writeRules(BubbleStore.rules);
  }

  /** 删掉一条规则，并把它物化出来、还没被完成的泡泡一并清掉（还没办的才清） */
  static removeRule(ruleId: number): void {
    const kept: RepeatRule[] = [];
    for (let i = 0; i < BubbleStore.rules.length; i++) {
      if (BubbleStore.rules[i].id !== ruleId) {
        kept.push(BubbleStore.rules[i]);
      }
    }
    BubbleStore.rules = kept;

    const keptRecords: BubbleRecord[] = [];
    for (let i = 0; i < BubbleStore.records.length; i++) {
      const r: BubbleRecord = BubbleStore.records[i];
      if (r.ruleId === `${ruleId}` && !r.done) {
        continue;
      }
      keptRecords.push(r);
    }
    BubbleStore.records = keptRecords;

    BubbleStore.writeRules(BubbleStore.rules);
    BubbleStore.writeAll(BubbleStore.records);
  }

  /** 下一条规则的 id */
  static nextRuleId(): number {
    let maxId: number = 0;
    for (let i = 0; i < BubbleStore.rules.length; i++) {
      if (BubbleStore.rules[i].id > maxId) {
        maxId = BubbleStore.rules[i].id;
      }
    }
    return maxId + 1;
  }

  private static readRules(): RepeatRule[] {
    const pref: preferences.Preferences | undefined = BubbleStore.pref;
    if (!BubbleStore.ready || pref === undefined) {
      return [];
    }
    try {
      const raw: string = pref.getSync(KEY_RULES, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const parsed: RepeatRule[] = JSON.parse(raw) as RepeatRule[];
      // 早期规则没有 startKey / spawnedKeys，补上默认值，避免物化时判空崩掉
      for (let i = 0; i < parsed.length; i++) {
        const r: RepeatRule = parsed[i];
        if (r.startKey === undefined || r.startKey === null) {
          r.startKey = '0000-00-00';
        }
        if (r.spawnedKeys === undefined || r.spawnedKeys === null) {
          r.spawnedKeys = [];
        }
        if (r.level === undefined || r.level === null) {
          r.level = 0;
        }
        // 早期规则没有「截止时刻」：留 0，读取时按当天末尾兜底（ruleDueTimeMs）
        if (r.dueTimeMs === undefined || r.dueTimeMs === null
          || r.dueTimeMs < 0 || r.dueTimeMs > DAY_END_MS) {
          r.dueTimeMs = DAY_END_MS;
        }
      }
      return parsed;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load rules failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  private static writeRules(rules: RepeatRule[]): void {
    const pref: preferences.Preferences | undefined = BubbleStore.pref;
    if (!BubbleStore.ready || pref === undefined) {
      return;
    }
    try {
      pref.putSync(KEY_RULES, JSON.stringify(rules));
      pref.flushSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'persist rules failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 用某一天最新的泡泡覆盖存储里该天的部分，其余日期原样保留。
   * 按日期整体替换，就不必去 diff 增删改。
   */
  static saveDate(dateKey: string, bubbles: Bubble[]): void {
    const merged: BubbleRecord[] = [];
    for (let i = 0; i < BubbleStore.records.length; i++) {
      const r: BubbleRecord = BubbleStore.records[i];
      if (r.dateKey !== dateKey) {
        merged.push(r);
      }
    }
    for (let i = 0; i < bubbles.length; i++) {
      const b: Bubble = bubbles[i];
      b.dateKey = dateKey;
      merged.push(toRecord(b));
    }
    BubbleStore.records = merged;
    BubbleStore.writeAll(merged);
  }

  private static writeAll(records: BubbleRecord[]): void {
    BubbleStore.publishCounts(records);
    const pref: preferences.Preferences | undefined = BubbleStore.pref;
    if (!BubbleStore.ready || pref === undefined) {
      return;
    }
    try {
      pref.putSync(KEY_LIST, JSON.stringify(records));
      pref.flushSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(err));
    }
  }

  private static publishCounts(records: BubbleRecord[]): void {
    let completed: number = 0;
    for (let i = 0; i < records.length; i++) {
      if (records[i].done) { completed++; }
    }
    AppStorage.setOrCreate<number>('bubbleTotalCount', records.length);
    AppStorage.setOrCreate<number>('bubbleCompletedCount', completed);
  }

  /** 下一个可用 id（跨所有日期唯一） */
  static nextId(): number {
    let maxId: number = 0;
    for (let i = 0; i < BubbleStore.records.length; i++) {
      if (BubbleStore.records[i].id > maxId) {
        maxId = BubbleStore.records[i].id;
      }
    }
    return maxId + 1;
  }
}
