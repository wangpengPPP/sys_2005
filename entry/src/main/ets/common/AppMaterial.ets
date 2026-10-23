import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'LingXingXiaoJi';

/**
 * 当前设备是否达到沉浸光感所需的 API 版本（26.0.0）
 * 工程 compatibleSdkVersion 为 6.1.1(24)，因此必须做运行时判断，不能无条件调用 API 26 接口
 * 注：deviceInfo.apiAvailable() 只接受 1~25，故直接用 sdkApiVersion 判断
 */
export const API_26_AVAILABLE: boolean = deviceInfo.sdkApiVersion >= 26;

/**
 * 设备是否真正支持沉浸式系统材质（系统材质是设备能力，不是所有机型都有）
 */
export function isImmersiveMaterialSupported(): boolean {
  if (!API_26_AVAILABLE) {
    return false;
  }
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'isImmersiveMaterialSupported failed: %{public}s', JSON.stringify(err));
    return false;
  }
}

/**
 * 「沉浸光感」系统材质（ArkUI `uiMaterial.ImmersiveMaterial` + `CommonMethod.systemMaterial`）
 *
 * 与手写 backgroundBlurStyle 的区别：
 *  - 系统材质：折射 + 高光 + 阴影 + 点光源 + 触点流光，不只是像素模糊
 *  - 厚薄、强度、反色、降级全部由系统按本机算力档和系统侧的沉浸光感配置决定，
 *    应用只能提要求（选厚薄），不能指定强弱，也不该自己画一套玻璃去模仿
 *  - 设备能力和组件所在区域都要满足要求；`out of scope` 表示区域不支持，
 *    与设备算力无关。普通内容卡片使用下面的 FrostedContentModifier。
 *
 * 官方为沉浸光感留了两条接入轨道，本项目走的是第一条：
 *  1. **组件级 / 应用级（ArkUI）**：组件挂 `systemMaterial(ImmersiveMaterial)`，
 *     应用级开关是 module.json5 的 metadata `ohos.arkui.UIMaterial.state`（本项目已配 enable）。
 *     API 26（HarmonyOS 7）起可用 —— 本文件就是这条。
 *  2. **HDS 组件轨道**：HdsNavigation 标题栏 / HdsTabs 底部页签的
 *     `systemMaterialEffect`，参数是 `hdsMaterial` 的 materialType + materialLevel
 *     （都取 ADAPTIVE 即"跟随系统"）。API 23（HarmonyOS 6.1）起可用，但要换成 HDS 组件承载。
 *
 * 两条轨道的"强度"都不是应用能设的值：uiMaterial 侧没有强度参数，
 * hdsMaterial.MaterialLevel.ADAPTIVE 表达的就是"别问我，系统定"。
 * 另注意 `getGlobalMaterialLevel()` 返回的是**设备算力档**，与光感强度无关（见文件末尾）。
 *
 * 这些材质对象只在 API 26 及以上构造，低版本一律返回 undefined，不触碰构造接口。
 */
function createCardMaterial(): uiMaterial.Material | undefined {
  if (!API_26_AVAILABLE) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR
  });
}

function createThinMaterial(): uiMaterial.Material | undefined {
  if (!API_26_AVAILABLE) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: { color: Color.White }
  });
}

function createUltraThinMaterial(): uiMaterial.Material | undefined {
  if (!API_26_AVAILABLE) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: { color: Color.White }
  });
}

/**
 * 「新建」圆钮专用材质 —— **刻意与底部悬浮页签栏（HdsTabs）对齐观感**。
 *
 * 和 THIN_MATERIAL 的区别：
 *  - style 用 REGULAR 而不是 THIN。THIN 透得太狠，圆钮会缩成一块"几乎看不见的玻璃"，
 *    而旁边的页签栏有明确的玻璃厚度和底感，两者摆在一起不是一套语言。
 *    REGULAR 的厚度、模糊量与栏最接近。
 *  - materialColor 补一点极淡的白：栏体有不透明度（barOpacity 0.82）撑着一层底，
 *    圆钮若完全透明，会显得"空"。这一点白就是给它补上同款的底。
 *    想让圆钮更透 → 把 alpha 调小或整个删掉；想更实 → 调大。
 *
 * interactive / lightEffect 保留：按压形变 + 手指附近的光感反馈，
 * 这是交互反馈而非静态样式，不影响与栏的一致性。
 */
function createFabMaterial(): uiMaterial.Material | undefined {
  if (!API_26_AVAILABLE) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: '#1FFFFFFF',
    interactive: true,
    lightEffect: { color: Color.White }
  });
}

/** 常规厚度：卡片、列表分组 */
export const CARD_MATERIAL: uiMaterial.Material | undefined = createCardMaterial();
/** 薄：搜索框、输入类；带按压形变 + 光感跟随反馈 */
export const THIN_MATERIAL: uiMaterial.Material | undefined = createThinMaterial();
/** 超薄：chip、小浮层 */
export const ULTRA_THIN_MATERIAL: uiMaterial.Material | undefined = createUltraThinMaterial();
/** 与底部悬浮页签栏（HdsTabs）观感对齐：页签栏右侧的「新建」圆钮 */
export const FAB_MATERIAL: uiMaterial.Material | undefined = createFabMaterial();

/**
 * 底栏与「新建」圆钮共用的系统材质。
 *
 * 使用系统 THIN 预设，不叠加自绘底色、模糊、描边或阴影。
 * style 选择的是材质厚薄，并不是用户的光感强弱；即使指定 style，
 * 系统仍会按设备能力和用户的光感设置调整效果。不传 style 则默认 REGULAR，
 * 不代表特殊的“跟随系统”档位。交互反馈也使用系统默认光色。
 *
 * 生效范围（官方硬约束，写在日志里就一句
 * `Material inactive: out of scope`）：除弹窗类、Slider / Toggle / Select 之外，
 * 普通组件只有在 **Navigation / NavDestination 标题栏**或
 * **barPosition 为 BarPosition.End 的横向 Tabs 的底部 TabBar** 里才会生效。
 * 本项目的底栏正好落在后者（见 pages/Index.ets 的 dockBar），别把它挪出 tabBar。
 */
function createDockMaterial(): uiMaterial.Material | undefined {
  if (!API_26_AVAILABLE) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: {}
  });
}

export const DOCK_MATERIAL: uiMaterial.Material | undefined = createDockMaterial();

/**
 * 正文卡片使用 ArkUI 磨砂预设。正文不在 systemMaterial 生效范围内，
 * 这里只跟随应用深浅主题，不读取或模拟系统“沉浸光感”强弱。
 */
export class FrostedContentModifier implements AttributeModifier<CommonAttribute> {
  private dark: boolean;
  private inactiveColor: ResourceColor;
  private borderColor: ResourceColor;

  constructor(dark: boolean, inactiveColor: ResourceColor, borderColor: ResourceColor) {
    this.dark = dark;
    this.inactiveColor = inactiveColor;
    this.borderColor = borderColor;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance.backgroundBlurStyle(BlurStyle.Thin, {
      colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
      policy: BlurStyleActivePolicy.FOLLOWS_WINDOW_ACTIVE_STATE,
      inactiveColor: this.inactiveColor
    }).border({ width: 0.5, color: this.borderColor });
  }
}

/**
 * 兜底用的半透明白：设备不支持沉浸光感时，卡片靠它维持基本可读性
 */
export const FALLBACK_CARD_BG: string = '#66FFFFFF';
export const FALLBACK_THIN_BG: string = '#59FFFFFF';

/**
 * 设备能力信息，用于在「我的」页展示当前沉浸光感状态
 */
export interface MaterialCapability {
  /** 系统材质接口（API 26+）在本机能不能用 */
  immersiveSupported: boolean;
  /** 设备算力档：高 / 中 / 低。**不是**沉浸光感的强度设置 */
  levelText: string;
  /** 当前设备的 API 版本，用来解释为什么不能用 */
  apiVersion: number;
}

/**
 * 查本机的沉浸光感能力。
 *
 * 注意 `getGlobalMaterialLevel()` 拿的是**设备算力档**（EXQUISITE / GENTLE / SMOOTH），
 * 官方文档写得很明确：它由设备厂商在系统配置文件里定死，应用改不了。
 * 它与"沉浸光感强度"不是一回事 —— 强度是系统设置里的那档（强 / 均衡 / 弱），
 * 应用侧**没有公开接口可以读、也没有接口可以设**，材质自己会跟着变。
 *
 * 这里报这个档位只为两件事：解释低算力设备为什么只有一种材质样式
 * （低算力档上 ImmersiveStyle 整条枚举都不生效），以及诊断用。
 */
export function getMaterialCapability(): MaterialCapability {
  const supported: boolean = isImmersiveMaterialSupported();
  let levelText: string = '';
  if (supported) {
    try {
      const level: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
      if (level === uiMaterial.MaterialLevel.EXQUISITE) {
        levelText = '高';
      } else if (level === uiMaterial.MaterialLevel.GENTLE) {
        levelText = '中';
      } else {
        levelText = '低';
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'getGlobalMaterialLevel failed: %{public}s', JSON.stringify(err));
    }
  }
  return { immersiveSupported: supported, levelText: levelText, apiVersion: deviceInfo.sdkApiVersion };
}
