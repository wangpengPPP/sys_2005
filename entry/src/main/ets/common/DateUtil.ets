/**
 * 日期工具
 *
 * 「零星小记」按天分页：每一天是一页，各有各的没办和办完。
 * 这里只做三件事：把一天压成一个键、把一天写成人能看的标题、按天偏移。
 */

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** 只要年月日，丢掉时分秒 —— 同一天必须得到同一个键 */
export function dateOnly(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/** 今天的零点 */
export function todayDate(): Date {
  return dateOnly(new Date());
}

/** 存储键：2026-10-10 */
export function toDateKey(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 反向：2026-10-10 → 本地零点 Date；格式不对时退回今天，绝不返回 Invalid Date */
export function fromDateKey(key: string): Date {
  const parts: string[] = key.split('-');
  if (parts.length !== 3) {
    return todayDate();
  }
  const y: number = Number.parseInt(parts[0], 10);
  const m: number = Number.parseInt(parts[1], 10);
  const d: number = Number.parseInt(parts[2], 10);
  if (Number.isNaN(y) || Number.isNaN(m) || Number.isNaN(d)) {
    return todayDate();
  }
  return new Date(y, m - 1, d);
}

const WEEK_CN: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/** 人看的标题：10月10日 周六 */
export function formatDateTitle(d: Date): string {
  return `${d.getMonth() + 1}月${d.getDate()}日 ${WEEK_CN[d.getDay()]}`;
}

/** 是不是今天 */
export function isToday(d: Date): boolean {
  return toDateKey(d) === toDateKey(new Date());
}

/** 按天偏移，返回新的 Date（不修改传入对象） */
export function shiftDay(d: Date, delta: number): Date {
  const n: Date = dateOnly(d);
  n.setDate(n.getDate() + delta);
  return n;
}

/**
 * 某一天的最后一刻（23:59:59.999）。
 * 用作「没特意挑时刻」时的兜底截止 —— 说"15 号截止"，就是 15 号一整天都还算数。
 */
export function endOfDay(d: Date): Date {
  const n: Date = dateOnly(d);
  n.setHours(23, 59, 59, 999);
  return n;
}

/** 一天的最后毫秒偏移（23:59:59.999 距当天零点）—— 没挑时刻时的默认值 */
export const DAY_END_MS: number = 86399999;

/**
 * 「时刻」在这里统一表示成**距当天零点的毫秒偏移**（0 ~ 86399999），而不是时间戳。
 *
 * 这么做是为了让循环规则说得通：「每天 9:00 截止」里的 9:00 是个**每天复用的时刻**，
 * 配到一个具体日期上才算得出时间戳。存时间戳的话，规则第二天就过期了。
 */
export function timeOfDayMs(ts: number): number {
  const d: Date = new Date(ts);
  return ((d.getHours() * 60 + d.getMinutes()) * 60 + d.getSeconds()) * 1000 + d.getMilliseconds();
}

/** 把某一天的零点与一个时刻拼成时间戳 */
export function atTimeOfDay(day: Date, ms: number): number {
  return dateOnly(day).getTime() + ms;
}

/** 时刻 → 14:30:00 */
export function formatTimeHMS(ms: number): string {
  const total: number = Math.max(0, Math.floor(ms / 1000));
  const h: number = Math.floor(total / 3600) % 24;
  const m: number = Math.floor(total / 60) % 60;
  const s: number = total % 60;
  return `${pad2(h)}:${pad2(m)}:${pad2(s)}`;
}

/** 时间戳 → 14:30:00（只取时刻那一段） */
export function formatClockHMS(ts: number): string {
  return formatTimeHMS(timeOfDayMs(ts));
}

/** 截止文案：今天 / 明天 / 10月15日 / 2027年3月2日 */
export function formatDueLabel(ts: number): string {
  if (ts <= 0) {
    return '无';
  }
  const d: Date = new Date(ts);
  const now: Date = new Date();
  const key: string = toDateKey(d);
  if (key === toDateKey(now)) {
    return '今天';
  }
  if (key === toDateKey(shiftDay(now, 1))) {
    return '明天';
  }
  if (d.getFullYear() === now.getFullYear()) {
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

/** 到截止那天的最后一刻为止，过了就算逾期 */
export function isOverdue(dueAt: number): boolean {
  return dueAt > 0 && Date.now() > dueAt;
}

/** 截止就落在今天 */
export function isDueToday(dueAt: number): boolean {
  return dueAt > 0 && toDateKey(new Date(dueAt)) === toDateKey(new Date());
}

/**
 * 时间戳 → 人读的时刻：今天 14:32 / 昨天 09:05 / 10月12日 14:32
 *
 * 只用在「详细信息」卡片上。老数据（以及首次启动的示例数据）createdAt 是 0，
 * 那种一律显示一个短横，不要甩出个 1970 年吓人。
 */
export function formatClockTime(ts: number): string {
  if (ts <= 0) {
    return '—';
  }
  const d: Date = new Date(ts);
  const hm: string = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  const key: string = toDateKey(d);
  const now: Date = new Date();
  if (key === toDateKey(now)) {
    return `今天 ${hm}`;
  }
  if (key === toDateKey(shiftDay(now, -1))) {
    return `昨天 ${hm}`;
  }
  return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
}
