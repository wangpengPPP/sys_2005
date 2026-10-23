import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { cloudCommon } from '@kit.CloudFoundationKit';
import { BubbleStore } from '../model/BubbleStore';
import { TodoService } from '../service/TodoService';
import { StatusBarService } from '../service/live/StatusBarService';
import { DeadlineReminderService } from '../service/DeadlineReminderService';
import { FormCardService } from '../service/FormCardService';
import { CARD_ENTRY_KEY } from '../common/AppEvents';
import { AppTheme } from '../common/AppTheme';
import { HandSense } from '../common/HandSense';
import { CLOUD_REGION } from '../service/agc/AgcConfig';

const DOMAIN = 0x0000;

/** 桌面卡片点进来时，want 里带的标记（见 form/TodoCard.ets 的 postCardAction） */
const CARD_PARAM_FROM: string = 'fromCard';
const CARD_PARAM_CREATE: string = 'create';

export default class EntryAbility extends UIAbility {
  /**
   * 冷启动那一次的 want 直接用基类的 launchWant
   * （UIAbility 自带这个属性，记着最近一次拉起本 ability 的 want）。
   * 判断"是不是从桌面卡片点进来的"要等到窗口加载完才好做，那时 onCreate 的参数早没了。
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 主题：读盘里存的选择、读一次系统深浅色，然后广播版本号
    // 必须排在画面之前 —— 首帧就得按正确的配色画，否则会闪一下浅色
    AppTheme.init(this.context);
    // 把系统此刻的深浅色喂给主题（默认选择是"跟随系统"，得先知道系统是什么）
    AppTheme.applySystemColorMode(this.context.config.colorMode);
    // 智感握姿：读盘里的选择，然后订阅系统的握持手 / 操作手感知。
    // 订阅放在这里而不是页面里 —— 换手是随时发生的，跟哪个页面在前台没关系
    HandSense.init(this.context);
    HandSense.start();
    // 初始化本地小记存储（Preferences）
    BubbleStore.init(this.context);
    // 好友收件箱 + 华为账号登录态
    TodoService.init(this.context);
    // 状态栏待办（实况窗 / 常驻通知双通道）。这里只是读开关、恢复上次状态，
    // 真正推送要等 BubbleStore 里有数据，所以放 onForeground 再刷一次
    StatusBarService.init(this.context);
    // 截止提醒（后台代理提醒）：提醒本身托管在系统里，进程重启也不会丢，
    // 但系统侧的登记可能被清过（升级、清数据），所以启动后重算一遍补齐
    DeadlineReminderService.init(this.context);
    // 桌面卡片：这里只是把 context 交给它，之后 App 里数据一变就主动推给桌面上的卡片
    FormCardService.init(this.context);
    // 云端连接初始化：云函数、云存储、云数据库都靠它建连
    // （不传 authProvider —— 鉴权我们自己走"授权码换会话"那条路，见 service/agc）
    try {
      cloudCommon.init({ region: CLOUD_REGION });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'CloudFoundation init failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 系统深浅色被改了（设置里切换 / 系统自动切换）。
   * 这里只把新值交给主题；主题内部会判断"当前是不是跟随系统"，
   * 手动选过浅色或深色的话不会被这次变化带走。
   */
  onConfigurationUpdate(config: Configuration): void {
    AppTheme.applySystemColorMode(config.colorMode);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 退订握姿感知：回调是系统持有的，留着会指向已经销毁的进程
    HandSense.stop();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 先读一次安全区：HdsTabs 的悬浮样式对"渲染后再改"不敏感，
    // 底部页签栏必须让首帧就拿到手势条高度，否则会一直压在小白条上
    this.applySafeArea(windowStage, 'beforeLoad');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 先开全屏，再读安全区 —— 顺序反了的话拿到的避让区还是旧值
      this.applyWindowLayout(windowStage);
      this.applySafeArea(windowStage, 'afterFullscreen');
      // 从桌面卡片的「记一笔」冷启动进来：等首页站稳再让 Index 把弹框推出来
      this.handleCardEntry(this.launchWant, 320);
    });

  }

  /**
   * 让内容铺满整屏。
   *
   * 默认窗口是"非沉浸式"的：它会把状态栏和底部手势条的高度让出来，
   * 让出来的那块由系统用**窗口底色（默认白）**填 —— 页面上看就是上下各一条白条。
   *
   * 打开沉浸式布局后，页面里的 100% 指的就是整块屏幕，
   * 底层的浅蓝渐变才能真正铺满；被系统栏压住的部分由各页面自己用
   * topSafeAreaPx / bottomSafeAreaPx 做内边距躲开。
   */
  private applyWindowLayout(windowStage: window.WindowStage): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();

      // ① 沉浸式布局：状态栏和手势条仍显示，但内容可以画到它们底下
      mainWindow.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
      });

      // ② 状态栏 / 导航栏图标：跟当前配色走（深色主题下必须转成浅色图标，
      //    否则深色图标压在深色背景上等于隐形）。之后切主题由 AppTheme 自己改，
      //    所以要把窗口交给它 —— 系统栏不在组件树里，页面重绘动不到
      AppTheme.attachWindow(windowStage);

      // ③ 窗口底色设成渐变顶部色：冷启动那一瞬内容还没渲染，先铺这个色，
      //    不会突然闪一下白（深色主题下铺的是深色的顶段）
      mainWindow.setWindowBackgroundColor(AppTheme.palette().bg1);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'applyWindowLayout failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 记录状态栏 / 手势条高度（单位 px），页面再换算成 vp 做内边距，
   * 避免内容被系统栏遮挡。
   */
  private applySafeArea(windowStage: window.WindowStage, phase: string): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      const topArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottomArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('topSafeAreaPx', topArea.topRect.height);
      AppStorage.setOrCreate<number>('bottomSafeAreaPx', bottomArea.bottomRect.height);
      // 底部这个值就是手势条（小白条）占的高度，页签栏靠它抬高，打日志方便对不上时排查
      hilog.info(DOMAIN, 'testTag', 'avoidArea[%{public}s] top=%{public}d bottom=%{public}d (px)',
        phase, topArea.topRect.height, bottomArea.bottomRect.height);

      mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>('topSafeAreaPx', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate<number>('bottomSafeAreaPx', data.area.bottomRect.height);
        }
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to get avoid area. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * App 已经在后台时，又从桌面卡片点了一下「记一笔」。
   * 这时窗口是活的，直接发信号即可，不用等太久。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleCardEntry(want, 160);
  }

  /**
   * 卡片点进来的信号转运。
   *
   * 卡片那边只能给一个 want 参数（postCardAction 的能力就这么大），而"弹出新建框"这件事
   * 要由 Index 先切回主页页签、HomePage 才弹得出来，所以这里只负责把参数转成
   * CARD_ENTRY_KEY 这个 AppStorage 信号，剩下的交给页面。
   *
   * @param delay 延迟毫秒数 —— @StorageProp 只对**变更**响应：页面还没挂载就写进去，
   *              页面拿到的只是初始值，@Watch 不会响。冷启动要给足加载时间。
   */
  private handleCardEntry(want: Want, delay: number): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const from: Object | undefined = params[CARD_PARAM_FROM];
    if (from === undefined || from === null || (from as string) !== CARD_PARAM_CREATE) {
      return;
    }
    setTimeout((): void => {
      AppStorage.setOrCreate<number>(CARD_ENTRY_KEY, Date.now());
    }, delay);
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 回到前台先验一次本地会话的有效期：应用在后台放久了，
    // 那份 token 可能已经过头，就地作废并把传输层手里的 token 撤掉，
    // 免得继续拿一个死 token 去调云函数（服务端只会拒，界面上却看不出毛病）
    TodoService.checkSession();
    // 回到前台同步一次状态栏：进程重启后实况窗会掉，这里把它接回来；
    // 内容没变的话 StatusBarService 内部会跳过，不会反复打扰系统
    StatusBarService.refresh();
    // 截止提醒也重算一次（内容没变会被指纹挡住，代价只是一次内存扫描）
    DeadlineReminderService.sync();
    // 桌面卡片也补推一次：App 关着的时候卡片是靠系统的 5 分钟刷新自己续的，
    // 万一那条链断了，回到前台这一下能把它接回来
    FormCardService.syncAll();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
