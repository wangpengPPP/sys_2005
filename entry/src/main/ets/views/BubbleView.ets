import {
  Bubble,
  LEVEL_IMPORTANT,
  LEVEL_URGENT,
  bubbleFontSize,
  levelColor,
  levelNeedsBadge
} from '../model/BubbleModel';
import { isDueToday, isOverdue } from '../common/DateUtil';
import { repeatText } from '../model/RepeatModel';
import { friendAccent } from '../model/FriendModel';
import { AppPalette, AppTheme, THEME_VERSION_KEY, THEME_DARK_KEY } from '../common/AppTheme';

/**
 * 泡泡：一枚透明玻璃球
 *
 * 由五层叠出来：
 *   ① 球体      —— 半透明白 + 沉浸光感材质 + 一圈亮边 + 外投影
 *   ② 薄膜      —— 斜向虹彩渐变，模拟肥皂泡的薄膜干涉色
 *   ③ 主高光    —— 左上一道柔和亮斑
 *   ④ 次反光    —— 右下一点小亮斑
 *   ⑤ 文字      —— 那句「提示」，居中
 *
 * 手势：
 *   - 拖动（Pan）   ：把泡泡拖到对面区域 = 改变完成状态
 *   - 按住（Long）  ：未完成区的泡泡瞬间向上发射 = 变成已完成
 *   - 单击（Tap×1） ：翻开这条的「详细信息」
 *   - 双击（Tap×2） ：删除
 *
 * 位置由 @ObjectLink 直接驱动：物理引擎改了 bubble.cx/cy，这里只重绘这一颗。
 */

/**
 * 两次点击落在这个窗口内就按双击算。
 * ArkUI 的单/双击竞合由 handleTap 自己实现，理由见那里的注释。
 */
const DOUBLE_TAP_WINDOW_MS: number = 260;

@Component
export struct BubbleView {
  /** 主题版本号：切换主题时 +1，这一页跟着重画（见 common/AppTheme.ets） */
  @StorageProp(THEME_VERSION_KEY) themeVersion: number = 0;
  @StorageProp(THEME_DARK_KEY) themeDark: boolean = AppTheme.isDark();

  /** 当前这套配色 */
  private p(): AppPalette {
    return AppTheme.palette(this.themeDark);
  }

  @ObjectLink bubble: Bubble;
  /** 按住：未完成区的泡泡向上发射 */
  onHoldAction: () => void = () => {
  };
  /** 拖拽开始 */
  onDragStartAction: () => void = () => {
  };
  /** 拖拽中，dx/dy 是相对按下点的累计位移（vp） */
  onDragMoveAction: (dx: number, dy: number) => void = (dx: number, dy: number) => {
  };
  /** 拖拽结束（含被系统取消） */
  onDragEndAction: () => void = () => {
  };
  /** 单击：翻开这条的详细信息 */
  onTapAction: () => void = () => {
  };
  /** 双击删除 */
  onDoubleTapAction: () => void = () => {
  };

  /** 上一次单击的时间戳，用来自己分辨单击还是双击 */
  private lastTapTs: number = 0;

  private diameter(): number {
    return this.bubble.r * 2;
  }

  /**
   * 第二行的「截止告急」文案 —— 只报逾期和今天到期两种。
   * 还有好几天的截止不往泡泡上塞（泡泡就这么大），想看具体几号，
   * 单击翻详情。
   */
  private dueText(): string {
    if (this.bubble.done || this.bubble.dueAt <= 0) {
      return '';
    }
    if (isOverdue(this.bubble.dueAt)) {
      return '已逾期';
    }
    if (isDueToday(this.bubble.dueAt)) {
      return '今天截止';
    }
    return '';
  }

  /**
   * 单击 / 双击的分派。
   *
   * 没用「TapGesture(count:2) 配 onClick」那种直观写法：同一节点上这两个手势会互相竞争，
   * 结果不是单击被吃掉、就是单击必须等双击超时才响应，两头都不讨好。
   * 这里只挂一个 TapGesture(count:1)，靠时间窗口自己分辨 ——
   * 单击先挂起，窗口内若来了第二次就取消挂起、改判双击。
   */
  private handleTap(): void {
    const now: number = Date.now();
    if (now - this.lastTapTs < DOUBLE_TAP_WINDOW_MS) {
      this.lastTapTs = 0;
      this.onDoubleTapAction();
      return;
    }
    this.lastTapTs = now;
    setTimeout(() => {
      // 这期间没被第二次点击清掉，才真的算单击
      if (this.lastTapTs === now) {
        this.lastTapTs = 0;
        this.onTapAction();
      }
    }, DOUBLE_TAP_WINDOW_MS);
  }

  /** 给虹彩色补透明度，ArkUI 颜色串是 #AARRGGBB（alpha 在最前） */
  private tintWithAlpha(alphaHex: string): string {
    const tint: string = this.bubble.level === LEVEL_URGENT ? '#FF819C'
      : (this.bubble.level === LEVEL_IMPORTANT ? '#EFBD6A' : this.bubble.tint);
    return `#${alphaHex}${tint.substring(1)}`;
  }

  build() {
    Stack() {
      // ① 球体
      Column()
        .width(this.diameter())
        .height(this.diameter())
        .borderRadius(this.bubble.r)
        .backgroundColor(this.bubble.done ? this.p().bubbleFillDone : this.p().bubbleFill)
        .border({ width: 1, color: this.bubble.done ? this.p().bubbleBorderDone : (this.themeDark ? this.tintWithAlpha('BF') : this.p().bubbleBorder) })
        .shadow({ radius: this.themeDark ? 10 : 16, color: this.themeDark ? this.tintWithAlpha(this.bubble.done ? '20' : '55') : this.p().shadowSoft, offsetX: 0, offsetY: 3 })

      // ①-b 好友发来的：描一圈发送者的颜色，一眼看出"这不是我自己记的"
      if (this.bubble.fromUid.length > 0) {
        Column()
          .width(this.diameter())
          .height(this.diameter())
          .borderRadius(this.bubble.r)
          .border({ width: 2, color: friendAccent(this.bubble.fromUid) })
          .opacity(0.9)
      }

      // ② 薄膜虹彩
      Column()
        .width(this.diameter() - 2)
        .height(this.diameter() - 2)
        .borderRadius(this.bubble.r)
        .opacity(this.bubble.done ? 0.45 : 1)
        .linearGradient({
          angle: 145,
          colors: [
            [this.tintWithAlpha(this.themeDark ? '55' : '4D'), 0.0],
            ['#00FFFFFF', 0.52],
            [this.tintWithAlpha('33'), 1.0]
          ]
        })

      // 深色球体的彩色边缘：渐变画在原生组件上，随拖动一起移动。
      if (this.themeDark) {
        Column()
          .width(this.diameter() - 2)
          .height(this.diameter() - 2)
          .borderRadius(this.bubble.r)
          .opacity(this.bubble.done ? 0.35 : 0.9)
          .radialGradient({
            center: ['50%', '50%'],
            radius: this.bubble.r - 1,
            colors: [
              [this.tintWithAlpha('00'), 0.0],
              [this.tintWithAlpha('00'), 0.72],
              [this.tintWithAlpha('30'), 0.91],
              [this.tintWithAlpha('B3'), 0.98],
              [this.tintWithAlpha('40'), 1.0]
            ]
          })
      }

      // ③ 主高光
      Column()
        .width(this.bubble.r * 0.74)
        .height(this.bubble.r * 0.44)
        .borderRadius(this.bubble.r * 0.34)
        .linearGradient({
          angle: 165,
          colors: [[this.p().bubbleBorder, 0.0], ['#00FFFFFF', 1.0]]
        })
        .position({ x: this.bubble.r * 0.40, y: this.bubble.r * 0.32 })
        .opacity(this.themeDark ? 0.55 : 1)

      // ④ 次反光
      Column()
        .width(this.bubble.r * 0.30)
        .height(this.bubble.r * 0.18)
        .borderRadius(this.bubble.r * 0.14)
        .linearGradient({
          angle: 20,
          colors: [['#00FFFFFF', 0.0], [this.p().bubbleBorder, 1.0]]
        })
        .position({ x: this.bubble.r * 1.02, y: this.bubble.r * 1.34 })

      // ⑤ 文字（好友发来的多一行落款）
      Column({ space: 1 }) {
        Text(this.bubble.text)
          .fontSize(bubbleFontSize(this.bubble.text))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.bubble.done ? this.p().bubbleTextDone : this.p().bubbleText)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width(this.diameter() * 0.80)

        // 第二行只放一样东西，优先级：好友落款 > 截止告急 > 循环文案
        if (this.bubble.fromUid.length > 0) {
          Text(`· ${this.bubble.fromName} ·`)
            .fontSize(9)
            .fontColor(friendAccent(this.bubble.fromUid))
            .opacity(0.85)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(this.diameter() * 0.78)
            .textAlign(TextAlign.Center)
        } else if (this.dueText().length > 0) {
          Text(this.dueText())
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().dangerText)
            .opacity(0.95)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(this.diameter() * 0.78)
            .textAlign(TextAlign.Center)
        } else if (this.bubble.repeat > 0) {
          Text(repeatText(this.bubble.repeat, this.bubble.weekdays))
            .fontSize(9)
            .fontColor(this.bubble.done ? this.p().bubbleTextDone : this.p().bubbleSubText)
            .opacity(0.9)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(this.diameter() * 0.78)
            .textAlign(TextAlign.Center)
        }
      }
      .width(this.diameter())

      // ⑥ 重要程度角标（普通不显示）：右上角一颗色点，紧急的带一圈光晕
      if (levelNeedsBadge(this.bubble.level)) {
        if (this.bubble.level === LEVEL_URGENT) {
          Column()
            .width(this.bubble.r * 0.56)
            .height(this.bubble.r * 0.56)
            .borderRadius(this.bubble.r * 0.28)
            .backgroundColor(levelColor(this.bubble.level))
            .opacity(0.30)
            .position({ x: this.bubble.r * 1.34, y: this.bubble.r * 0.02 })
        }
        Column()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(levelColor(this.bubble.level))
          .border({ width: 1, color: this.p().dividerStrong })
          .position({ x: this.bubble.r * 1.52, y: this.bubble.r * 0.18 })
      }

      // ⑦ 选中光环：详情卡正指着这一颗时套一圈主题色，比球体大 10vp、四周均匀溢出
      if (this.bubble.focused) {
        Column()
          .width(this.diameter() + 10)
          .height(this.diameter() + 10)
          .borderRadius((this.diameter() + 10) / 2)
          .border({ width: 2, color: this.p().accentHalo })
          .shadow({ radius: 12, color: this.p().accentGlow, offsetX: 0, offsetY: 0 })
      }
    }
    .width(this.diameter())
    .height(this.diameter())
    // 属性顺序是有意的：animation() 只作用于它**之前**的属性，
    // 所以 scale 排在它前面、translate 排在它后面 ——
    // 否则物理引擎逐帧改的 cx/cy 会被套上 200ms 过渡，泡泡会拖出一条尾巴
    .scale({
      x: this.bubble.dragging ? 1.08 : (this.bubble.focused ? 1.12 : 1),
      y: this.bubble.dragging ? 1.08 : (this.bubble.focused ? 1.12 : 1)
    })
    // 拖动中的泡泡浮到最上层、被指着的那枚次之，保证光环不被别的泡泡盖住
    .zIndex(this.bubble.dragging ? 99 : (this.bubble.focused ? 50 : 0))
    .animation({ duration: 200, curve: Curve.Friction })
    .translate({
      x: this.bubble.cx - this.bubble.r,
      y: this.bubble.cy - this.bubble.r
    })
    .gesture(
      GestureGroup(
        GestureMode.Exclusive,
        // 按住不动 → 发射（移动超过阈值会失败，让位给拖动）
        LongPressGesture({ repeat: false, duration: 420 })
          .onAction((event: GestureEvent) => {
            this.onHoldAction();
          }),
        PanGesture({ fingers: 1, distance: 4 })
          .onActionStart(() => {
            this.onDragStartAction();
          })
          .onActionUpdate((event: GestureEvent) => {
            // GestureEvent.offsetX/offsetY 的单位**已经是 vp**（SDK：relative to the finger press
            // position, in vp），绝不能再 px2vp —— 转一次等于除以屏幕密度，
            // 泡泡只走手指的 1/3，表现就是"不跟手"
            this.onDragMoveAction(event.offsetX, event.offsetY);
          })
          .onActionEnd(() => {
            this.onDragEndAction();
          })
          .onActionCancel(() => {
            this.onDragEndAction();
          }),
        // 单击 / 双击都从这一个手势进来，由 handleTap 按时间窗口分派。
        // 只放 count:1 —— Exclusive 组里只会有一个手势胜出，
        // 因此「按住发射」不会在抬手时又漏出一次点击，反之亦然。
        TapGesture({ count: 1 })
          .onAction((event: GestureEvent) => {
            this.handleTap();
          })
      )
    )
  }
}
