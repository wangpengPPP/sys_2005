import { curves } from '@kit.ArkUI';
import { HomePage } from '../views/HomePage';
import { FriendsPage } from '../views/FriendsPage';
import { MinePage } from '../views/MinePage';
import { DOCK_MATERIAL, isImmersiveMaterialSupported } from '../common/AppMaterial';
import { CALENDAR_VISIBLE_KEY, CREATE_REQUEST_KEY, CARD_ENTRY_KEY, DETAIL_VISIBLE_KEY } from '../common/AppEvents';
import { AppPalette, AppTheme, THEME_VERSION_KEY, THEME_DARK_KEY } from '../common/AppTheme';
import { HAND_VERSION_KEY, HandSense } from '../common/HandSense';

const BAR_BOTTOM_GAP: number = 10;

const DOCK_HEIGHT: number = 64;
const FAB_SIZE: number = DOCK_HEIGHT;
const FAB_GAP: number = 12;
/** 还没分开时按钮往里缩的距离：看着像"从栏里长出来"，而不是贴边浮着 */
const FAB_TUCK: number = 28;

const TAB_HOME: number = 0;

class DockMaterialModifier implements AttributeModifier<CommonAttribute> {
  private supported: boolean;
  private fallbackColor: ResourceColor;
  private fallbackBorder: ResourceColor;

  constructor(supported: boolean, fallbackColor: ResourceColor, fallbackBorder: ResourceColor) {
    this.supported = supported;
    this.fallbackColor = fallbackColor;
    this.fallbackBorder = fallbackBorder;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (this.supported) {
      // 系统材质自己管底色、描边和阴影，不要再叠 backgroundColor / border / shadow——
      // 官方明确说这几个属性和材质互斥，叠上去等于把材质挡掉。
      instance.systemMaterial(DOCK_MATERIAL);
    } else {
      instance.backgroundColor(this.fallbackColor)
        .border({ width: 1, color: this.fallbackBorder });
    }
  }
}

@Entry
@Component
struct Index {

  @StorageProp(THEME_VERSION_KEY) themeVersion: number = 0;
  @StorageProp(THEME_DARK_KEY) themeDark: boolean = AppTheme.isDark();
  @StorageLink(DETAIL_VISIBLE_KEY) detailVisible: boolean = false;
  @StorageLink(CALENDAR_VISIBLE_KEY) calendarVisible: boolean = false;

  /**
   * 主页上有没有盖着全屏弹层（详情卡 / 日历）。
   *
   * 两者都要让底栏和新建钮让开：它们都铺了一层淡遮罩，
   * 底栏留在上面会显得像是"浮在弹层之上"的另一套界面。
   */
  private overlayShown(): boolean {
    return this.detailVisible || this.calendarVisible;
  }

  private p(): AppPalette {
    return AppTheme.palette(this.themeDark);
  }

  private controller: TabsController = new TabsController();

  @StorageProp('bottomSafeAreaPx') bottomSafeAreaPx: number = 0;

  @State currentTab: number = TAB_HOME;

  @State fabProgress: number = 0;
  @State dockWidth: number = 336;
  /**
   * 底栏那层系统材质（沉浸光感）在本机能不能用。
   *
   * 只问一次：设备算力档与 API 版本不会在运行期变化。
   * 拿不到就退回半透明底色，观感差一档但不会变成一块空白。
   */
  private immersiveDock: boolean = isImmersiveMaterialSupported();
  private entryTimer: number = -1;

  @StorageProp(CARD_ENTRY_KEY) @Watch('onCardEntry') cardEntryTick: number = 0;

  /** 握姿版本号：系统识别到的握持手变了，或者用户在设置里手动锁了某只手 */
  @StorageProp(HAND_VERSION_KEY) @Watch('onHandChanged') handVersion: number = 0;

  /**
   * 左右位移的连续量：0 = 右手（按钮在右），1 = 左手（按钮在左）。
   *
   * 不直接用布尔值，是因为换手时要让它滑过去而不是瞬移 —— 一个 0→1 的插值
   * 就能让按钮和导航条同时、同速地换边，跟主题那套"只改数据"是一个路子。
   */
  @State handShift: number = 0;
  /** 根容器尺寸（vp）：落点推断要拿它换算落点在屏幕的哪一侧 */
  @State rootHeight: number = 0;
  @State rootWidth: number = 0;

  aboutToAppear(): void {
    this.fabProgress = 0;
    this.handShift = HandSense.isLeft() ? 1 : 0;
    this.entryTimer = setTimeout(() => {
      this.entryTimer = -1;
      if (this.currentTab === TAB_HOME) {
        this.emergeFab();
      }
    }, 150);
  }

  aboutToDisappear(): void {
    if (this.entryTimer >= 0) {
      clearTimeout(this.entryTimer);
      this.entryTimer = -1;
    }
  }

  /** 握姿变了：滑到新的一边 */
  private onHandChanged(): void {
    const target: number = HandSense.isLeft() ? 1 : 0;
    if (Math.abs(target - this.handShift) < 0.001) {
      return;
    }
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.handShift = target;
    });
  }

  /**
   * 记一次落点，交给握姿感知去判断用户拿的是哪只手。
   *
   * 只在系统握姿感知不可用时才有意义（HandSense 内部会挡掉），
   * 这里负责两件它不知道的事：**剔掉底栏那一条**，以及剔掉弹层。
   */
  private onRootTouch(event: TouchEvent): void {
    if (this.overlayShown() || this.rootWidth <= 0) {
      return;
    }
    const touches: TouchObject[] = event.touches;
    if (touches.length === 0 || touches[0].type !== TouchType.Down) {
      return;
    }
    // 底栏 + 新增按钮这一条不能算：它们自己会跟着换边，
    // 算进去就是拿自己的结论当证据，按钮挪到哪边、样本就偏哪边
    const dockTop: number = this.rootHeight - (DOCK_HEIGHT + this.barBottomMargin() + 12);
    if (this.rootHeight > 0 && touches[0].y > dockTop) {
      return;
    }
    HandSense.sample(touches[0].x, this.rootWidth);
  }

  private separation(): number {
    return Math.max(0, Math.min(1, this.fabProgress));
  }

  private squeeze(): number {
    return Math.sin(Math.PI * this.separation());
  }

  /** 新增按钮的横坐标：右手贴右边、左手贴左边，合并时都往栏里缩一截 */
  private fabX(): number {
    const tuck: number = FAB_TUCK * (1 - this.separation());
    const right: number = this.dockWidth - FAB_SIZE - tuck;
    const left: number = tuck;
    return right + (left - right) * this.handShift;
  }

  /** 导航条给按钮让位的位移：左手时整条往右挪，右手时不动 */
  private barX(): number {
    return (FAB_SIZE + FAB_GAP) * this.separation() * this.handShift;
  }

  /** 加号的倾斜角：右手 -35°，左手 +35°，镜像一下就对了 */
  private plusTilt(): number {
    return (-35 + 70 * this.handShift) * (1 - this.separation());
  }

  @Builder
  navItem(index: number, label: string, normal: Resource, selected: Resource) {
    Column({ space: 3 }) {
      SymbolGlyph(this.currentTab === index ? selected : normal)
        .fontSize(24)
        .fontColor([this.currentTab === index ? this.p().accentText : this.p().textTertiary])
      Text(label)
        .fontSize(11)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTab === index ? this.p().accentText : this.p().textSecondary)
    }
    .height(DOCK_HEIGHT - 12)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .borderRadius(24)
    .backgroundColor(this.currentTab === index ? this.p().accentSoft : Color.Transparent)
    .accessibilityText(label)
    .onClick(() => {
      this.controller.changeIndex(index);
      this.onTabSelected(index);
    })
  }

  private barBottomMargin(): number {
    return this.getUIContext().px2vp(this.bottomSafeAreaPx) + BAR_BOTTOM_GAP;
  }

  private onTabSelected(index: number): void {
    if (index === this.currentTab) {
      return;
    }
    const wasHome: boolean = this.currentTab === TAB_HOME;
    this.currentTab = index;
    if (index === TAB_HOME) {
      this.emergeFab();
    } else if (wasHome) {
      // 仅离开主页时合入；好友与我的互切不重播新增按钮的中间帧。
      this.retractFab();
    }
  }

  private onCardEntry(): void {
    this.detailVisible = false;
    this.calendarVisible = false;
    if (this.currentTab !== TAB_HOME) {
      this.controller.changeIndex(TAB_HOME);
      this.currentTab = TAB_HOME;
      this.emergeFab();
    }
    setTimeout(() => {
      AppStorage.setOrCreate<number>(CREATE_REQUEST_KEY, Date.now());
    }, 260);
  }

  private emergeFab(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 160, curve: Curve.EaseOut, event: () => { this.fabProgress = 0.48; } },
      { duration: 230, curve: curves.cubicBezierCurve(0.16, 1, 0.3, 1),
        event: () => { this.fabProgress = 1.035; } },
      { duration: 130, curve: Curve.EaseOut, event: () => { this.fabProgress = 1; } }
    ]);
  }

  private retractFab(): void {
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 170, curve: Curve.EaseInOut, event: () => { this.fabProgress = 0.45; } },
      { duration: 210, curve: curves.cubicBezierCurve(0.2, 0.8, 0.2, 1),
        event: () => { this.fabProgress = 0; } }
    ]);
  }

  onBackPress(): boolean {
    // 先收日历：它是后开的，也叠在上面（详情卡开着时点不到日期栏，
    // 两者不会同时存在，但顺序按"最后开的先关"写更稳妥）
    if (this.calendarVisible) {
      this.calendarVisible = false;
      return true;
    }
    if (this.detailVisible) {
      this.detailVisible = false;
      return true;
    }
    return false;
  }

  // 必须挂在 Tabs 的 tabBar 里：组件级沉浸光感只认两个位置——Navigation/NavDestination
  // 标题栏，或 barPosition 为 BarPosition.End 的横向 Tabs 的底部 TabBar。
  // 这里正好是后者（见 build() 里的 Tabs），挪到普通 Stack 里就会静默失效。
  @Builder
  dockBar() {
    // 按钮先画，栏体后画：重合阶段由栏体盖住按钮左侧，形成分离/融入的轮廓。
    Stack({ alignContent: Alignment.Start }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(26)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.p().accentText])
          .rotate({ angle: this.plusTilt() })
      }
      .width(FAB_SIZE)
      .height(FAB_SIZE)
      .borderRadius(FAB_SIZE / 2)
      .attributeModifier(new DockMaterialModifier(this.immersiveDock, this.p().cardBg,
        this.p().glassBorderStrong))
      .accessibilityText('记一句')
      .scale({
        x: 0.2 + 0.8 * this.fabProgress + 0.28 * this.squeeze(),
        y: 0.2 + 0.8 * this.fabProgress - 0.12 * this.squeeze()
      })
      .opacity(Math.max(0, Math.min(1, (this.separation() - 0.12) / 0.65)))
      .position({ x: this.fabX(), y: 0 })
      .hitTestBehavior(this.currentTab === TAB_HOME && !this.overlayShown()
        ? HitTestMode.Default : HitTestMode.None)
      .onClick(() => {
        AppStorage.setOrCreate<number>(CREATE_REQUEST_KEY, Date.now());
      })

      Row({ space: 6 }) {
        this.navItem(0, '主页', $r('sys.symbol.house'), $r('sys.symbol.house_fill'))
        this.navItem(1, '好友', $r('sys.symbol.person_2'), $r('sys.symbol.person_2_fill'))
        this.navItem(2, '我的', $r('sys.symbol.person'), $r('sys.symbol.person_fill'))
      }
      .width(this.dockWidth - (FAB_SIZE + FAB_GAP) * this.fabProgress)
      .height(DOCK_HEIGHT)
      .padding(6)
      .borderRadius(DOCK_HEIGHT / 2)
      .attributeModifier(new DockMaterialModifier(this.immersiveDock, this.p().cardBg,
        this.p().glassBorderStrong))
      .scale({ x: 1, y: 1 - 0.045 * this.squeeze(), centerY: '50%' })
      .position({ x: this.barX(), y: 0 })
    }
    .width('calc(100% - 32vp)')
    .height(DOCK_HEIGHT)
    .margin({ left: 16, right: 16, bottom: this.barBottomMargin() })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const width: number = newArea.width as number;
      if (width > 0 && Math.abs(width - this.dockWidth) > 0.5) {
        this.dockWidth = width;
      }
    })
    .visibility(this.overlayShown() ? Visibility.Hidden : Visibility.Visible)
  }

  build() {
    WithTheme({ colorMode: this.themeDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [this.p().bg1, 0.0],
            [this.p().bg2, 0.42],
            [this.p().bg3, 0.76],
            [this.p().bg4, 1.0]
          ]
        })

      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          Tabs({ controller: this.controller }) {
            TabContent() { HomePage() }
            TabContent() { FriendsPage() }
            TabContent() { MinePage() }
          }
          .width('100%')
          .height('100%')
          .barHeight(0)
          .scrollable(false)
          .animationDuration(180)
          .onChange((index: number) => { this.onTabSelected(index); })
        }
        .tabBar(this.dockBar())
      }
      .width('100%')
      .height('100%')
      .barHeight(this.overlayShown() ? 0 : DOCK_HEIGHT + this.barBottomMargin())
      .barOverlap(true)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .divider(null)
      .scrollable(false)
      .animationDuration(0)
    }
    .width('100%')
    .height('100%')
    // 落点推断的兜底：传感器不支持时，靠用户在屏幕哪一侧点来猜握持手
    .onTouch((event: TouchEvent) => {
      this.onRootTouch(event);
    })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rootWidth = newArea.width as number;
      this.rootHeight = newArea.height as number;
    })
    }
  }
}
