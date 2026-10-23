/**
 * 零星小记 · 数据模型
 *
 * 设计前提：这不是笔记，是「提示」。
 * 一条内容 = 几个字，没有标题、正文、时间、分类。
 * 它唯一要解决的问题是：看见这个词，你就想起那件事。
 *
 * 例：老婆说「下班买个苹果」，你只记「买苹果」三个字。
 *     三个字看见就想起来了，剩下的细节本来就在你脑子里。
 *
 * 来源有两种：
 *   - 自己记的：fromUid 为空
 *   - 好友发来的：fromUid / fromName 有值，remoteId 是服务端消息号（用来去重）
 */

import { endOfDay } from '../common/DateUtil';

/** 持久化记录：只存本质信息，物理状态（坐标/速度）每次启动重新生成 */
export interface BubbleRecord {
  id: number;
  text: string;
  done: boolean;
  createdAt: number;
  /** 属于哪一天（YYYY-MM-DD）：一天一页，跨天互不干扰 */
  dateKey: string;
  /** 好友发来的待办：发送者 uid；自己记的为空串 */
  fromUid: string;
  /** 发送者昵称，显示在泡泡里 */
  fromName: string;
  /** 服务端消息 id：同一条好友待办只收一次；自己记的为空串 */
  remoteId: string;
  /** 重要程度：0 普通 / 1 重要 / 2 紧急（见 LEVEL_*） */
  level: number;
  /** 重复方式：0 不重复 / 1 每天 / 2 每周指定星期（见 REPEAT_*） */
  repeat: number;
  /** 重复的星期位掩码（bit0=周一 … bit6=周日），仅 repeat=2 有意义 */
  weekdays: number;
  /** 由哪条循环规则物化而来（空串 = 手动记的）。删规则时按它连坐清理 */
  ruleId: string;
  /**
   * 截止时间戳（0 = 不设）。
   * 只有「紧急」才谈得上截止：不重复时由用户自己选一天，
   * 每天 / 每周则自动落在这枚泡泡所属那一天的末尾（见 BubbleStore.materialize）。
   */
  dueAt: number;
  /** 附带照片：应用沙箱里的绝对路径；可选，老数据没有这一项时按空串处理 */
  photo?: string;
}

/**
 * 泡泡：既是列表数据，也是物理实体。
 *
 * 用 @Observed 装饰，是为了让物理引擎逐帧改坐标时，
 * 只有对应那一个泡泡组件重绘，而不是整页重建。
 */
@Observed
export class Bubble {
  // ---- 持久化字段 ----
  id: number = 0;
  text: string = '';
  done: boolean = false;
  createdAt: number = 0;
  dateKey: string = '';
  /** 好友发来的：对方 uid；自己记的空串 */
  fromUid: string = '';
  /** 好友昵称 */
  fromName: string = '';
  /** 服务端消息 id */
  remoteId: string = '';
  /** 重要程度：0 普通 / 1 重要 / 2 紧急 */
  level: number = 0;
  /** 重复方式：0 不重复 / 1 每天 / 2 每周指定星期 */
  repeat: number = 0;
  /** 星期位掩码，仅 repeat=2 有意义 */
  weekdays: number = 0;
  /** 来自哪条循环规则（空串 = 手动记的） */
  ruleId: string = '';
  /** 截止时间戳，0 = 不设（见 BubbleRecord.dueAt） */
  dueAt: number = 0;
  /** 附带照片的沙箱路径，空串 = 没附图 */
  photo: string = '';

  // ---- 运行时物理状态（不落盘） ----
  /** 圆心坐标（vp），相对所在区域的左上角 */
  cx: number = 0;
  cy: number = 0;
  /** 速度（vp/s） */
  vx: number = 0;
  vy: number = 0;
  /** 半径（vp） */
  r: number = 34;
  /** 是否已经投放到区域里（首帧才做随机散布，之后不再重置） */
  placed: boolean = false;
  /** 正被手指拖着走：物理引擎让位，位置完全交给手势 */
  dragging: boolean = false;
  /**
   * 正被「详细信息」卡片指着。
   * 放在模型里而不是 BubbleView 的入参上，是因为 BubbleView 的普通入参
   * 只在创建时取一次值，父组件事后改了不会同步过来；
   * 而 @ObjectLink 监听的是 Bubble 自身字段，改完这一颗立刻重绘。
   */
  focused: boolean = false;
  /**
   * 正在向上发射（未完成区按住触发）。
   * 飞行中以极快速度冲出本区顶部，飞到对面区域后由 HomePage 接管改状态。
   */
  flying: boolean = false;
  /** 泡泡壁的虹彩底色，按 id 稳定取色 */
  tint: string = '#8AB4FF';

  // ---- 所在区域的物理边界（由布局回调注入） ----
  boundLeft: number = 0;
  boundTop: number = 0;
  boundRight: number = 0;
  boundBottom: number = 0;
}

/** 泡泡壁的虹彩色板，模拟肥皂泡的薄膜干涉色 */
const TINTS: string[] = [
  '#7FA9FF',
  '#FFA8C6',
  '#8FE0C0',
  '#FFD08A',
  '#BCA6FA',
  '#8FD4F0'
];

/** 按内容长度决定泡泡半径：字越多泡越大 */
export function bubbleRadius(text: string): number {
  const n: number = text.length;
  if (n <= 2) {
    return 32;
  }
  if (n <= 4) {
    return 36;
  }
  if (n <= 6) {
    return 40;
  }
  return 44;
}

/** 按内容长度决定字号 */
export function bubbleFontSize(text: string): number {
  const n: number = text.length;
  if (n <= 2) {
    return 17;
  }
  if (n <= 4) {
    return 15;
  }
  return 13;
}

/** 记录 → 泡泡实体 */
export function createBubble(record: BubbleRecord): Bubble {
  const b: Bubble = new Bubble();
  b.id = record.id;
  b.text = record.text;
  b.done = record.done;
  b.createdAt = record.createdAt;
  b.dateKey = record.dateKey;
  // 早期版本没有来源字段，这里兜一层，老数据一律当"自己记的"
  b.fromUid = record.fromUid === undefined ? '' : record.fromUid;
  b.fromName = record.fromName === undefined ? '' : record.fromName;
  b.remoteId = record.remoteId === undefined ? '' : record.remoteId;
  // 重要程度与循环：老数据没有这几个字段，一律兜成"普通 + 不重复"
  b.level = record.level === undefined ? LEVEL_NORMAL : record.level;
  b.repeat = record.repeat === undefined ? 0 : record.repeat;
  b.weekdays = record.weekdays === undefined ? 0 : record.weekdays;
  b.ruleId = record.ruleId === undefined || record.ruleId === null ? '' : record.ruleId;
  // 截止：老数据没有这个字段，一律当"没设"
  b.dueAt = record.dueAt === undefined || record.dueAt === null ? 0 : record.dueAt;
  // 照片：老数据（或循环规则物化出来的）没有这一项，一律当"没附图"
  b.photo = record.photo === undefined || record.photo === null ? '' : record.photo;
  b.r = bubbleRadius(record.text);
  b.tint = TINTS[Math.abs(record.id) % TINTS.length];
  return b;
}

/** 泡泡实体 → 记录（落盘用） */
export function toRecord(b: Bubble): BubbleRecord {
  const record: BubbleRecord = {
    id: b.id,
    text: b.text,
    done: b.done,
    createdAt: b.createdAt,
    dateKey: b.dateKey,
    fromUid: b.fromUid,
    fromName: b.fromName,
    remoteId: b.remoteId,
    level: b.level,
    repeat: b.repeat,
    weekdays: b.weekdays,
    ruleId: b.ruleId,
    dueAt: b.dueAt,
    photo: b.photo
  };
  return record;
}

/** 输入框允许的最长字数：够表达一件事，又不至于变成笔记 */
export const MAX_TEXT_LENGTH: number = 16;

// ───────────────────────────────────────────────────────────────
//  重要程度
// ───────────────────────────────────────────────────────────────

export const LEVEL_NORMAL: number = 0;
export const LEVEL_IMPORTANT: number = 1;
export const LEVEL_URGENT: number = 2;

/** 三档中文名，下标就是等级值 */
export const LEVEL_LABELS: string[] = ['普通', '重要', '紧急'];
/** 三档配色：普通是灰（不着色、最安静），重要琥珀，紧急玫红 */
export const LEVEL_COLORS: string[] = ['#7E8CA0', '#F59E0B', '#F43F5E'];

/** 该等级在泡泡上要不要显示角标（普通不显示，免得屏幕上全是点） */
export function levelNeedsBadge(level: number): boolean {
  return level === LEVEL_IMPORTANT || level === LEVEL_URGENT;
}

/** 等级色，越界一律当普通 */
export function levelColor(level: number): string {
  if (level === LEVEL_IMPORTANT || level === LEVEL_URGENT) {
    return LEVEL_COLORS[level];
  }
  return LEVEL_COLORS[LEVEL_NORMAL];
}

/** 等级中文名 */
export function levelLabel(level: number): string {
  if (level === LEVEL_IMPORTANT) {
    return LEVEL_LABELS[LEVEL_IMPORTANT];
  }
  if (level === LEVEL_URGENT) {
    return LEVEL_LABELS[LEVEL_URGENT];
  }
  return LEVEL_LABELS[LEVEL_NORMAL];
}

/** 造一条示例记录的简写：手动记的、不循环 */
function seed(id: number, text: string, done: boolean, level: number,
  fromUid: string, fromName: string, remoteId: string, dateKey: string): BubbleRecord {
  const r: BubbleRecord = {
    id: id,
    text: text,
    done: done,
    createdAt: 0,
    dateKey: dateKey,
    fromUid: fromUid,
    fromName: fromName,
    remoteId: remoteId,
    level: level,
    repeat: 0,
    weekdays: 0,
    ruleId: '',
    dueAt: 0
  };
  return r;
}

/**
 * 首次启动的示例数据，撒在「今天」这一页
 * 故意做成「一件小事」的语气，让用户一眼明白这个 app 该怎么用；
 * 其中两条带 fromName，用来演示「好友发来的」长什么样（会多一圈彩色细边 + 落款）；
 * 另外两条给了重要程度，用来演示泡泡右上角那颗色点。
 */
export function buildSeedRecords(dateKey: string): BubbleRecord[] {
  const seeds: BubbleRecord[] = [
    seed(1, '买苹果', false, LEVEL_NORMAL, '', '', '', dateKey),
    seed(2, '取快递', false, LEVEL_NORMAL, '', '', '', dateKey),
    seed(3, '带伞', false, LEVEL_NORMAL, '', '', '', dateKey),
    seed(4, '还书给同事', false, LEVEL_NORMAL, '', '', '', dateKey),
    seed(5, '给妈回电话', false, LEVEL_IMPORTANT, '', '', '', dateKey),
    seed(6, '交电费', true, LEVEL_NORMAL, '', '', '', dateKey),
    seed(7, '带充电器', false, LEVEL_NORMAL, 'u_lin', '林深', 'seed_lin_1', dateKey),
    seed(8, '记得吃药', false, LEVEL_URGENT, 'u_wan', '苏晚', 'seed_wan_1', dateKey)
  ];
  // 紧急的那条顺手给个"今天截止"，让截止在泡泡上的样子（今天截止 / 已逾期）一进来就能看见
  for (let i = 0; i < seeds.length; i++) {
    if (seeds[i].id === 8) {
      seeds[i].dueAt = endOfDay(new Date()).getTime();
    }
  }
  return seeds;
}
