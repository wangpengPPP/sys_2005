/**
 * 零星小记 · 循环规则
 *
 * 有些事不是"今天要做一次"，而是"每天都要"：吃药、遛狗、打卡。
 * 这里不引入日程表，只加一条极简规则：
 *
 *   一条规则 = 一句话 + 多久一次（每天 / 每周的哪几天）+ 重要程度
 *
 * 规则本身不会直接变成泡泡，而是**按天物化**：
 * 翻到某一天时，命中的规则才生成当天那枚泡泡。好处是——
 *   · 昨天没做的那条不会堆积到今天来烦你（一天一页的语义保持一致）
 *   · 未来的日期翻过去也是对的，不需要定时任务提前铺数据
 *
 * 每个规则记着 spawnedKeys：已经生成过泡泡的日期。
 * 靠它做到「删掉今天的泡泡后，今天不会再自动冒出来」。
 */

import { DAY_END_MS, fromDateKey } from '../common/DateUtil';

/** 不重复（记一次就完了） */
export const REPEAT_NONE: number = 0;
/** 每天 */
export const REPEAT_DAILY: number = 1;
/** 每周指定星期几 */
export const REPEAT_WEEKLY: number = 2;

/** 星期位掩码：下标 0=周一 … 6=周日，与界面从左到右的顺序一致 */
export const WEEK_BITS: number[] = [1, 2, 4, 8, 16, 32, 64];
/** 界面上的星期标签，周一在最左 */
export const WEEK_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/**
 * 一条循环规则
 */
export interface RepeatRule {
  id: number;
  text: string;
  /** 重要程度，与 BubbleModel 的 LEVEL_* 同一套 */
  level: number;
  /** REPEAT_DAILY / REPEAT_WEEKLY */
  mode: number;
  /** 位掩码，仅 mode = REPEAT_WEEKLY 时有意义 */
  weekdays: number;
  createdAt: number;
  /**
   * 从哪一天开始生效（YYYY-MM-DD）。
   * 建规则的当天就是它的起点 —— 因此翻回上周三不会突然冒出"每天吃药"。
   */
  startKey: string;
  /**
   * 紧急任务的截止**时刻**（距当天零点的毫秒偏移，0 ~ 86399999）。
   *
   * 存时刻而不是时间戳，是因为"每天 9:00 截止"里的 9:00 是个**每天复用**的点；
   * 物化到某一天时，用那天的零点 + 这个偏移才得到真正的时间戳。
   * 未设（非紧急，或早期数据）时按当天末尾算。
   */
  dueTimeMs: number;
  /** 已经物化过泡泡的日期键，防止重复生成、也让"删掉后当天不复活"成立 */
  spawnedKeys: string[];
}

/** 规则生效的截止时刻；没设过就退回"当天末尾"，与旧行为一致 */
export function ruleDueTimeMs(rule: RepeatRule): number {
  const t: number = rule.dueTimeMs;
  if (t === undefined || t === null || t < 0 || t > DAY_END_MS) {
    return DAY_END_MS;
  }
  return t;
}

/** 周几：以周一为一周第一天，返回 0(周一) ~ 6(周日) */
export function weekdayIndexMonFirst(d: Date): number {
  return (d.getDay() + 6) % 7;
}

/**
 * 规则版本号（AppStorage 键）。
 * 主页新建规则、我的页删规则时都 +1，
 * 让「我的」页那张规则清单和主页上的泡泡能立刻跟着变，不用切 Tab 才刷新。
 */
export const REPEAT_VERSION_KEY: string = 'repeatRuleVersion';

/**
 * 这条规则在 dateKey 这一天该不该出现。
 * 用字符串比较判断先后 —— YYYY-MM-DD 的字典序就是时间序。
 */
export function ruleHitsAt(rule: RepeatRule, dateKey: string): boolean {
  if (dateKey < rule.startKey) {
    return false;
  }
  if (rule.mode === REPEAT_DAILY) {
    return true;
  }
  if (rule.mode === REPEAT_WEEKLY) {
    const bit: number = WEEK_BITS[weekdayIndexMonFirst(fromDateKey(dateKey))];
    return (rule.weekdays & bit) !== 0;
  }
  return false;
}

/** 人能读的循环文案：每天 / 周一·三·五 / 每周（没选具体日子时） */
export function repeatText(mode: number, weekdays: number): string {
  if (mode === REPEAT_DAILY) {
    return '每天';
  }
  if (mode === REPEAT_WEEKLY) {
    const parts: string[] = [];
    for (let i = 0; i < WEEK_BITS.length; i++) {
      if ((weekdays & WEEK_BITS[i]) !== 0) {
        parts.push(WEEK_LABELS[i]);
      }
    }
    if (parts.length === 0) {
      return '每周';
    }
    return `周${parts.join('·')}`;
  }
  return '';
}

/** 建规则时的简写。dueTimeMs 只在紧急时才有意义，不紧急时传 0 */
export function createRule(id: number, text: string, level: number,
  mode: number, weekdays: number, startKey: string,
  dueTimeMs: number): RepeatRule {
  const rule: RepeatRule = {
    id: id,
    text: text,
    level: level,
    mode: mode,
    weekdays: weekdays,
    createdAt: Date.now(),
    startKey: startKey,
    dueTimeMs: dueTimeMs,
    spawnedKeys: []
  };
  return rule;
}
