import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ACCOUNT_VERSION_KEY, FRIEND_VERSION_KEY, TodoService } from '../service/TodoService';
import { HwAccount, HuaweiAccount } from '../service/agc/HuaweiAccount';
import { SENSOR_KIND_KEY } from '../model/BubbleEngine';
import { StatusBarService, STATUS_TEXT_KEY } from '../service/live/StatusBarService';
import { DeadlineReminderService, DEADLINE_REMINDER_KEY } from '../service/DeadlineReminderService';
import { FormCardService } from '../service/FormCardService';
import { BubbleStore } from '../model/BubbleStore';
import { levelColor, levelLabel, levelNeedsBadge } from '../model/BubbleModel';
import { REPEAT_VERSION_KEY, RepeatRule, repeatText } from '../model/RepeatModel';
import { AppPalette, AppTheme, ThemeMode, THEME_VERSION_KEY, THEME_DARK_KEY } from '../common/AppTheme';
import { HAND_VERSION_KEY, HandMode, HandSense } from '../common/HandSense';
import { getMaterialCapability, MaterialCapability } from '../common/AppMaterial';

/**
 * 隐私政策网址。
 *
 * 为什么必须在 App 里放一个入口：华为应用市场上架（含邀请测试）要求
 * 应用内**可访问**隐私政策，只在 AGC 后台填个链接不够，审核会打回。
 */
const PRIVACY_URL: string = 'https://lingxing-privacy.app.workbuddy.host/';

/**
 * 我的页：卡片使用主题配色，底栏的系统沉浸材质由 Index.ets 统一管理。
 */
@Component
export struct MinePage {
  /** 主题版本号：切换主题时 +1，这一页跟着重画（见 common/AppTheme.ets） */
  @StorageProp(THEME_VERSION_KEY) @Watch('syncTheme') themeVersion: number = 0;
  @StorageProp(THEME_DARK_KEY) themeDark: boolean = AppTheme.isDark();

  /** 当前这套配色 */
  private p(): AppPalette {
    return AppTheme.palette(this.themeDark);
  }

  @StorageProp('topSafeAreaPx') topSafeAreaPx: number = 0;
  @StorageProp('bottomSafeAreaPx') bottomSafeAreaPx: number = 0;
  /**
   * 深色开关的当前位置。
   *
   * 取的是"实际深不深"而不是"选了什么"：默认选择是「跟随系统」，
   * 那种情况下开关该显示系统当前的样子，否则一进来就和系统反着，看着像坏了。
   */
  @State darkMode: boolean = AppTheme.isDark();
  @State selectedTheme: ThemeMode = AppTheme.currentMode();
  @StorageProp('bubbleTotalCount') totalRecords: number = 0;
  @StorageProp('bubbleCompletedCount') completedRecords: number = 0;
  @StorageProp(FRIEND_VERSION_KEY) @Watch('syncFriendCount') friendVersion: number = 0;
  @State friendCount: number = TodoService.friends().length;

  private syncFriendCount(): void { this.friendCount = TodoService.friends().length; }

  /** 握姿版本号：系统识别结果变了、或手动锁了某只手，这一页跟着重画 */
  @StorageProp(HAND_VERSION_KEY) @Watch('syncHand') handVersion: number = 0;
  @State handMode: HandMode = HandSense.currentMode();
  /** 握姿那行小字：现在按什么摆、这个结论是哪来的 */
  @State handText: string = HandSense.currentText();

  /**
   * 沉浸光感能力：底栏那层系统材质在本机到底能不能生效。
   *
   * 只问一次 —— 设备算力档和 API 版本都不会在运行期变化。
   */
  private material: MaterialCapability = getMaterialCapability();

  private syncHand(): void {
    this.handMode = HandSense.currentMode();
    this.handText = HandSense.currentText();
  }

  private syncTheme(): void {
    this.selectedTheme = AppTheme.currentMode();
    this.darkMode = AppTheme.isDark();
    this.themeText = AppTheme.currentText();
  }
  /** 开关下面那行小字：跟随系统（当前深色）/ 深色 / 浅色 */
  @State themeText: string = AppTheme.currentText();
  @State notifyOn: boolean = true;
  /**
   * 重力来源自检：物理引擎绑上传感器后会把类型写进 AppStorage。
   * 真机上如果这里显示「不可用」，说明左右倾斜不会带动泡泡（只剩固定垂坠），
   * 属于设备不支持 GRAVITY / ACCELEROMETER 的兜底状态。
   */
  @StorageProp(SENSOR_KIND_KEY) sensorKind: string = 'pending';
  /** 状态栏待办开关（实际值存在 Preferences 里，这里只是界面镜像） */
  @State statusBarOn: boolean = false;
  /** 投递通道的人话说明，由 StatusBarService 写进 AppStorage */
  @StorageProp(STATUS_TEXT_KEY) statusBarText: string = '未开启';
  /** 截止提醒的登记结果（几件、登记了几条），由 DeadlineReminderService 写进 AppStorage */
  @StorageProp(DEADLINE_REMINDER_KEY) deadlineText: string = '还没有紧急任务';

  // ---- 华为账号 ----
  @State signedIn: boolean = false;
  @State nickName: string = '';
  @State uidText: string = '';
  @State signingIn: boolean = false;
  /** 真头像（AGC profile scope 才有）；空串就退回昵称首字 */
  @State avatarUri: string = '';
  @State avatarInitial: string = '星';
  /** 账号卡片第二行：会话还有多久 / 没登录的原因 */
  @State accountSubText: string = '';
  /**
   * 登录态版本号：在别的页面登录/退出后，这一页要跟着变。
   * 页签切回来不一定重新走 aboutToAppear（TabContent 会被缓存），
   * 光靠 aboutToAppear 读一次，会出现"好友页显示已登录、我的页还写着未登录"。
   */
  @StorageProp(ACCOUNT_VERSION_KEY) @Watch('onAccountChanged') accountVersion: number = 0;

  /** 循环任务清单（值存在 BubbleStore，这里只是界面镜像） */
  @State rules: RepeatRule[] = [];
  @StorageProp(REPEAT_VERSION_KEY) @Watch('syncRules') repeatVersion: number = 0;
  /** 桌面上已经加了几张卡片（数字由卡片进程写，这里读文件） */
  @State cardCount: number = 0;

  /** 从存储里重新读一遍规则清单 */
  private syncRules(): void {
    const list: RepeatRule[] = BubbleStore.loadRules();
    const copy: RepeatRule[] = [];
    for (let i = 0; i < list.length; i++) {
      copy.push(list[i]);
    }
    this.rules = copy;
  }

  aboutToAppear(): void {
    this.syncTheme();
    this.syncFriendCount();
    this.syncAccount();
    // 开关真值在 Preferences 里，进页面时同步到界面
    this.statusBarOn = StatusBarService.isOn();
    this.syncRules();
    // 进页面时顺手重算一次截止提醒，保证「截止提醒」那一行显示的是最新的登记情况
    // （内容没变会被指纹挡住，代价只是一次内存扫描）
    DeadlineReminderService.sync();
    // 桌面卡片数量同理：添卡是在桌面做的，App 这边只能现读一次文件
    this.cardCount = FormCardService.installedCount();
    // 进页面时把攒着的账号提示（比如"登录已过期"）兑现掉
    this.showPendingAccountNotice();
  }

  /**
   * 状态栏投递开关。
   * 做成一整行是因为要给用户解释"现在走的是哪条通道"——
   * 实况窗（灵动岛）要 AGC 权益，没有的时候会自动退到常驻通知，
   * 这件事必须让用户看得见，否则他会以为功能坏了。
   */
  @Builder
  statusBarItem() {
    Column() {
      Row() {
        Text('📮')
          .fontSize(16)
          .width(26)
          .textAlign(TextAlign.Center)
        Column() {
          Text('待办挂状态栏')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
          Text(this.statusBarText)
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        Toggle({ type: ToggleType.Switch, isOn: this.statusBarOn })
          .selectedColor(this.p().accent)
          .onChange((value: boolean) => {
            this.statusBarOn = value;
            StatusBarService.setOn(value);
            if (!value) {
              this.getUIContext().getPromptAction().showToast({ message: '已从状态栏撤下', duration: 1200 });
              return;
            }
            // 点亮要先异步问系统能不能用实况窗，稍等一下再读结论
            setTimeout(() => {
              const msg: string | undefined = AppStorage.get<string>(STATUS_TEXT_KEY);
              this.getUIContext().getPromptAction().showToast({
                message: msg === undefined ? '已开启' : msg,
                duration: 2000
              });
            }, 1200);
          })
      }
      .width('100%')
      .height(58)

      Divider()
        .color(this.p().shadowSoft)
        .margin({ left: 36 })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  /** 把传感器类型翻译成人话 */
  private sensorText(): string {
    if (this.sensorKind === 'gravity') {
      return '已启用 · 重力传感器';
    }
    if (this.sensorKind === 'accelerometer') {
      return '已启用 · 加速度计';
    }
    if (this.sensorKind === 'none') {
      return '不可用 · 只分区不跟手';
    }
    return '检测中…';
  }

  /**
   * 沉浸光感那行字。
   *
   * 系统材质是"能用则用、不能用就静默降级"的：不支持时不会报错，
   * 只是底栏看起来像一块普通半透明底。不把状态摆出来，
   * 根本分不清是"没生效"还是"效果本来就淡"。
   */
  private materialText(): string {
    if (!this.material.immersiveSupported) {
      return `本机不支持 · 需 HarmonyOS 7（当前 API ${this.material.apiVersion}）`;
    }
    return `系统材质已开启 · ${this.material.levelText}算力档`;
  }

  /**
   * 登录态在别处变了（在好友页登录/退出、应用回到前台时发现会话到期）。
   * @Watch 不区分原因，所以这里统一"重读 + 把该解释的解释掉"。
   */
  private onAccountChanged(): void {
    this.syncAccount();
    this.showPendingAccountNotice();
  }

  /** 会话过期这类"不是用户点出来"的状态变化，得跟用户交代一句 */
  private showPendingAccountNotice(): void {
    const notice: string = TodoService.consumeAccountNotice();
    if (notice.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: notice, duration: 2600 });
    }
  }

  /**
   * 把登录态读进界面。
   *
   * 登录态一变（自己登录 / 在好友页登录 / 会话过期 / 启动时恢复）都会走到这里，
   * 所以这里不做任何缓存判断，每次如实重读 —— 这个函数很便宜。
   */
  private syncAccount(): void {
    this.signedIn = TodoService.isSignedIn();
    this.nickName = HuaweiAccount.displayName();
    this.avatarUri = HuaweiAccount.avatarUri();
    this.avatarInitial = HuaweiAccount.avatarInitial();

    // uid 只露后 6 位：够自己对一下是不是本人，又不至于在用户背后把完整 id 亮给旁边的人
    const tail: string = HuaweiAccount.uidTail(6);
    this.uidText = tail.length > 0 ? `ID：${tail}` : 'ID：未登录';

    if (this.signedIn) {
      this.accountSubText = `会话剩 ${HuaweiAccount.sessionDaysLeft()} 天 · 好友可以把小记发到你主页`;
    } else if (!TodoService.canSignIn()) {
      // 说清楚"不是坏了，是还没配" —— 否则用户点登录只会收到一句看不懂的报错
      this.accountSubText = '尚未接入华为账号登录（AGC 未配置 Client ID）';
    } else {
      this.accountSubText = '登录后好友才能给你发小记';
    }
  }

  private signIn(): void {
    if (this.signingIn) {
      return;
    }
    this.signingIn = true;
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    TodoService.signIn(ctx).then(() => {
      this.signingIn = false;
      this.syncAccount();
      this.getUIContext().getPromptAction().showToast({
        message: `已登录 · ${HuaweiAccount.displayName()}`,
        duration: 1500
      });
    }).catch((e: Error) => {
      this.signingIn = false;
      // 登录失败的提示给足时间：里面往往带着"下一步该去做什么"（没登录华为账号 / 没登记签名指纹）
      this.getUIContext().getPromptAction().showToast({ message: e.message, duration: 2600 });
    });
  }

  private signOut(): void {
    TodoService.signOut();
    this.syncAccount();
    this.getUIContext().getPromptAction().showToast({ message: '已退出登录', duration: 1200 });
  }

  /** 退出前先问一句：退出会清掉本机会话，之后好友发的小记就收不到了 */
  private confirmSignOut(): void {
    if (this.signingIn) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后会清掉本机保存的会话，重新登录才能继续收好友发来的小记。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: this.p().danger,
        action: () => {
          this.signOut();
        }
      }
    });
  }

  /**
   * 账号详情。
   *
   * 最要紧的是把**完整 uid** 摆出来 —— 加好友就是把这一串交换给对方，
   * 之前界面上只露后 6 位，用户想加人时无从下手。
   */
  private showAccountDetail(): void {
    const acc: HwAccount | undefined = TodoService.account();
    if (acc === undefined) {
      this.getUIContext().getPromptAction().showToast({
        message: TodoService.canSignIn() ? '先登录，才有账号详情' : '尚未接入华为账号登录，见 service/agc/AgcConfig.ets',
        duration: 2400
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '账号详情',
      message: `昵称：${HuaweiAccount.displayName()}\n`
        + `uid：${acc.unionId}\n`
        + `openId：${acc.openId}\n`
        + `登录时间：${HuaweiAccount.signedAtText()}\n`
        + `会话：还剩 ${HuaweiAccount.sessionDaysLeft()} 天过期\n\n`
        + `uid 就是加好友时给对方的那串，可以直接复制。`,
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  @Builder
  accountGroup() {
    Row() {
      SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
        .fontSize(20).width(26).fontColor([this.p().textSecondary])

      Column() {
        Text(this.signedIn ? (this.nickName.length > 0 ? this.nickName : '已登录') : '华为账号')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .width('100%')
        Text(this.accountSubText)
          .fontSize(12)
          .fontColor(this.p().textTertiary)
          .width('100%')
          .maxLines(2)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })

      Text(this.signingIn ? '登录中…' : (this.signedIn ? '退出' : '登录'))
        .fontSize(13)
        .fontColor(this.signedIn ? this.p().textTertiary : Color.White)
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(this.signedIn ? this.p().shadowSoft : this.p().accent)
        .borderRadius(15)
        .onClick(() => {
          if (this.signingIn) {
            return;
          }
          if (this.signedIn) {
            this.confirmSignOut();
          } else {
            this.signIn();
          }
        })
    }
    .width('100%')
    .height(64)
    .padding({ left: 14, right: 14 })
  }

  @Builder
  statItem(index: number, label: string) {
    Column() {
      Text(`${index === 0 ? this.totalRecords : (index === 1 ? this.friendCount : this.completedRecords)}`)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
      Text(label)
        .fontSize(12)
        .fontColor(this.p().textMeta)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
  }

  @Builder
  profileHeader() {
    Column() {
      Row() {
        // 头像：云端给了真头像就用真的，没有就用昵称首字顶着。
        // clip(true) 是必要的 —— Image 自己带 borderRadius，但 Stack 的圆角不会自动裁子节点
        Stack() {
          if (this.avatarUri.length > 0) {
            Image(this.avatarUri)
              .width(58)
              .height(58)
              .borderRadius(29)
              .objectFit(ImageFit.Cover)
              .alt($r('app.media.startIcon'))
          } else {
            Image($r('app.media.brand_icon')).width(58).height(58).objectFit(ImageFit.Cover)
          }
        }
        .width(58)
        .height(58)
        .borderRadius(29)
        .backgroundColor(this.p().cardBg)
        .clip(true)

        Column() {
          Text(this.signedIn ? this.nickName : '未登录')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().textPrimary)
          Text(this.uidText)
            .fontSize(12)
            .fontColor(this.p().textMeta)
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14 })
        .layoutWeight(1)

        Text('账号详情')
          .fontSize(12)
          .fontColor(this.p().textPrimary)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor(this.p().accentSoft)
          .onClick(() => {
            this.showAccountDetail();
          })
      }
      .width('100%')

      Divider()
        .color(this.p().shadowSoft)
        .margin({ top: 18, bottom: 16 })

      Row() {
        this.statItem(0, '小记')
        this.statItem(1, '好友')
        this.statItem(2, '已完成')
      }
      .width('100%')
    }
    .width('100%')
    .padding({
      left: 20,
      right: 20,
      top: 20,
      bottom: 22
    })
    .backgroundColor(this.p().cardBg)
    .border({ width: 1, color: this.p().glassBorder })
    .borderRadius(24)
  }

  @Builder
  themeChoice(mode: ThemeMode, icon: Resource) {
    Column({ space: 8 }) {
      SymbolGlyph(icon).fontSize(22)
        .fontColor([this.selectedTheme === mode ? this.p().accentText : this.p().textSecondary])
      Text(AppTheme.modeText(mode)).fontSize(12)
        .fontWeight(this.selectedTheme === mode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selectedTheme === mode ? this.p().accentText : this.p().textSecondary)
    }
    .layoutWeight(1).height(76).justifyContent(FlexAlign.Center).borderRadius(17)
    .backgroundColor(this.selectedTheme === mode ? this.p().accentSoft : this.p().cardBg)
    .border({ width: 1, color: this.selectedTheme === mode ? this.p().accentText : Color.Transparent })
    .accessibilityText(AppTheme.modeText(mode))
    .onClick(() => { AppTheme.setMode(mode); })
  }

  @Builder
  themePicker() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        this.themeChoice(ThemeMode.LIGHT, $r('sys.symbol.sun_max'))
        this.themeChoice(ThemeMode.DARK, $r('sys.symbol.moon'))
        this.themeChoice(ThemeMode.FOLLOW, $r('sys.symbol.circle_lefthalf_inset_filled'))
      }.width('100%')
    }
    .width('100%').padding(10).backgroundColor(this.p().cardBg).borderRadius(22)
    .border({ width: 1, color: this.p().glassBorder })
  }

  @Builder
  handChoice(mode: HandMode) {
    Column() {
      Text(HandSense.modeText(mode))
        .fontSize(13)
        .fontWeight(this.handMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.handMode === mode ? this.p().accentText : this.p().textSecondary)
    }
    .layoutWeight(1).height(46).justifyContent(FlexAlign.Center).borderRadius(15)
    .backgroundColor(this.handMode === mode ? this.p().accentSoft : this.p().cardBg)
    .border({ width: 1, color: this.handMode === mode ? this.p().accentText : Color.Transparent })
    .accessibilityText(HandSense.modeText(mode))
    .onClick(() => {
      HandSense.setMode(mode);
      this.syncHand();
    })
  }

  /** 握持方式：新增按钮跟着握持手换边，识别不准时可以手动锁死 */
  @Builder
  handPicker() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        this.handChoice(HandMode.AUTO)
        this.handChoice(HandMode.RIGHT)
        this.handChoice(HandMode.LEFT)
      }.width('100%')
      Text(this.handText)
        .fontSize(11).fontColor(this.p().textTertiary)
        .width('100%').padding({ left: 4 })
    }
    .width('100%').padding(10).backgroundColor(this.p().cardBg).borderRadius(22)
    .border({ width: 1, color: this.p().glassBorder })
  }

  @Builder
  groupTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.p().textMeta)
      .width('100%')
      .padding({ left: 6, top: 20, bottom: 8 })
  }

  private rowIcon(icon: string): Resource {
    if (icon === '📌') { return $r('sys.symbol.star'); }
    if (icon === '🏷️') { return $r('sys.symbol.label'); }
    if (icon === '🗑️') { return $r('sys.symbol.trash'); }
    if (icon === '🔔') { return $r('sys.symbol.bell'); }
    if (icon === '🔒') { return $r('sys.symbol.lock'); }
    if (icon === '☁️') { return $r('sys.symbol.cloud'); }
    if (icon === '❓') { return $r('sys.symbol.questionmark_circle'); }
    if (icon === '🌀') { return $r('sys.symbol.arrow_clockwise'); }
    if (icon === '🪟') { return $r('sys.symbol.square_grid_2x2'); }
    return $r('sys.symbol.info_circle');
  }

  @Builder
  rowItem(icon: string, title: string, value: string, showArrow: boolean, isLast: boolean) {
    Column() {
      Row() {
        SymbolGlyph(this.rowIcon(icon))
          .fontSize(20).width(26).fontColor([this.p().textSecondary])
        Text(title)
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .layoutWeight(1)
          .margin({ left: 10 })
        if (value.length > 0) {
          Text(value)
            .fontSize(13)
            .fontColor(this.p().textTertiary)
        }
        if (showArrow) {
          Text('›')
            .fontSize(18)
            .fontColor(this.p().textTertiary)
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .height(52)

      if (!isLast) {
        Divider()
          .color(this.p().shadowSoft)
          .margin({ left: 36 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      this.getUIContext().getPromptAction().showToast({ message: `${title}（待开发）`, duration: 1200 });
    })
  }

  /**
   * 会跳外链的一行（目前给「隐私政策」用）。
   *
   * 和 rowItem 的区别只有点击行为：rowItem 是"待开发"占位，
   * 这行是真的要用系统浏览器打开网址 —— App 内没有自建 WebView，
   * 交给系统浏览器最省事，也符合"能用系统能力就别自己造"的原则。
   */
  @Builder
  linkItem(icon: string, title: string, value: string, isLast: boolean) {
    Column() {
      Row() {
        SymbolGlyph(this.rowIcon(icon))
          .fontSize(20).width(26).fontColor([this.p().textSecondary])
        Text(title)
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .layoutWeight(1)
          .margin({ left: 10 })
        if (value.length > 0) {
          Text(value)
            .fontSize(13)
            .fontColor(this.p().textTertiary)
        }
        Text('›')
          .fontSize(18)
          .fontColor(this.p().textTertiary)
          .margin({ left: 6 })
      }
      .width('100%')
      .height(52)

      if (!isLast) {
        Divider()
          .color(this.p().shadowSoft)
          .margin({ left: 36 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      this.openPrivacyPolicy();
    })
  }

  /** 用系统浏览器打开隐私政策；打不开时把原因说清楚，别静默失败 */
  private openPrivacyPolicy(): void {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: PRIVACY_URL
    };
    ctx.startAbility(want).catch((err: BusinessError) => {
      this.getUIContext().getPromptAction().showToast({
        message: `打不开隐私政策（${err.code}）：${err.message}`,
        duration: 2600
      });
    });
  }

  /**
   * @param tag 0=消息通知 1=深色模式
   */
  @Builder
  switchItem(icon: string, title: string, isOn: boolean, tag: number, isLast: boolean, sub: string = '') {
    Column() {
      Row() {
        SymbolGlyph(this.rowIcon(icon))
          .fontSize(20).width(26).fontColor([this.p().textSecondary])
        Column() {
          Text(title)
            .fontSize(15)
            .fontColor(this.p().textPrimary)
            .width('100%')
          if (sub.length > 0) {
            Text(sub)
              .fontSize(11)
              .fontColor(this.p().textTertiary)
              .width('100%')
              .margin({ top: 3 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor(this.p().accent)
          .onChange((value: boolean) => {
            if (tag === 0) {
              this.notifyOn = value;
            } else {
              this.darkMode = value;
              // 拨过开关就变成"手动选了某一种"，不再是跟随系统
              AppTheme.setMode(value ? ThemeMode.DARK : ThemeMode.LIGHT);
              this.themeText = AppTheme.currentText();
              this.getUIContext().getPromptAction().showToast({
                message: value ? '已切到深色' : '已切到浅色',
                duration: 1200
              });
            }
          })
      }
      .width('100%')
      .height(52)

      if (!isLast) {
        Divider()
          .color(this.p().shadowSoft)
          .margin({ left: 36 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  @Builder
  cardGroup() {
    Column() {
      this.rowItem('📌', '我的收藏', '', true, false)
      this.rowItem('🏷️', '标签管理', '', true, false)
      this.rowItem('🗑️', '回收站', '', true, true)
    }
    .width('100%')
    .backgroundColor(this.p().cardBg)
    .borderRadius(20)
  }

  /** 停掉一条循环任务：规则删掉，它物化出来还没做的泡泡也会跟着撤走 */
  private stopRule(rule: RepeatRule): void {
    BubbleStore.removeRule(rule.id);
    this.syncRules();
    AppStorage.setOrCreate<number>(REPEAT_VERSION_KEY, this.repeatVersion + 1);
    // 规则被停掉时，它物化出来还没做的泡泡也一起撤走了 ——
    // 那些泡泡可能挂着截止提醒，得跟着撤销，否则系统还会替一条不存在的任务催你
    DeadlineReminderService.sync();
    // 规则停掉会连带撤走泡泡，桌面卡片上的数字也就跟着不对了，补推一次
    FormCardService.syncAll();
    this.getUIContext().getPromptAction().showToast({
      message: `已停掉「${rule.text}」`,
      duration: 1500
    });
  }

  /** 一条循环任务 */
  @Builder
  ruleRow(rule: RepeatRule, isLast: boolean) {
    Column() {
      Row() {
        if (levelNeedsBadge(rule.level)) {
          Column()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(levelColor(rule.level))
            .margin({ right: 8 })
        }

        Column() {
          Text(rule.text)
            .fontSize(15)
            .fontColor(this.p().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${repeatText(rule.mode, rule.weekdays)} · ${levelLabel(rule.level)}`)
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('停掉')
          .fontSize(13)
          .fontColor(this.p().danger)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(this.p().dangerSoftBg)
          .borderRadius(14)
          .onClick(() => {
            this.stopRule(rule);
          })
      }
      .width('100%')
      .height(60)

      if (!isLast) {
        Divider()
          .color(this.p().shadowSoft)
          .margin({ left: 16 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  /**
   * 循环任务清单。
   * 加这一块是因为「每天 / 每周」的规则如果只能建、不能停，
   * 就是个单向门 —— 用户第二天想取消都没处点。
   */
  @Builder
  rulesGroup() {
    Column() {
      if (this.rules.length === 0) {
        Row() {
          Text('还没有循环任务，去主页记一条并选「每天」或「每周」')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .maxLines(2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 18, bottom: 18 })
      } else {
        ForEach(this.rules, (item: RepeatRule, index: number) => {
          this.ruleRow(item, index === this.rules.length - 1)
        }, (item: RepeatRule) => `rule_${item.id}`)
      }
    }
    .width('100%')
    .backgroundColor(this.p().cardBg)
    .borderRadius(20)
  }

  /**
   * 截止提醒的登记情况（只读，点一下说明提醒节奏）。
   *
   * 这一行存在的唯一理由：提醒托管给系统之后，App 里什么都看不见，
   * 而"到底有没有生效"要等到第一个提前量（可能是 3 小时后）才验证得了。
   * 把条数摆出来，建完任务当场就能确认；万一显示"登记失败"，
   * 也能立刻知道是通知没开，而不是傻等。
   */
  @Builder
  deadlineItem() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.clock'))
        .fontSize(20).width(26).fontColor([this.p().textSecondary])
        Column() {
          Text('截止提醒')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
          Text(this.deadlineText)
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
      }
      .width('100%')
      .height(58)
      .onClick(() => {
        this.getUIContext().getPromptAction().showToast({
          message: '紧急任务在截止前 3小时 / 1小时 / 30分 / 10分 / 5分 / 3分 / 1分 各提醒一次',
          duration: 3000
        });
      })

      Divider()
        .color(this.p().shadowSoft)
        .margin({ left: 36 })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  /**
   * 桌面小卡片。
   *
   * 加卡片的动作是在桌面上做的（App 里办不到），所以这一行只干两件事：
   * 告诉用户"你现在有几张"，以及"去哪儿加"。不写这一行的话，
   * 这个功能做完了用户根本不知道它存在。
   */
  @Builder
  cardItem() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
        .fontSize(20).width(26).fontColor([this.p().textSecondary])
        Column() {
          Text('桌面小卡片')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
          Text(this.cardCount > 0 ? `桌面上已有 ${this.cardCount} 张 · 点看怎么加` : '还没放到桌面 · 点看怎么加')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
      }
      .width('100%')
      .height(58)
      .onClick(() => {
        this.getUIContext().getPromptAction().showToast({
          message: '桌面双指捏合（或长按空白处）→ 服务卡片 → 找到「零星小记」→ 添加「今天的零星小记」',
          duration: 4000
        });
      })

      Divider()
        .color(this.p().shadowSoft)
        .margin({ left: 36 })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          Text('我的').fontSize(27).fontWeight(FontWeight.Bold)
            .fontColor(this.p().textPrimary).width('100%').margin({ top: 4, bottom: 16 })
          this.profileHeader()

          this.groupTitle('外观主题')
          this.themePicker()

          this.groupTitle('握持方式')
          this.handPicker()

          this.groupTitle('账号')
          Column() {
            this.accountGroup()
          }
          .width('100%')
          .backgroundColor(this.p().cardBg)
          .borderRadius(20)

          this.groupTitle('我的内容')
          this.cardGroup()

          this.groupTitle('循环任务')
          this.rulesGroup()

          this.groupTitle('界面效果')
          Column() {
            this.rowItem('🪟', '界面风格', '星光玻璃', false, false)
            this.rowItem('✨', '沉浸光感', this.materialText(), false, false)
            this.rowItem('🌀', '重力感应', this.sensorText(), false, true)
          }
          .width('100%')
          .backgroundColor(this.p().cardBg)
          .borderRadius(20)

          this.groupTitle('提醒与桌面')
          Column() {
            this.statusBarItem()
            this.deadlineItem()
            this.cardItem()
            this.switchItem('🔔', '消息通知', this.notifyOn, 0, false)
            this.rowItem('☁️', '数据备份', '未开启', true, true)
          }
          .width('100%')
          .backgroundColor(this.p().dividerStrong)
          .borderRadius(20)
          .shadow({ radius: 14, color: this.p().shadowSoft, offsetX: 0, offsetY: 4 })

          this.groupTitle('其他')
          Column() {
            this.linkItem('🔒', '隐私政策', '', false)
            this.rowItem('❓', '帮助与反馈', '', true, false)
            this.rowItem('ℹ️', '关于我们', 'v1.0.0', true, true)
          }
          .width('100%')
          .backgroundColor(this.p().dividerStrong)
          .borderRadius(20)
          .shadow({ radius: 14, color: this.p().shadowSoft, offsetX: 0, offsetY: 4 })

          // 没登录时不摆这个按钮：账号区已经有登录入口了，
          // 一个永远点不出结果的"退出登录"只会让人以为界面坏了
          if (this.signedIn) {
            Button('退出登录')
              .width('100%')
              .height(48)
              .fontSize(15)
              .fontColor(this.p().danger)
              .backgroundColor(this.p().cardBg)
              .borderRadius(20)
              .margin({ top: 24 })
              .onClick(() => {
                this.confirmSignOut();
              })
          }

          // 底部留白：内容一直铺到屏幕底（滚动时从悬浮页签栏底下穿过，玻璃才有东西可模糊），
          // 这段占位保证滚到底时最后一项能完整露在栏上方
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.bottomSafeAreaPx) + 112)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) + 8 })
  }
}
