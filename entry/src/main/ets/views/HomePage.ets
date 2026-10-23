import { promptAction } from '@kit.ArkUI';
import {
  Bubble,
  BubbleRecord,
  LEVEL_COLORS,
  LEVEL_IMPORTANT,
  LEVEL_LABELS,
  LEVEL_NORMAL,
  LEVEL_URGENT,
  MAX_TEXT_LENGTH,
  createBubble,
  levelColor,
  levelLabel
} from '../model/BubbleModel';
import { BubbleStore } from '../model/BubbleStore';
import {
  REPEAT_DAILY,
  REPEAT_NONE,
  REPEAT_VERSION_KEY,
  REPEAT_WEEKLY,
  RepeatRule,
  WEEK_BITS,
  WEEK_LABELS,
  createRule,
  repeatText
} from '../model/RepeatModel';
import { BubbleEngine } from '../model/BubbleEngine';
import { BubbleView } from './BubbleView';
import {
  DAY_END_MS,
  dateOnly,
  formatClockHMS,
  formatClockTime,
  formatDateTitle,
  formatDueLabel,
  formatTimeHMS,
  fromDateKey,
  isOverdue,
  isToday,
  shiftDay,
  toDateKey,
  todayDate
} from '../common/DateUtil';
import { INBOX_VERSION_KEY } from '../service/TodoService';
import { StatusBarService } from '../service/live/StatusBarService';
import { DeadlineReminderService } from '../service/DeadlineReminderService';
import { FormCardService } from '../service/FormCardService';
import { CALENDAR_VISIBLE_KEY, CREATE_REQUEST_KEY, DETAIL_VISIBLE_KEY } from '../common/AppEvents';
import { AppPalette, AppTheme, THEME_VERSION_KEY, THEME_DARK_KEY } from '../common/AppTheme';
import { FrostedContentModifier } from '../common/AppMaterial';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { pickPhoto, removePhoto, toFileUri, loadPhotoPixelMap } from '../common/PhotoPicker';

// ---- 新建弹框里的常量 ----
//
// 这里刻意**不定义任何颜色**：配色一律走 AppTheme 的语义色（this.p().xxx），
// 换主题时同一处代码拿到的就是另一套值，不需要在这里维护两份。

/** 重复方式三档的显示文字，下标 = REPEAT_NONE / DAILY / WEEKLY */
const REPEAT_SEG_LABELS: string[] = ['不重复', '每天', '每周'];
/** 「标签 + 控件」这一行里，左侧标签固定占的宽度（vp）—— 两行左对齐靠它 */
const SEG_LABEL_WIDTH: number = 58;

// ---- 自绘日历 ----

/**
 * 日历永远铺满 6 行 × 7 列。
 *
 * 固定 6 行不是为了"算起来省事"，是为了**换月时卡片不跳动**：
 * 有的月份只占 5 行，如果按实际行数渲染，翻月时卡片会突然矮一截、
 * 底下的说明文字跟着上下窜，像是界面在抖。
 */
const CAL_ROWS: number = 6;
const CAL_COLS: number = 7;
/** 一格的尺寸：宽度靠 layoutWeight 均分，高度固定 */
const CAL_CELL_HEIGHT: number = 46;

/** 日历里的一天。算出来的一格快照，不参与持久化 */
class CalCell {
  /** 格子里显示的数字（1~31），前后补白来自相邻月份 */
  day: number = 0;
  /** 这格的存储键（YYYY-MM-DD），点击与打角标都按它 */
  key: string = '';
  /** 属不属于当前展示的月份（相邻月的补白格画得淡一些） */
  inMonth: boolean = true;
  /** 这天还没办完的事有几条（0 = 不打角标） */
  pending: number = 0;
  /** 是不是今天 */
  today: boolean = false;
}

/**
 * 主页：零星小记
 *
 *   ╭──────────────────────╮
 *   │   ‹  10月10日 周六  ›  │  日期栏：翻页看别的天，点日期直接选
 *   ╰──────────────────────╯
 *   ╭──────────────────────╮
 *   │    ●   ●              │  上半区：已完成，受重力落向本区底部
 *   ╰──────────────────────╯
 *   ╭──────────────────────╮
 *   │   ●    ●   ●          │  下半区：还没办的，沉到页面最下面
 *   │        ●              │
 *   ╰──────────────────────╯
 *      ▓▓▓▒▓▒▓ 页签栏   ( + )   最底部：悬浮页签栏 + 右侧独立的新建圆钮
 *
 * 一天一页：换日期就是换一批泡泡，各天的没办/办完互不干扰。
 * 上下两区等分。改变完成状态有两种方式（单击不切换）：
 *   ① 把泡泡拖到对面区域 —— 松手即换状态
 *   ② 按住泡泡瞬间向对面发射 —— 未完成向上弹、已完成向下落
 * 单击泡泡 = 翻开那一枚的详细信息（状态 / 重复 / 来源 / 记录时间，可就地完成或删掉）；
 * 双击泡泡 = 删除。
 */
@Component
export struct HomePage {
  /** 主题版本号：切换主题时 +1，这一页跟着重画（见 common/AppTheme.ets） */
  @StorageProp(THEME_VERSION_KEY) themeVersion: number = 0;
  @StorageProp(THEME_DARK_KEY) themeDark: boolean = AppTheme.isDark();

  /** 当前这套配色 */
  private p(): AppPalette {
    return AppTheme.palette(this.themeDark);
  }

  @StorageProp('topSafeAreaPx') topSafeAreaPx: number = 0;
  @StorageProp('bottomSafeAreaPx') bottomSafeAreaPx: number = 0;
  /**
   * 好友页「收下」一条小记后，TodoService 会把今天的泡泡写进存储并让这个号 +1。
   * 主页盯着它，停在今天这一页时就地把新泡泡补进来，不用切 Tab 也不会漏。
   */
  @StorageProp(INBOX_VERSION_KEY) @Watch('onInboxChanged') inboxVersion: number = 0;
  /**
   * 循环规则被改动（新建或删除）时 +1。
   * 规则在「我的」页被删掉后，主页上那枚还没做的泡泡要立刻消失，
   * 不能等切日期或者重启才更新。
   */
  @StorageProp(REPEAT_VERSION_KEY) @Watch('onRulesChanged') repeatVersion: number = 0;
  /**
   * 页签栏右侧那枚新建圆钮的触发信号（挂在 Index 层，和本页跨组件）。
   * 写入的是时间戳，值必然变化 → @Watch 必然触发。
   */
  @StorageProp(CREATE_REQUEST_KEY) @Watch('onCreateRequest') createRequestTick: number = 0;

  @State todoBubbles: Bubble[] = [];
  @State doneBubbles: Bubble[] = [];

  // ---- 日期栏 ----
  /** 显示中的日期标题：10月10日 周六 */
  @State dateTitle: string = '';
  /** 当前是不是今天（决定日期配色与「回到今天」是否出现） */
  @State showingToday: boolean = true;
  /** 换页时整块内容淡出淡入，避免泡泡"啪"地跳一下 */
  @State contentOpacity: number = 1;

  // ---- 自绘日历 ----
  /**
   * 日历是否展开。
   *
   * 用 @StorageLink 而不是 @State，是为了让 Index（外层页签框架）也能看见：
   * 日历盖住整屏时必须先收掉底栏和新建钮，返回键也得先收日历。
   */
  @StorageLink(CALENDAR_VISIBLE_KEY) calShown: boolean = false;
  /** 正在看哪个月（month 是 0~11，与 Date 一致；只在展示时 +1） */
  @State calYear: number = 0;
  @State calMonth: number = 0;
  /** 当前这个月的 42 格（换月 / 打开时整体重算） */
  @State calCells: CalCell[] = [];

  // ---- 新建面板 ----
  @State sheetShown: boolean = false;
  @State draft: string = '';
  /** 新建时选的重要程度 */
  @State draftLevel: number = LEVEL_NORMAL;
  /** 新建弹框里选好的照片（沙箱路径，空串 = 没选） */
  @State draftPhoto: string = '';
  /** 上面对应照片解码出来的 PixelMap：优先用它能 100% 显示，绕开沙箱路径加载兼容问题 */
  @State draftImage: image.PixelMap | null = null;
  /** 新建时选的重复方式：不重复 / 每天 / 每周 */
  @State draftRepeat: number = REPEAT_NONE;
  /** 每周模式下勾选的星期位掩码 */
  @State draftWeekdays: number = 0;
  /**
   * 紧急任务的截止 —— 拆成「哪一天」和「几点」两段，因为两段的选择器不一样：
   *   · 不重复   ：日期 + 时刻都能挑（年月日 + 时分秒）
   *   · 每天/每周 ：只有时刻能挑（时分秒），日期由循环自己带
   *
   * draftDueDate 存那天的零点时间戳；draftDueTimeMs 存距零点的毫秒偏移。
   * 拆开存是为了「换成循环再换回来」时，用户挑过的时刻不会丢。
   */
  @State draftDueDate: number = 0;
  @State draftDueTimeMs: number = DAY_END_MS;
  /** 输入框是否聚焦：聚焦时描边点亮，给一个"正在这里写"的锚点 */
  @State inputFocused: boolean = false;

  // ---- 单击泡泡翻开的「详细信息」 ----
  /**
   * 卡片是否在展示（淡入 / 缩放出场都挂在它上面）。
   *
   * 卡面字段全部抄成快照存下来，而不是每次去 allBubbles 里现查：
   * 卡片是半透明的、背后泡泡还在动，万一这期间那条被清掉（切天、被好友流程覆盖），
   * 现查会当场拿到 undefined，卡片就空了。快照没有这个问题。
   */
  @StorageLink(DETAIL_VISIBLE_KEY) @Watch('onDetailVisibilityChanged') detailShown: boolean = false;
  /** 正在看的是哪一枚（-1 = 没看）；泡泡靠它决定要不要套光环 */
  @State detailId: number = -1;
  @State detailText: string = '';
  @State detailLevel: number = LEVEL_NORMAL;
  @State detailRepeat: number = REPEAT_NONE;
  @State detailWeekdays: number = 0;
  @State detailDone: boolean = false;
  /** 已经格式化好的时刻文案 */
  @State detailTime: string = '';
  /** 好友发来的才有：来自 林深 */
  @State detailFrom: string = '';
  /** 详情卡当前这条的附带照片（沙箱路径，空串 = 没图） */
  @State detailPhoto: string = '';
  /** 上面对应照片解码出来的 PixelMap */
  @State detailImage: image.PixelMap | null = null;
  /** 点详情里的图 → 全屏看；空串 = 不弹 */
  @State previewPhoto: string = '';
  /** 全屏预览用的 PixelMap：直接复用 detailImage 的引用，不重复解码 */
  @State previewImage: image.PixelMap | null = null;
  /** 截止时间戳（0 = 没设），只有紧急会有 */
  @State detailDueAt: number = 0;

  /**
   * 正在被拖的泡泡 id（-1 = 没有）
   * 拖动时两个区域临时关掉圆角裁剪，泡泡才能"走"到对面去给人看见
   */
  @State draggingId: number = -1;

  private engine: BubbleEngine = new BubbleEngine();
  private allBubbles: Bubble[] = [];
  private initialized: boolean = false;

  /** 当前页的日期（零点）与它的存储键 */
  private selectedDate: Date = todayDate();
  @State dateKey: string = '';

  // 拖拽起点（vp）
  private dragStartCx: number = 0;
  private dragStartCy: number = 0;

  // 两个区域的实际尺寸（vp），新建泡泡时用来算投放位置
  private todoW: number = 0;
  private todoH: number = 0;
  private doneW: number = 0;
  private doneH: number = 0;

  aboutToAppear(): void {
    if (!this.initialized) {
      this.reload();
      // 发射出去的泡泡飞出本区后，由页面接管改状态
      this.engine.onEscapedUp = (b: Bubble): void => {
        this.onEscaped(b, true);
      };
      this.engine.onEscapedDown = (b: Bubble): void => {
        this.onEscaped(b, false);
      };
      this.initialized = true;
    }
  }

  aboutToDisappear(): void {
    this.engine.stop();
    // 日历是 @StorageLink：不主动收起来的话，切走再回来它会自己又展开
    this.calShown = false;
  }

  // ---------------- 按天翻页 ----------------

  /** 重新按当前日期装载泡泡（首次进入 / 切换日期都走这里） */
  private reload(): void {
    this.dateKey = toDateKey(this.selectedDate);
    this.dateTitle = formatDateTitle(this.selectedDate);
    this.showingToday = isToday(this.selectedDate);

    this.draggingId = -1;
    this.closeDetail();
    this.engine.endDrag();
    this.allBubbles = BubbleStore.loadDate(this.dateKey);
    this.engine.setBubbles(this.allBubbles);
    // 新一天的泡泡 placed=false，交给区域尺寸做一次随机散布
    if (this.doneW > 0 && this.doneH > 0) {
      this.engine.layoutArea(true, this.doneW, this.doneH);
    }
    if (this.todoW > 0 && this.todoH > 0) {
      this.engine.layoutArea(false, this.todoW, this.todoH);
    }
    this.syncLists();
    this.startEngineIfReady();
  }

  /** 换到某一天：先淡出，换完再淡入 —— 一步之间不要有突兀的跳变 */
  private switchDate(target: Date): void {
    const next: Date = dateOnly(target);
    if (toDateKey(next) === this.dateKey) {
      return;
    }
    this.contentOpacity = 0;
    setTimeout((): void => {
      this.selectedDate = next;
      this.reload();
      this.contentOpacity = 1;
    }, 90);
  }

  /** 左右箭头：前后翻一天 */
  private stepDay(delta: number): void {
    this.switchDate(shiftDay(this.selectedDate, delta));
  }

  // ---------------- 自绘日历 ----------------
  //
  // 不用系统 CalendarPickerDialog：它没法给某一天加标记，
  // 而"哪天还欠着事"恰恰是翻日历最想一眼看到的信息。

  /** 点日期：展开月历，默认停在当前所在的那个月 */
  private pickDate(): void {
    const sel: Date = this.selectedDate;
    this.calYear = sel.getFullYear();
    this.calMonth = sel.getMonth();
    this.buildCalCells();
    this.calShown = true;
  }

  /**
   * 算一次 42 格。
   *
   * 周一起排：先看 1 号是周几，把那一周的周一当作第一格（可能落到上个月），
   * 于是 6×7 一定能盖住整月。前后补白用相邻月份的真实日期算，
   * 这样跨月那几格也能正确打上角标。
   */
  private buildCalCells(): void {
    const first: Date = new Date(this.calYear, this.calMonth, 1);
    // getDay() 里 0 是周日；布局以周一为第一列，先换算成 0(周一)~6(周日)
    const lead: number = (first.getDay() + 6) % 7;
    const todayKey: string = toDateKey(new Date());
    const cells: CalCell[] = [];
    for (let i = 0; i < CAL_ROWS * CAL_COLS; i++) {
      const d: Date = new Date(this.calYear, this.calMonth, 1 - lead + i);
      const key: string = toDateKey(d);
      const cell: CalCell = new CalCell();
      cell.day = d.getDate();
      cell.key = key;
      cell.inMonth = d.getMonth() === this.calMonth;
      cell.pending = BubbleStore.pendingCountOf(key);
      cell.today = key === todayKey;
      cells.push(cell);
    }
    this.calCells = cells;
  }

  /** 翻月。跨年交给 Date 自己换算，不手写 12 进制的取模 */
  private calShiftMonth(delta: number): void {
    const d: Date = new Date(this.calYear, this.calMonth + delta, 1);
    this.calYear = d.getFullYear();
    this.calMonth = d.getMonth();
    this.buildCalCells();
  }

  /** 选中某天：先收日历再换页 —— 遮罩还盖着的话，用户看不到自己挑的那天 */
  private calPick(key: string): void {
    this.calShown = false;
    this.switchDate(fromDateKey(key));
  }

  private calGoToday(): void {
    this.calShown = false;
    this.switchDate(todayDate());
  }

  private isSelectedDay(cell: CalCell): boolean {
    return cell.key === this.dateKey;
  }

  /** 日期数字的配色：选中（白）> 今天（主题蓝）> 本月（墨）> 补白（淡） */
  private calDayColor(cell: CalCell): string {
    if (this.isSelectedDay(cell)) {
      return '#FFFFFF';
    }
    if (cell.today) {
      return this.p().accentText;
    }
    return cell.inMonth ? this.p().textPrimary : this.p().textQuaternary;
  }

  /** 角标底色：选中那格压在主题蓝上，得用半透明白才看得出 */
  private calBadgeBg(cell: CalCell): string {
    if (this.isSelectedDay(cell)) {
      return '#3DFFFFFF';
    }
    return cell.inMonth ? this.p().accentSoft : this.p().chip;
  }

  private calBadgeTextColor(cell: CalCell): string {
    if (this.isSelectedDay(cell)) {
      return '#FFFFFF';
    }
    return cell.inMonth ? this.p().accentText : this.p().textQuaternary;
  }

  /** 两位数就够用了，再多会把格子撑歪 */
  private calBadgeText(cell: CalCell): string {
    return cell.pending > 9 ? '9+' : `${cell.pending}`;
  }

  /**
   * 这一屏月历里还没办完的总件数。
   *
   * 只算本月的格子：前后补白那几格属于相邻月份，把它们算进来，"本月"这个词就不成立了
   * —— 翻到 10 月，9 月 30 日那格会跟着出现在第一行，但它不该记在 10 月头上。
   */
  private calMonthPending(): number {
    let n: number = 0;
    for (let i = 0; i < this.calCells.length; i++) {
      const cell: CalCell = this.calCells[i];
      if (cell.inMonth) {
        n += cell.pending;
      }
    }
    return n;
  }

  /** 本月有几个日子还挂着事（用来区分"一天堆了 8 件"和"8 天各欠 1 件"） */
  private calMonthPendingDays(): number {
    let n: number = 0;
    for (let i = 0; i < this.calCells.length; i++) {
      const cell: CalCell = this.calCells[i];
      if (cell.inMonth && cell.pending > 0) {
        n++;
      }
    }
    return n;
  }

  /** 底部那句汇总：把"欠了多少件、摊在几天上"一次说清 */
  private calMonthSummary(): string {
    const days: number = this.calMonthPendingDays();
    if (days === 0) {
      return '这个月没有欠着的事';
    }
    const items: number = this.calMonthPending();
    return `欠着 ${items} 件 · 摊在 ${days} 天`;
  }

  private calA11y(cell: CalCell): string {
    if (cell.pending > 0) {
      return `${cell.day}日，还有 ${cell.pending} 件没办完`;
    }
    return `${cell.day}日`;
  }

  /**
   * 挑截止日期（只有「紧急 + 不重复」会走到这里）。
   * 起点锁在今天：设一个已经过去的截止没有意义。
   */
  private pickDueDate(): void {
    const now: Date = new Date();
    const selected: Date = this.draftDueDate > 0 ? new Date(this.draftDueDate) : todayDate();
    this.getUIContext().showDatePickerDialog({
      start: todayDate(),
      end: new Date(now.getFullYear() + 5, 11, 31),
      selected: selected,
      onDateAccept: (value: Date) => {
        this.draftDueDate = dateOnly(value).getTime();
      }
    });
  }

  /**
   * 挑截止时刻（时分秒）—— 紧急任务都会走到这里，两种重复方式共用：
   *   · 不重复   ：这个时刻是"挑中的那一天"里的时刻
   *   · 每天/每周 ：这个时刻是"每个命中的那天"共用的时刻
   */
  private pickDueTime(): void {
    const base: number = this.draftDueDate > 0 ? this.draftDueDate : todayDate().getTime();
    this.getUIContext().showTimePickerDialog({
      selected: new Date(base + this.draftDueTimeMs),
      format: TimePickerFormat.HOUR_MINUTE_SECOND,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        this.draftDueTimeMs = ((value.hour * 60 + value.minute) * 60 + value.second) * 1000;
      }
    });
  }

  /** 把 allBubbles 按完成状态拆成两个渲染列表 */
  private syncLists(): void {
    const todo: Bubble[] = [];
    const done: Bubble[] = [];
    for (let i = 0; i < this.allBubbles.length; i++) {
      const b: Bubble = this.allBubbles[i];
      if (b.done) {
        done.push(b);
      } else {
        todo.push(b);
      }
    }
    this.todoBubbles = todo;
    this.doneBubbles = done;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }

  /** 两个区域都量到尺寸后再启动物理循环，避免首帧泡泡挤在左上角 */
  private startEngineIfReady(): void {
    if (!this.engine.isRunning() && this.todoW > 0 && this.todoH > 0
      && this.doneW > 0 && this.doneH > 0) {
      this.engine.start();
    }
  }

  private persist(): void {
    BubbleStore.saveDate(this.dateKey, this.allBubbles);
    // 待办一有增减就同步状态栏（开关没打开时 refresh 内部直接返回，不打扰系统）
    StatusBarService.refresh();
    // 顺带重算紧急任务的截止提醒：新建、删除、办完、取消办完都走这里，
    // 一个挂点就覆盖了所有会让"该提醒什么"发生变化的操作
    DeadlineReminderService.sync();
    // 桌面卡片同理：桌面上没加卡片时这个调用会立刻返回，几乎不要钱
    FormCardService.syncAll();
  }

  // ---------------- 好友收下的待办 ----------------

  /**
   * 好友的小记被「收下」后落到今天。
   * 如果当前正停在今天这一页，就地把新泡泡冒出来（从右下角弹入），
   * 而不是整页 reload —— 否则已经沉好的泡泡会被重新撒一遍，视觉上很跳。
   */
  private onInboxChanged(): void {
    const todayKey: string = toDateKey(new Date());
    if (this.dateKey.length === 0 || this.dateKey !== todayKey) {
      return;
    }
    const stored: Bubble[] = BubbleStore.loadDate(todayKey);
    const known: Set<number> = new Set<number>();
    for (let i = 0; i < this.allBubbles.length; i++) {
      known.add(this.allBubbles[i].id);
    }

    let added: number = 0;
    for (let i = 0; i < stored.length; i++) {
      const b: Bubble = stored[i];
      if (known.has(b.id)) {
        continue;
      }
      if (this.todoW > 0 && this.todoH > 0) {
        b.boundLeft = 0;
        b.boundTop = 0;
        b.boundRight = this.todoW;
        b.boundBottom = this.todoH;
        // 和「加号新建」一样：从右下角冒出来
        b.cx = Math.max(b.r + 2, this.todoW - b.r - 26);
        b.cy = Math.max(b.r + 2, this.todoH - b.r - 6);
        b.vx = -70;
        b.vy = -560;
        b.placed = true;
      }
      this.allBubbles.push(b);
      added++;
    }

    if (added > 0) {
      this.engine.setBubbles(this.allBubbles);
      this.syncLists();
      // 好友塞过来的待办不写本页（它已经落在 BubbleStore 里了），
      // 所以走不到 persist —— 这里补一次截止提醒的重算
      DeadlineReminderService.sync();
      // 桌面卡片同样补一次
      FormCardService.syncAll();
      this.toast(`收到 ${added} 条好友小记`);
    }
  }

  // ---------------- 循环规则变动 ----------------

  /**
   * 规则被删了：把由它物化出来、且还没完成的泡泡就地撤掉。
   * 已完成的留着 —— 那是你确实做过的事，不该跟着规则一起消失。
   */
  private onRulesChanged(): void {
    const rules: RepeatRule[] = BubbleStore.loadRules();
    const alive: Set<number> = new Set<number>();
    for (let i = 0; i < rules.length; i++) {
      alive.add(rules[i].id);
    }

    const kept: Bubble[] = [];
    let removed: number = 0;
    for (let i = 0; i < this.allBubbles.length; i++) {
      const b: Bubble = this.allBubbles[i];
      if (b.ruleId.length > 0 && !b.done) {
        const rid: number = Number.parseInt(b.ruleId, 10);
        if (!Number.isNaN(rid) && !alive.has(rid)) {
          removed++;
          continue;
        }
      }
      kept.push(b);
    }

    if (removed > 0) {
      this.allBubbles = kept;
      this.engine.setBubbles(this.allBubbles);
      this.syncLists();
    }
  }

  // ---------------- 交互 ----------------

  /**
   * 页签栏右侧那枚新建圆钮被点了（信号来自 Index 层）。
   * 点的时候 Index 已经先把页签切回主页，这里只管把弹框打开。
   */
  private onCreateRequest(): void {
    this.openCreate();
  }

  private openCreate(): void {
    this.draft = '';
    this.draftLevel = LEVEL_NORMAL;
    this.draftRepeat = REPEAT_NONE;
    this.draftWeekdays = 0;
    // 截止默认「今天 · 23:59:59」—— 选了紧急就有一个合理起点，不用先点一下才不是空的。
    // 时刻默认压在当天末尾，和"说 15 号截止，15 号一整天都算数"的直觉一致。
    this.draftDueDate = todayDate().getTime();
    this.draftDueTimeMs = DAY_END_MS;
    this.inputFocused = false;
    this.draftPhoto = '';
    this.swapDraftImage(null);
    this.sheetShown = true;
  }

  /** 从相册选一张图，复制到沙箱后填进 draftPhoto */
  private async pickDraftPhoto(): Promise<void> {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.toast('无法访问相册');
      return;
    }
    const path: string = await pickPhoto(ctx);
    if (path.length > 0) {
      this.draftPhoto = path;
      // 顺手解码成 PixelMap：显示优先用它，沙箱路径渲染不出来的机型也能正常看图
      this.swapDraftImage(await loadPhotoPixelMap(path));
    } else {
      this.toast('图片没读出来，换一张试试');
    }
  }

  /** 替换草稿图 PixelMap：释放掉上一张，避免反复选图把内存撑爆（撑爆了反而更白） */
  private swapDraftImage(pm: image.PixelMap | null): void {
    const old: image.PixelMap | null = this.draftImage;
    this.draftImage = pm;
    if (old !== null && old !== pm) {
      try { old.release(); } catch (e) {}
    }
  }

  /** 替换详情图 PixelMap：同上，释放旧的 */
  private swapDetailImage(pm: image.PixelMap | null): void {
    const old: image.PixelMap | null = this.detailImage;
    this.detailImage = pm;
    if (old !== null && old !== pm) {
      try { old.release(); } catch (e) {}
    }
  }

  /** 勾/去勾星期（每周模式用） */
  private toggleWeekday(i: number): void {
    const bit: number = WEEK_BITS[i];
    if ((this.draftWeekdays & bit) !== 0) {
      this.draftWeekdays = this.draftWeekdays & ~bit;
    } else {
      this.draftWeekdays = this.draftWeekdays | bit;
    }
  }

  /**
   * 新建。
   *  · 不重复 —— 直接往当前这一天放一枚泡泡（从右下角冒出来）
   *  · 每天 / 每周 —— 存一条循环规则，然后立刻按规则物化当前这一天
   *
   * 规则的起点固定是「今天」而不是"当前正在看的那一天"：
   * 否则你翻回上个月随手记一条"每天吃药"，那一整个月都会被填满。
   */
  private commitDraft(): void {
    const text: string = this.draft.trim();
    if (text.length === 0) {
      this.toast('写一句吧');
      return;
    }
    if (this.draftRepeat === REPEAT_WEEKLY && this.draftWeekdays === 0) {
      this.toast('选一下周几重复');
      return;
    }

    // 紧急 + 不重复：截止必须还在未来。
    // 挑了个已经过去的时刻，这条一建出来就是"已逾期"——与其让人事后纳闷，不如当场拦下。
    const isUrgent: boolean = this.draftLevel === LEVEL_URGENT;
    const dueAtAbs: number = this.draftDueDate + this.draftDueTimeMs;
    if (isUrgent && this.draftRepeat === REPEAT_NONE && dueAtAbs <= Date.now()) {
      this.toast('这个时刻已经过了，换一个');
      return;
    }

    if (this.draftRepeat === REPEAT_NONE) {
      // 截止只有紧急才有；不紧急时硬塞一个日期，以后会在详情里冒出一行看不懂的"截止"
      this.spawnOne(text, this.draftLevel, isUrgent ? dueAtAbs : 0, this.draftPhoto);
      this.sheetShown = false;
      return;
    }

    const todayKey: string = toDateKey(new Date());
    // 循环任务的截止只存**时刻**（几点），日期由物化时的 dateKey 给 ——
    // 「每天 9:00 截止」于是每天都落在当天 9:00，规则本身不会过期。
    const rule: RepeatRule = createRule(
      BubbleStore.nextRuleId(), text, this.draftLevel,
      this.draftRepeat, this.draftWeekdays, todayKey,
      isUrgent ? this.draftDueTimeMs : 0
    );
    BubbleStore.addRule(rule);

    // 规则的起点是今天：如果这一页就是今天（或更晚且命中），新泡泡当场冒出来
    const created: Bubble[] = BubbleStore.materialize(this.dateKey);
    if (created.length > 0) {
      for (let i = 0; i < created.length; i++) {
        this.dropIntoTodo(created[i]);
      }
      this.syncLists();
      this.toast(`${repeatText(rule.mode, rule.weekdays)}，已记下`);
    } else {
      // 在看过去的日子（或今天不命中）：规则已存好，回到该出现的日子就会自己冒出来
      this.toast(`${repeatText(rule.mode, rule.weekdays)}，回今天就能看到`);
    }
    // 通知「我的」页那张规则清单刷新
    AppStorage.setOrCreate<number>(REPEAT_VERSION_KEY, this.repeatVersion + 1);
    this.sheetShown = false;
  }

  /** 手动记一条：投入未完成区，从右下角「冒」出来 */
  private spawnOne(text: string, level: number, dueAt: number, photo: string): void {
    const record: BubbleRecord = {
      id: BubbleStore.nextId(),
      text: text,
      done: false,
      createdAt: Date.now(),
      dateKey: this.dateKey,
      fromUid: '',
      fromName: '',
      remoteId: '',
      level: level,
      repeat: 0,
      weekdays: 0,
      dueAt: dueAt,
      ruleId: '',
      photo: photo
    };
    this.dropIntoTodo(createBubble(record));
    this.syncLists();
    this.persist();
  }

  /** 把一枚泡泡放进未完成区右下角，给一个向上的初速度，像从加号里冒出来 */
  private dropIntoTodo(b: Bubble): void {
    if (this.todoW > 0 && this.todoH > 0) {
      b.boundLeft = 0;
      b.boundTop = 0;
      b.boundRight = this.todoW;
      b.boundBottom = this.todoH;
      b.cx = Math.max(b.r + 2, this.todoW - b.r - 26);
      b.cy = Math.max(b.r + 2, this.todoH - b.r - 6);
      b.vx = -70;
      b.vy = -560;
      b.placed = true;
    }
    this.engine.add(b);
  }

  // ---------------- 拖拽 ----------------

  /** 手指按住泡泡开始拖：物理引擎暂时放手，位置全交给手指 */
  private startDrag(b: Bubble): void {
    this.draggingId = b.id;
    this.dragStartCx = b.cx;
    this.dragStartCy = b.cy;
    b.dragging = true;
    this.engine.beginDrag(b.id);
  }

  /** 拖动中：跟手移动。横向留在区域内，纵向放开 —— 要能拖到对面去 */
  private moveDrag(b: Bubble, dx: number, dy: number): void {
    const w: number = b.done ? this.doneW : this.todoW;
    const margin: number = b.r * 0.5;
    if (w > margin * 2) {
      b.cx = Math.max(margin, Math.min(w - margin, this.dragStartCx + dx));
    } else {
      b.cx = this.dragStartCx + dx;
    }
    b.cy = this.dragStartCy + dy;
  }

  /** 松手：看它落在哪一边 —— 拖到对面才换状态，留在本区就原位垂回去 */
  private endDrag(b: Bubble): void {
    b.dragging = false;
    this.draggingId = -1;
    this.engine.endDrag();

    // 判定"拖到对面"：泡泡中心要明显越过本区边界（留 0.6r 余量，避免轻碰就误判）
    const crossed: boolean = b.done
      ? b.cy > this.doneH + b.r * 0.6
      : b.cy < -b.r * 0.6;

    if (crossed) {
      b.done = !b.done;
      this.adoptInto(b);
      this.syncLists();
      this.persist();
      this.toast(b.done ? '办完了' : '又回到未完成');
    } else {
      this.clampToOwnArea(b);
    }
  }

  /** 跨区后交给新区域：横向位置沿用，从靠来向的那一侧进入，免得"跳"到角落 */
  private adoptInto(b: Bubble): void {
    const w: number = b.done ? this.doneW : this.todoW;
    const h: number = b.done ? this.doneH : this.todoH;
    if (w <= 0 || h <= 0) {
      return;
    }
    b.boundLeft = 0;
    b.boundTop = 0;
    b.boundRight = w;
    b.boundBottom = h;
    b.cx = Math.max(b.r + 2, Math.min(w - b.r - 2, b.cx));
    // 拖上去的从上区底部进入，拖下来的从下区顶部进入
    b.cy = b.done ? h - b.r - 4 : b.r + 4;
    b.vx = 0;
    b.vy = b.done ? -90 : 90;
    b.placed = true;
  }

  /** 没跨区：收回自己区域，松手后由重力垂回自己那侧 */
  private clampToOwnArea(b: Bubble): void {
    const w: number = b.done ? this.doneW : this.todoW;
    const h: number = b.done ? this.doneH : this.todoH;
    if (w <= 0 || h <= 0) {
      return;
    }
    b.boundLeft = 0;
    b.boundTop = 0;
    b.boundRight = w;
    b.boundBottom = h;
    b.cx = Math.max(b.r + 2, Math.min(w - b.r - 2, b.cx));
    b.cy = Math.max(b.r + 2, Math.min(h - b.r - 2, b.cy));
    b.vx = 0;
    b.vy = 0;
  }

  // ---------------- 按住发射 ----------------

  /** 按住泡泡：朝对面「射」出去。未完成向上、已完成向下 */
  private launchBubble(b: Bubble): void {
    if (b.dragging) {
      return;
    }
    if (b.done) {
      this.engine.launchDown(b);
      this.toast('落回未完成');
    } else {
      this.engine.launchUp(b);
      this.toast('飞上去了');
    }
  }

  /**
   * 发射出去的泡泡整个飞离本区，落到对面区域
   * @param toDone true = 飞进了上半区（变已完成），false = 落回下半区
   */
  private onEscaped(b: Bubble, toDone: boolean): void {
    b.done = toDone;
    const w: number = toDone ? this.doneW : this.todoW;
    const h: number = toDone ? this.doneH : this.todoH;
    if (w > 0 && h > 0) {
      b.boundLeft = 0;
      b.boundTop = 0;
      b.boundRight = w;
      b.boundBottom = h;
      b.cx = Math.max(b.r + 2, Math.min(w - b.r - 2, b.cx));
      // 从对面区域的"入口侧"接上，位置连续，看起来像一路穿过去的
      b.cy = toDone ? h - b.r * 0.6 : b.r * 0.6;
      // 保留一点向前的势头，剩下的交给该区重力收尾
      b.vy = toDone ? -320 : 320;
      b.vx = 0;
      b.placed = true;
    }
    this.syncLists();
    this.persist();
  }

  /** 双击泡泡：删除 */
  private confirmDelete(b: Bubble): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删掉这条小记？',
      message: b.text,
      buttons: [
        { text: '留着', color: this.p().textMeta },
        { text: '删掉', color: this.p().danger }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.removeBubble(b);
      }
    }).catch(() => {
    });
  }

  private removeBubble(b: Bubble): void {
    removePhoto(b.photo);
    this.allBubbles = this.allBubbles.filter((item: Bubble) => item.id !== b.id);
    this.engine.setBubbles(this.allBubbles);
    this.syncLists();
    this.persist();
    this.toast('已删掉');
  }

  // ---------------- 单击泡泡：详细信息 ----------------

  /** 单击泡泡：把这条的信息抄一份到卡片上并弹出来 */
  private async openDetail(b: Bubble): Promise<void> {
    this.detailId = b.id;
    this.detailText = b.text;
    this.detailLevel = b.level;
    this.detailRepeat = b.repeat;
    this.detailWeekdays = b.weekdays;
    this.detailDone = b.done;
    this.detailTime = formatClockTime(b.createdAt);
    this.detailFrom = b.fromName;
    this.detailDueAt = b.dueAt;
    this.detailPhoto = b.photo;
    // 顺手把照片解码成 PixelMap：显示优先用它；空串时 loadPhotoPixelMap 返回 null，会退回 file:// 路径兜底
    this.swapDetailImage(await loadPhotoPixelMap(b.photo));
    // 给这一颗套上光环：屏幕上好几枚泡泡，得有东西指明在看哪个
    this.clearFocus();
    b.focused = true;
    this.detailShown = true;
  }

  private closeDetail(): void {
    this.detailShown = false;
    this.detailId = -1;
    this.clearFocus();
    // 释放详情图 PixelMap，省内存（预览层已先行置空，这里 release 不会误伤）
    this.swapDetailImage(null);
  }

  private onDetailVisibilityChanged(): void {
    if (!this.detailShown) {
      this.detailId = -1;
      this.clearFocus();
    }
  }

  /** 光环只属于"正在看的那一枚"，切换或收起时先把别的都清掉 */
  private clearFocus(): void {
    for (let i = 0; i < this.allBubbles.length; i++) {
      this.allBubbles[i].focused = false;
    }
  }

  private findBubble(id: number): Bubble | null {
    for (let i = 0; i < this.allBubbles.length; i++) {
      if (this.allBubbles[i].id === id) {
        return this.allBubbles[i];
      }
    }
    return null;
  }

  /** 详情里点「完成 / 回到未完成」：结果与把泡泡拖过对面完全一致 */
  private toggleDetailDone(): void {
    const b: Bubble | null = this.findBubble(this.detailId);
    if (b === null) {
      this.closeDetail();
      return;
    }
    b.done = !b.done;
    const nowDone: boolean = b.done;
    // 先让它从对面那一侧进场，再收卡片 —— 顺序反了会看到泡泡莫名其妙换位置
    this.adoptInto(b);
    this.syncLists();
    this.persist();
    this.closeDetail();
    this.toast(nowDone ? '办完了' : '又回到未完成');
  }

  /**
   * 详情里点「删掉」：不再问第二遍。
   * 双击删除要确认，是因为那一下可能只是想看一眼；
   * 而能翻到详情里再点删除，意图已经很明确了。
   */
  private deleteFromDetail(): void {
    const b: Bubble | null = this.findBubble(this.detailId);
    this.closeDetail();
    if (b !== null) {
      this.removeBubble(b);
    }
  }

  /** 详情卡「重复」那一行的文案：不循环时直说"只记一次"，比留空好懂 */
  private detailRepeatText(): string {
    if (this.detailRepeat === REPEAT_NONE) {
      return '只记一次';
    }
    return repeatText(this.detailRepeat, this.detailWeekdays);
  }

  /**
   * 详情卡「截止」那一行：日期 + 时刻，精确到秒。
   * 已完成的不报逾期 —— 事都做完了还标个"已逾期"没有意义。
   */
  private detailDueText(): string {
    const label: string = `${formatDueLabel(this.detailDueAt)} ${formatClockHMS(this.detailDueAt)}`;
    if (!this.detailDone && isOverdue(this.detailDueAt)) {
      return `${label} · 已逾期`;
    }
    return label;
  }

  // ---------------- UI ----------------

  /** 品牌标题与日历入口。 */
  @Builder
  brandHeader() {
    Row({ space: 7 }) {
      Text('零星小记').fontSize(27).fontWeight(FontWeight.Bold).fontColor(this.p().textPrimary)
      Text('✦').fontSize(23).fontColor('#E9B85E')
      Blank()
      SymbolGlyph($r('sys.symbol.calendar'))
        .fontSize(22).fontColor([this.p().textSecondary])
        .width(44).height(44)
        .accessibilityText('选择日期')
        .onClick(() => { this.pickDate(); })
    }
    .width('100%')
    .padding({ left: 20, right: 14, bottom: 8 })
  }

  private datePillText(): string {
    const date: Date = fromDateKey(this.dateKey);
    const shortDate: string = `${date.getMonth() + 1}月${date.getDate()}日`;
    const relative: string = this.dayRelLabel();
    if (relative.length > 0) { return `${relative} · ${shortDate}`; }
    if (date.getFullYear() !== new Date().getFullYear()) {
      return `${date.getFullYear()}年${shortDate}`;
    }
    return this.dateTitle;
  }

  @Builder
  dateBar() {
    Column() {
      Row() {
        Row({ space: 2 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(16).fontColor([this.p().textSecondary])
          }
          .width(38).height(38)
          .accessibilityText('前一天')
          .onClick(() => { this.stepDay(-1); })
          Text(this.datePillText())
            .fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary).textAlign(TextAlign.Center)
            .maxLines(1).minFontSize(12).layoutWeight(1).height(38)
            .accessibilityText('选择日期')
            .onClick(() => { this.pickDate(); })
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16).fontColor([this.p().textSecondary])
          }
          .width(38).height(38)
          .accessibilityText('后一天')
          .onClick(() => { this.stepDay(1); })
        }
        .width(238).height(42).padding({ left: 3, right: 3 })
        .borderRadius(21).backgroundColor(this.p().cardBgThin)
        .border({ width: 1, color: this.p().glassBorder })
      }
      .width('100%').justifyContent(FlexAlign.Center)

      Row() {
        Text(this.subTitleText())
          .fontSize(13).fontColor(this.p().textSecondary)
          .layoutWeight(1).maxLines(1)
        if (!this.showingToday) {
          Text('回到今天').fontSize(11).fontColor(this.p().accentText)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => { this.switchDate(todayDate()); })
        }
        Text(`${this.progressPercent()}%`).fontSize(13)
          .fontWeight(FontWeight.Medium).fontColor(this.p().accentText)
      }
      .width('100%').height(30).margin({ top: 10 })

      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(5).borderRadius(3).backgroundColor(this.p().chip)
        Row().width(`${this.progressPercent()}%`).height(5).borderRadius(3)
          .linearGradient({ angle: 90, colors: [[this.p().progressFrom, 0], [this.p().progressTo, 1]] })
          .animation({ duration: 320, curve: Curve.Friction })
      }
      .width('100%').height(5).margin({ top: 3 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 14 })
  }

  // ---------------- 日历弹层 ----------------

  /** 一格：日期 + 未办完的角标 */
  @Builder
  calCellView(cell: CalCell) {
    Column({ space: 1 }) {
      Text(`${cell.day}`)
        .fontSize(14)
        .fontWeight(cell.today || this.isSelectedDay(cell) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.calDayColor(cell))

      if (cell.pending > 0) {
        Text(this.calBadgeText(cell))
          .fontSize(10)
          .fontColor(this.calBadgeTextColor(cell))
          .height(14)
          .padding({ left: 5, right: 5 })
          .borderRadius(7)
          .backgroundColor(this.calBadgeBg(cell))
      } else {
        // 占位：没角标的日子也留出同样高度，每行数字才在同一水平线上
        Text('').fontSize(10).height(14)
      }
    }
    .layoutWeight(1)
    .height(CAL_CELL_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .borderRadius(13)
    .backgroundColor(this.isSelectedDay(cell) ? this.p().accent : Color.Transparent)
    .border({ width: cell.today && !this.isSelectedDay(cell) ? 1 : 0, color: this.p().accent })
    .accessibilityText(this.calA11y(cell))
    .onClick(() => { this.calPick(cell.key); })
  }

  /** 一行 7 格。calCells 是一维的 42 个，按行切 */
  @Builder
  calWeekRow(rowIndex: number) {
    Row() {
      ForEach(this.calCells.slice(rowIndex * CAL_COLS, rowIndex * CAL_COLS + CAL_COLS),
        (cell: CalCell) => {
          this.calCellView(cell)
        }, (cell: CalCell) => cell.key)
    }
    .width('100%')
    .height(CAL_CELL_HEIGHT)
  }

  /** 月历卡片 */
  @Builder
  calendarCard() {
    Column() {
      // 月份导航
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(16).fontColor([this.p().textSecondary])
        }
        .width(36).height(36)
        .justifyContent(FlexAlign.Center)
        .accessibilityText('上个月')
        .onClick(() => { this.calShiftMonth(-1); })

        Text(`${this.calYear}年${this.calMonth + 1}月`)
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.p().textPrimary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)

        Row() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16).fontColor([this.p().textSecondary])
        }
        .width(36).height(36)
        .justifyContent(FlexAlign.Center)
        .accessibilityText('下个月')
        .onClick(() => { this.calShiftMonth(1); })
      }
      .width('100%')

      // 星期表头（周一在最左，与格子同序）
      Row() {
        ForEach(WEEK_LABELS, (w: string) => {
          Text(w)
            .fontSize(11).fontColor(this.p().textTertiary)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (w: string) => `cal_wk_${w}`)
      }
      .width('100%').height(24).margin({ top: 6 })

      // 6 × 7 固定网格
      Column() {
        this.calWeekRow(0)
        this.calWeekRow(1)
        this.calWeekRow(2)
        this.calWeekRow(3)
        this.calWeekRow(4)
        this.calWeekRow(5)
      }
      .width('100%')

      // 底部：回今天 + 本月欠账汇总
      Row() {
        Text('回到今天')
          .fontSize(12).fontColor(this.p().accentText)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(13)
          .backgroundColor(this.p().accentSoft)
          .accessibilityText('回到今天')
          .onClick(() => { this.calGoToday(); })
        Blank()
        Text(this.calMonthSummary())
          .fontSize(11)
          .fontColor(this.calMonthPending() > 0 ? this.p().accentText : this.p().textTertiary)
      }
      .width('100%').margin({ top: 6 })

      // 一行说明：格子里的数字到底是什么，省得第一次看到要猜
      Text('格子里的数字 = 这天没办完的件数')
        .fontSize(10).fontColor(this.p().textTertiary)
        .width('100%').textAlign(TextAlign.Center)
        .margin({ top: 4 })
    }
    .width('calc(100% - 48vp)')
    .padding({ left: 10, right: 10, top: 8, bottom: 12 })
    .borderRadius(26)
    .backgroundColor(this.p().cardBg)
    .border({ width: 1, color: this.p().glassBorder })
    .shadow({ radius: 28, color: this.p().shadowCard, offsetX: 0, offsetY: 10 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 170, curve: Curve.EaseOut }))
  }

  /** 日历弹层：淡遮罩 + 居中卡片，点遮罩收起 */
  @Builder
  calendarOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().scrim)
        .onClick(() => { this.calShown = false; })
        .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))

      this.calendarCard()
    }
    .width('100%')
    .height('100%')
  }

  /** 相对今天的标签：今天 / 昨天 / 明天，更远的日子返回空串 */
  private dayRelLabel(): string {
    const diff: number = Math.round(
      (dateOnly(this.selectedDate).getTime() - todayDate().getTime()) / 86400000
    );
    if (diff === 0) {
      return '今天';
    }
    if (diff === -1) {
      return '昨天';
    }
    if (diff === 1) {
      return '明天';
    }
    return '';
  }

  /** 副行：有记录时报两区的条数，空的一天说清楚"为什么空" */
  private subTitleText(): string {
    if (this.totalCount() === 0) {
      return this.showingToday ? '今天还没有记录' : '这一天没有记录';
    }
    return `待办 ${this.todoBubbles.length} 条 · 办完 ${this.doneBubbles.length} 条`;
  }

  private totalCount(): number {
    return this.todoBubbles.length + this.doneBubbles.length;
  }

  /** 完成百分比（整数）。一条都没有时给 0，进度条就只剩轨道 */
  private progressPercent(): number {
    const total: number = this.totalCount();
    if (total === 0) {
      return 0;
    }
    return Math.round(this.doneBubbles.length * 100 / total);
  }

  /**
   * 分区卡头：「✓ 已完成 2」。
   *
   * 挂在 Stack 里、写在泡泡 ForEach 之后（也就是叠在泡泡上层），并设了
   * hitTestBehavior(None)：它不吃点击，泡泡从它下面飘过去照样能拖。
   */
  @Builder
  areaHeader(done: boolean) {
    Row({ space: 6 }) {
      Text(done ? '✓' : '●')
        .fontSize(11)
        .fontColor(done ? this.p().textSecondary : this.p().accentText)
      Text(done ? '已完成' : '待办')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(done ? this.p().textSecondary : this.p().accentText)
      Text(`${done ? this.doneBubbles.length : this.todoBubbles.length}`)
        .fontSize(11)
        .fontColor(done ? this.p().textSecondary : this.p().accentText)
        .padding({ left: 7, right: 7, top: 1, bottom: 2 })
        .backgroundColor(this.p().chipStrong)
        .borderRadius(9)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 空态：给一个符号 + 一句话，比孤零零一行灰字更像"这里空着"而不是"这里坏了" */
  @Builder
  emptyHint(done: boolean) {
    Column({ space: 7 }) {
      Text(done ? '○' : '＋')
        .fontSize(24)
        .fontColor(this.p().textQuaternary)
      Text(done ? '办完的事会落到这里' : (this.showingToday ? '点右下角的 + ，记一句' : '这一天没有记录'))
        .fontSize(12)
        .fontColor(this.p().textTertiary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ---- 新建弹框里两个分段控件 ----
  //
  // 做法是"一整块轨道 + 选中项自己带一块滑块"，而不是每个选项各自一枚独立的圆角按钮：
  // 独立按钮看上去是三个平级的开关，一体轨道才读得出"三选一"。
  // 选中态的颜色直接吃 LEVEL_COLORS（普通灰 / 重要琥珀 / 紧急玫红），
  // 于是"紧急"这个选择本身就有颜色提示，不用再额外写文字说明。

  /** 分段控件里的一个「重要程度」选项 */
  @Builder
  levelChip(lv: number) {
    Text(LEVEL_LABELS[lv])
      .fontSize(14)
      .fontWeight(this.draftLevel === lv ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.draftLevel === lv ? '#FFFFFF' : this.p().textMuted)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .borderRadius(11)
      .backgroundColor(this.draftLevel === lv ? LEVEL_COLORS[lv] : Color.Transparent)
      // 放在属性链最后：它前面的字号/颜色/底色一起过渡，切换时是"化"过去而不是"跳"过去
      .animation({ duration: 200, curve: Curve.Friction })
      .onClick(() => {
        this.draftLevel = lv;
      })
  }

  /** 分段控件里的一个「重复」选项 */
  @Builder
  repeatChip(mode: number) {
    Text(REPEAT_SEG_LABELS[mode])
      .fontSize(14)
      .fontWeight(this.draftRepeat === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.draftRepeat === mode ? '#FFFFFF' : this.p().textMuted)
      .textAlign(TextAlign.Center)
      .height(34)
      .layoutWeight(1)
      .borderRadius(11)
      .backgroundColor(this.draftRepeat === mode ? this.p().accent : Color.Transparent)
      .animation({ duration: 200, curve: Curve.Friction })
      .onClick(() => {
        this.draftRepeat = mode;
      })
  }

  /** 每周模式下的一个星期圆点 */
  @Builder
  weekdayDot(i: number) {
    Text(WEEK_LABELS[i])
      .fontSize(14)
      .fontWeight((this.draftWeekdays & WEEK_BITS[i]) !== 0 ? FontWeight.Medium : FontWeight.Normal)
      .fontColor((this.draftWeekdays & WEEK_BITS[i]) !== 0 ? Color.White : this.p().textMuted)
      .textAlign(TextAlign.Center)
      .width(32)
      .height(36)
      .borderRadius(18)
      .backgroundColor((this.draftWeekdays & WEEK_BITS[i]) !== 0 ? this.p().accent : this.p().cardBgThin)
      .border({ width: 1, color: (this.draftWeekdays & WEEK_BITS[i]) !== 0 ? this.p().accent : this.p().divider })
      .animation({ duration: 200, curve: Curve.Friction })
      .onClick(() => {
        this.toggleWeekday(i);
      })
  }

  /**
   * 截止的一个胶囊。日期和时刻共用这套皮：
   *   · isDate = true  —— 日期胶囊，只有「不重复」才出现（选年月日）
   *   · isDate = false —— 时刻胶囊，两种重复方式都有（选时分秒）
   */
  @Builder
  dueChip(label: string, isDate: boolean) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().dangerText)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([this.p().dangerText])
    }
    .layoutWeight(1)
    .height(40)
    .padding({ left: 12, right: 8 })
    .backgroundColor(this.p().dangerSoftBg)
    .borderRadius(13)
    .border({ width: 1, color: this.p().dangerSoftBorder })
    .animation({ duration: 200, curve: Curve.Friction })
    .onClick(() => {
      if (isDate) {
        this.pickDueDate();
      } else {
        this.pickDueTime();
      }
    })
  }

  /** 日期胶囊上的文案：今天 / 明天 / 10月15日 */
  private dueDateLabel(): string {
    return formatDueLabel(this.draftDueDate);
  }

  /** 时刻胶囊上的文案：不重复只写时刻；循环把周期一起写上（"每天 09:00:00"） */
  private dueTimeLabel(): string {
    const clock: string = formatTimeHMS(this.draftDueTimeMs);
    if (this.draftRepeat === REPEAT_NONE) {
      return clock;
    }
    return `${repeatText(this.draftRepeat, this.draftWeekdays)} ${clock}`;
  }

  /** 提交按钮的文案：跟着重复方式走，比笼统的"定下循环"明确 */
  private submitLabel(): string {
    if (this.draftRepeat === REPEAT_DAILY) {
      return '定下每天';
    }
    if (this.draftRepeat === REPEAT_WEEKLY) {
      return '定下每周';
    }
    return '记下';
  }

  /** 现在能不能提交：空内容、或选了每周却没勾星期，都把按钮压成灰的 */
  private canSubmit(): boolean {
    if (this.draft.trim().length === 0) {
      return false;
    }
    if (this.draftRepeat === REPEAT_WEEKLY && this.draftWeekdays === 0) {
      return false;
    }
    return true;
  }

  @Builder
  createSheet() {
    Column() {
      // ── 标题 ──
      // 不再套一层 Column：直接用两个 Text 顶格，少一层容器就少一层对齐要操心
      Text('记一句')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
        .width('100%')
      Text('几个字就行，你自己看得懂')
        .fontSize(12)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .margin({ top: 4 })

      // ── 输入 ──
      // 聚焦时描边点亮：磨砂玻璃上光看光标位置不够，边框变色给一个明确的"正在这里写"
      TextInput({ text: $$this.draft, placeholder: '比如：买苹果' })
        .width('100%')
        .height(58)
        .fontSize(18)
        .fontColor(this.p().textPrimary)
        .backgroundColor(this.p().cardBgThin)
        .borderRadius(16)
        .border({ width: 1, color: this.inputFocused ? this.p().accent : this.p().divider })
        .placeholderColor(this.p().textTertiary)
        .placeholderFont({ size: 16 })
        .maxLength(MAX_TEXT_LENGTH)
        .margin({ top: 16 })
        .onFocus(() => {
          this.inputFocused = true;
        })
        .onBlur(() => {
          this.inputFocused = false;
        })
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
          this.commitDraft();
        })

      // ── 附带照片 ──
      // 没选时是一个"加一张照片"的按钮；选了就显示缩略图，右上角一个 × 拿掉。
      // 照片是可选的：记一句本来就不要求配图，所以放在输入框下方、不抢戏。
      if (this.draftPhoto.length === 0) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(16)
              .fontColor([this.p().textSecondary])
            Text('加一张照片')
              .fontSize(13)
              .fontColor(this.p().textSecondary)
          }
        }
        .width('100%')
        .height(46)
        .borderRadius(14)
        .backgroundColor(this.p().cardBgThin)
        .border({ width: 1, color: this.p().divider })
        .margin({ top: 12 })
        .onClick(() => {
          this.pickDraftPhoto();
        })
      } else {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(this.draftImage !== null ? this.draftImage : toFileUri(this.draftPhoto))
            .width('100%')
            .aspectRatio(1.5)
            .borderRadius(14)
            .objectFit(ImageFit.Cover)
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(13)
              .fontColor([Color.White])
          }
          .width(24)
          .height(24)
          .backgroundColor('#66000000')
          .borderRadius(12)
          .margin({ top: 8, right: 8 })
          .onClick(() => {
            this.draftPhoto = '';
            this.swapDraftImage(null);
          })
        }
        .width('100%')
        .margin({ top: 12 })
      }

      // ── 重要程度 ──
      // 「标签在左、控件在右」压成一行。原来是标签独占一行、选项再占一行，
      // 两组选择器就是四行，弹框被撑得很长；现在两组一共两行。
      Row() {
        Text('重要程度')
          .fontSize(12)
          .fontColor(this.p().textSecondary)
          .width(SEG_LABEL_WIDTH)
        Row() {
          this.levelChip(LEVEL_NORMAL)
          this.levelChip(LEVEL_IMPORTANT)
          this.levelChip(LEVEL_URGENT)
        }
        .layoutWeight(1)
        .padding(3)
        .backgroundColor(this.p().chip)
        .borderRadius(14)
        .border({ width: 1, color: this.p().chipStrong })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 20 })

      // ── 重复 ──
      Row() {
        Text('重复')
          .fontSize(12)
          .fontColor(this.p().textSecondary)
          .width(SEG_LABEL_WIDTH)
        Row() {
          this.repeatChip(REPEAT_NONE)
          this.repeatChip(REPEAT_DAILY)
          this.repeatChip(REPEAT_WEEKLY)
        }
        .layoutWeight(1)
        .padding(3)
        .backgroundColor(this.p().chip)
        .borderRadius(14)
        .border({ width: 1, color: this.p().chipStrong })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10 })

      // 选了「每周」才展开星期多选。左边缩进到与上面两个控件的左边缘对齐，
      // 一眼读得出它是「重复」的补充，而不是一个平级的新问题。
      if (this.draftRepeat === REPEAT_WEEKLY) {
        Row() {
          Row({ space: 5 }) {
            this.weekdayDot(0)
            this.weekdayDot(1)
            this.weekdayDot(2)
            this.weekdayDot(3)
            this.weekdayDot(4)
            this.weekdayDot(5)
            this.weekdayDot(6)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .padding({ left: 0 })
        .margin({ top: 12 })
      }

      // ── 截止（只有「紧急」才出现） ──
      // 紧急才谈得上"什么时候必须做完"。两段的时间由重复方式决定：
      //   不重复   —— 年月日 + 时分秒 都能挑
      //   每天/每周 —— 只有时分秒能挑，日期由循环自己带（"每天 9:00 截止"）
      // 放在「重复」后面，因为它的形态取决于上面那个选择的结果。
      if (this.draftLevel === LEVEL_URGENT) {
        Row() {
          Text('截止')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width(SEG_LABEL_WIDTH)

          Row({ space: 8 }) {
            if (this.draftRepeat === REPEAT_NONE) {
              this.dueChip(this.dueDateLabel(), true)
            }
            this.dueChip(this.dueTimeLabel(), false)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 10 })
      }

      // ── 底部：字数 + 提交 ──
      Row() {
        Text(`${this.draft.length}/${MAX_TEXT_LENGTH}`)
          .fontSize(12)
          .fontColor(this.p().textTertiary)
        Blank()
        // 文案跟着重复方式走：「定下每天」比笼统的「定下循环」明确；
        // 还不能提交时按钮压成灰的（空内容、或选了每周却没勾星期）
        Button(this.submitLabel())
          .height(46)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.canSubmit() ? this.p().accent : this.p().textQuaternary)
          .borderRadius(23)
          .padding({ left: 30, right: 30 })
          .shadow({
            radius: 14,
            color: this.canSubmit() ? this.p().accentGlow : '#00000000',
            offsetX: 0,
            offsetY: 5
          })
          .animation({ duration: 200, curve: Curve.Friction })
          .onClick(() => {
            this.commitDraft();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 24 })
    }
    .width('100%')
    // 顶部给手势条留出 12：拖拽条和右上角关闭按钮都占着顶上那一小块
    .padding({ left: 20, right: 20, top: 12, bottom: 24 })
  }

  // ---------------- 详细信息卡片 ----------------

  private detailValue(label: string): string {
    if (label === '状态') { return this.detailDone ? '已完成' : '未完成'; }
    if (label === '重复') { return this.detailRepeatText(); }
    if (label === '截止') { return this.detailDueText(); }
    if (label === '来自') { return this.detailFrom; }
    return this.detailTime;
  }

  private detailValueColor(label: string): string {
    if (label === '状态') { return this.detailDone ? this.p().textMeta : this.p().accentText; }
    if (label === '截止' && !this.detailDone && isOverdue(this.detailDueAt)) { return this.p().dangerText; }
    return label === '记录' ? this.p().textSecondary : this.p().textPrimary;
  }

  /** 详情卡里的一行：左标签、右取值 */
  @Builder
  detailRow(label: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.p().textSecondary)
        .width(52)
      Text(this.detailValue(label))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.detailValueColor(label))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  /**
   * 单击泡泡后翻开的玻璃卡。
   * 尺寸不铺满是有意的 —— 留出四周，让背后那片渐变和泡泡还看得见，
   * 读起来像"浮在桌面上的一张卡"，而不是切了一个新页面。
   */
  @Builder
  detailCard() {
    Column() {
      Column().width(32).height(4).borderRadius(2).backgroundColor(this.p().dividerStrong)
        .margin({ bottom: 12 })
      // ── 顶行：等级 + 关闭 ──
      Row() {
        Row({ space: 6 }) {
          // 普通不加点：一行小字前面挂个灰点反而脏
          if (this.detailLevel !== LEVEL_NORMAL) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(LEVEL_COLORS[this.detailLevel])
          }
          Text(levelLabel(this.detailLevel))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(levelColor(this.detailLevel))
        }

        Blank()

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(17)
          .fontColor([this.p().textSecondary])
          .width(30)
          .height(30)
          .onClick(() => {
            this.closeDetail();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ── 就是那句话 ──
      Text(this.detailText)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 12 })

      // 附带照片：有图才显示，点一下全屏看。整张卡片不铺满，照片也收着圆角，
      // 让它像卡上的一张小图，而不是把卡片撑成图册。
      if (this.detailPhoto.length > 0) {
        Image(this.detailImage !== null ? this.detailImage : toFileUri(this.detailPhoto))
          .width('100%')
          .aspectRatio(1.6)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
          .margin({ top: 14 })
          .onClick(() => {
            this.previewPhoto = this.detailPhoto;
            this.previewImage = this.detailImage;
          })
      }

      Divider()
        .strokeWidth(1)
        .color(this.p().shadowSoft)
        .margin({ top: 16, bottom: 4 })

      this.detailRow('状态')
      this.detailRow('重复')
      // 截止只有紧急才有；逾期了就把这一行的颜色点起来
      if (this.detailDueAt > 0) {
        this.detailRow('截止')
      }
      if (this.detailFrom.length > 0) {
        this.detailRow('来自')
      }
      this.detailRow('记录')

      Row({ space: 10 }) {
        Button(this.detailDone ? '回到未完成' : '标记完成')
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.p().accent)
          .borderRadius(22)
          .layoutWeight(1)
          .onClick(() => {
            this.toggleDetailDone();
          })

        Button('删掉')
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().danger)
          .backgroundColor(this.p().dangerSoftBg)
          .borderRadius(22)
          .layoutWeight(1)
          .onClick(() => {
            this.deleteFromDetail();
          })
      }
      .width('100%')
      .margin({ top: 18 })
    }
    .width('92%')
    .margin({ bottom: this.getUIContext().px2vp(this.bottomSafeAreaPx) + 20 })
    .padding({ left: 22, right: 22, top: 18, bottom: 22 })
    .borderRadius(26)
    .backgroundColor(this.p().cardBg)
    // 和新建弹框同一档磨砂：卡片是"玻璃"，不是白纸
    .border({ width: 1, color: this.p().glassBorderStrong })
    .shadow({ radius: 30, color: this.p().shadowCard, offsetX: 0, offsetY: 12 })
    // 空 onClick 是必要的：不吃掉这次点击，它会穿到下面的遮罩上、卡片刚弹出来就被收掉
    .onClick(() => {
    })
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
        .animation({ duration: 220, curve: Curve.Friction })
    )
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // ---- 日期栏 ----
        this.brandHeader()
        this.dateBar()

        Column() {
          // ---- 上半区：已完成 ----
          Stack() {
            ForEach(this.doneBubbles, (item: Bubble) => {
              BubbleView({
                bubble: item,
                onHoldAction: () => {
                  this.launchBubble(item);
                },
                onDragStartAction: () => {
                  this.startDrag(item);
                },
                onDragMoveAction: (dx: number, dy: number) => {
                  this.moveDrag(item, dx, dy);
                },
                onDragEndAction: () => {
                  this.endDrag(item);
                },
                onTapAction: () => {
                  this.openDetail(item);
                },
                onDoubleTapAction: () => {
                  this.confirmDelete(item);
                }
              })
            }, (item: Bubble) => `done_${item.id}`)

            if (this.doneBubbles.length === 0) {
              this.emptyHint(true)
            }
            this.areaHeader(true)
          }
          .width('calc(100% - 32vp)')
          .layoutWeight(1)
          .alignContent(Alignment.TopStart)
          .borderRadius(26)
          .attributeModifier(new FrostedContentModifier(this.themeDark, this.p().cardBg, this.p().glassBorder))
          // 平时裁掉圆角外的部分；拖动时放开，泡泡才能"走"到对面让人看见
          .clip(this.draggingId < 0)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.doneW = newValue.width as number;
            this.doneH = newValue.height as number;
            this.engine.layoutArea(true, this.doneW, this.doneH);
            this.startEngineIfReady();
          })
          .margin({ left: 16, right: 16, bottom: 0 })

          Row({ space: 12 }) {
            Divider().width(28).color(this.p().dividerStrong)
            Text('拖到上方，就办完了').fontSize(11).fontColor(this.p().textTertiary)
            Divider().width(28).color(this.p().dividerStrong)
          }
          .height(30).width('100%').justifyContent(FlexAlign.Center)

          // ---- 下半区：未完成 ----
          Stack() {
            ForEach(this.todoBubbles, (item: Bubble) => {
              BubbleView({
                bubble: item,
                onHoldAction: () => {
                  this.launchBubble(item);
                },
                onDragStartAction: () => {
                  this.startDrag(item);
                },
                onDragMoveAction: (dx: number, dy: number) => {
                  this.moveDrag(item, dx, dy);
                },
                onDragEndAction: () => {
                  this.endDrag(item);
                },
                onTapAction: () => {
                  this.openDetail(item);
                },
                onDoubleTapAction: () => {
                  this.confirmDelete(item);
                }
              })
            }, (item: Bubble) => `todo_${item.id}`)

            if (this.todoBubbles.length === 0) {
              this.emptyHint(false)
            }
            this.areaHeader(false)
          }
          .width('calc(100% - 32vp)')
          .layoutWeight(1)
          .alignContent(Alignment.TopStart)
          .borderRadius(26)
          .attributeModifier(new FrostedContentModifier(this.themeDark, this.p().cardBg, this.p().glassBorder))
          .clip(this.draggingId < 0)
          .margin({ left: 16, right: 16, bottom: 14 })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.todoW = newValue.width as number;
            this.todoH = newValue.height as number;
            this.engine.layoutArea(false, this.todoW, this.todoH);
            this.startEngineIfReady();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .opacity(this.contentOpacity)
      }
      .width('100%')
      .height('100%')
      // 顶部让出状态栏与日期栏，底部留出悬浮页签的高度
      .padding({
        top: this.getUIContext().px2vp(this.topSafeAreaPx) + 10,
        // 底栏与新建按钮同一行，内容只需避让这一行。
        bottom: this.getUIContext().px2vp(this.bottomSafeAreaPx) + 88
      })
      // 新建入口已移到 Index 层：页签栏右侧那枚独立的沉浸光感圆钮
      // （点击后由 CREATE_REQUEST_KEY 信号回到这里触发 onCreateRequest）

      // ---- 详细信息：淡遮罩 + 居中玻璃卡 ----
      // 遮罩压得很淡（#26），背后那片渐变和泡泡还在动，像卡片浮在桌面上；
      // 点任意空白处收起。内层另起一个居中的 Stack，是因为外层是 BottomEnd 对齐的。
      if (this.detailShown) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.p().scrim)
            .onClick(() => {
              this.closeDetail();
            })
            .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))

          this.detailCard()
        }
        .width('100%')
        .height('100%')
      }

      // ---- 日历：写在详情卡之后，保证它叠在最上层 ----
      if (this.calShown) {
        this.calendarOverlay()
      }

      // ---- 照片全屏预览：压在最上层 ----
      if (this.previewPhoto.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#E6000000')
            .onClick(() => {
              this.previewPhoto = '';
              this.previewImage = null;
            })
          Image(this.previewImage !== null ? this.previewImage : toFileUri(this.previewPhoto))
            .width('92%')
            .height('72%')
            .borderRadius(16)
            .objectFit(ImageFit.Contain)
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetShown, this.createSheet(), {
      // 按内容自适应高度：加了两组选择器后固定 300 会截断
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      // 磨砂玻璃：与页面里的沉浸光感材质同一套观感
      backgroundColor: this.p().cardBg,
      // 蒙层压淡一点，玻璃才透得出背后的渐变
      maskColor: this.p().scrimSheet,
      onDisappear: () => {
        this.sheetShown = false;
      }
    })
  }
}
