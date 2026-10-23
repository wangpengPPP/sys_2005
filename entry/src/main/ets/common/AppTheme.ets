import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppTheme';
const PREF_NAME: string = 'lingxing_theme';
const KEY_MODE: string = 'theme_mode';

export enum ThemeMode {

  FOLLOW = 0,

  LIGHT = 1,

  DARK = 2
}

export const THEME_VERSION_KEY: string = 'appThemeVersion';
export const THEME_DARK_KEY: string = 'appThemeDark';

export interface AppPalette {

  bg1: string;
  bg2: string;
  bg3: string;
  bg4: string;

  // ---- 文字 ----

  textPrimary: string;

  textSecondary: string;

  textTertiary: string;

  textQuaternary: string;

  textMeta: string;

  textMuted: string;

  // ---- 强调 ----

  accent: string;

  accentText: string;

  fabIcon: string;

  danger: string;

  dangerText: string;

  success: string;

  progressFrom: string;
  progressTo: string;

  accentSoft: string;

  accentHalo: string;

  accentGlow: string;

  dangerSoftBg: string;

  dangerSoftBorder: string;

  // ---- 玻璃与表面 ----

  glassArea: string;

  glassAreaStrong: string;

  glassBorder: string;

  glassBorderStrong: string;

  chip: string;

  chipStrong: string;

  divider: string;

  dividerStrong: string;

  cardBg: string;

  cardBgThin: string;

  // ---- 泡泡 ----
  bubbleFill: string;
  bubbleFillDone: string;
  bubbleBorder: string;
  bubbleBorderDone: string;
  bubbleText: string;
  bubbleTextDone: string;

  bubbleSubText: string;
  bubbleSubTextDone: string;

  // ---- 遮罩与阴影 ----

  scrim: string;

  scrimSheet: string;

  shadowSoft: string;

  shadowCard: string;
}

const LIGHT: AppPalette = {
  bg1: '#F8F8FF',
  bg2: '#F1F2FF',
  bg3: '#E8EBFC',
  bg4: '#E1E5F8',
  textPrimary: '#24283D',
  textSecondary: '#727B95',
  textTertiary: '#828BA3',
  textQuaternary: '#A2ABC0',
  textMeta: '#737D98',
  textMuted: '#59647F',
  accent: '#6265EF',
  accentText: '#5659D6',
  fabIcon: '#FFFFFF',
  danger: '#E3677C',
  dangerText: '#C54B65',
  success: '#4DAD9E',
  progressFrom: '#9B95FF',
  progressTo: '#6265EF',
  accentSoft: '#186265EF',
  accentHalo: '#996265EF',
  accentGlow: '#406265EF',
  dangerSoftBg: '#12E3677C',
  dangerSoftBorder: '#40E3677C',
  glassArea: '#80FFFFFF',
  glassAreaStrong: '#A6FFFFFF',
  glassBorder: '#D9FFFFFF',
  glassBorderStrong: '#CFD5EC',
  chip: '#E9ECF9',
  chipStrong: '#DDE1F5',
  divider: '#E1E5F1',
  dividerStrong: '#D6DCEC',
  cardBg: '#F9FAFF',
  cardBgThin: '#EFF1FA',
  bubbleFill: '#96FFFFFF',
  bubbleFillDone: '#70FFFFFF',
  bubbleBorder: '#EFFFFFFF',
  bubbleBorderDone: '#C4D4F0',
  bubbleText: '#2D3551',
  bubbleTextDone: '#727F9C',
  bubbleSubText: '#667696',
  bubbleSubTextDone: '#939CB3',
  scrim: '#4020253F',
  scrimSheet: '#6620253F',
  shadowSoft: '#14606EA0',
  shadowCard: '#28606EA0'
};

const DARK: AppPalette = {
  bg1: '#111525',
  bg2: '#101423',
  bg3: '#0D1220',
  bg4: '#0B101C',
  textPrimary: '#F1F3FF',
  textSecondary: '#AAB3CF',
  textTertiary: '#959FBB',
  textQuaternary: '#727E9C',
  textMeta: '#9EA9C5',
  textMuted: '#BDC5DD',
  accent: '#7372F8',
  accentText: '#AAA8FF',
  fabIcon: '#FFFFFF',
  danger: '#E9758C',
  dangerText: '#FF9BAC',
  success: '#72CEBB',
  progressFrom: '#A39AFF',
  progressTo: '#6567FC',
  accentSoft: '#307775F8',
  accentHalo: '#B39C96FF',
  accentGlow: '#506D6CF6',
  dangerSoftBg: '#26EA788C',
  dangerSoftBorder: '#59EA788C',
  glassArea: '#B31B2236',
  glassAreaStrong: '#CC1E273C',
  glassBorder: '#414C68',
  glassBorderStrong: '#515D80',
  chip: '#252E49',
  chipStrong: '#303B5D',
  divider: '#303A53',
  dividerStrong: '#414D69',
  cardBg: '#1C2438',
  cardBgThin: '#242D44',
  bubbleFill: '#9E172A48',
  bubbleFillDone: '#661B3048',
  bubbleBorder: '#96B3DC',
  bubbleBorderDone: '#607F9F',
  bubbleText: '#F4F6FF',
  bubbleTextDone: '#BAC9E2',
  bubbleSubText: '#B5C7E5',
  bubbleSubTextDone: '#9AAFC8',
  scrim: '#80070B17',
  scrimSheet: '#A6070B17',
  shadowSoft: '#55020510',
  shadowCard: '#99020510'
};

export class AppTheme {
  private static pref: preferences.Preferences | undefined = undefined;
  private static mode: ThemeMode = ThemeMode.FOLLOW;

  private static systemDark: boolean = false;

  private static windowStage: window.WindowStage | undefined = undefined;
  private static applicationContext: common.ApplicationContext | undefined = undefined;

  static init(context: common.Context): void {
    AppTheme.applicationContext = context.getApplicationContext();
    try {
      AppTheme.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      const saved: number = AppTheme.pref.getSync(KEY_MODE, ThemeMode.FOLLOW) as number;
      AppTheme.mode = AppTheme.normalize(saved);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
      AppTheme.mode = ThemeMode.FOLLOW;
    }
    AppTheme.publish();
    hilog.info(DOMAIN, TAG, 'theme ready: mode=%{public}d dark=%{public}s',
      AppTheme.mode, String(AppTheme.isDark()));
  }

  static applySystemColorMode(cm: ConfigurationConstant.ColorMode | undefined): void {
    // 手动主题也会触发配置回调，不能把应用强制颜色当作系统颜色缓存。
    if (cm === undefined || AppTheme.mode !== ThemeMode.FOLLOW) {
      return;
    }
    const dark: boolean = cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (dark === AppTheme.systemDark) {
      return;
    }
    AppTheme.systemDark = dark;
    // 只有"跟随系统"才需要跟着变；手动选了某一种就不该被系统拖着走
    if (AppTheme.mode === ThemeMode.FOLLOW) {
      AppTheme.applySystemBar();
      AppTheme.publish();
    }
    hilog.info(DOMAIN, TAG, 'system color mode -> %{public}s', String(dark));
  }

  private static normalize(v: number): ThemeMode {
    if (v === ThemeMode.LIGHT || v === ThemeMode.DARK) {
      return v;
    }
    return ThemeMode.FOLLOW;
  }

  static currentMode(): ThemeMode {
    return AppTheme.mode;
  }

  static isDark(): boolean {
    if (AppTheme.mode === ThemeMode.DARK) {
      return true;
    }
    if (AppTheme.mode === ThemeMode.LIGHT) {
      return false;
    }
    return AppTheme.systemDark;
  }

  static palette(dark: boolean = AppTheme.isDark()): AppPalette {
    return dark ? DARK : LIGHT;
  }

  static setMode(mode: ThemeMode): void {
    const next: ThemeMode = AppTheme.normalize(mode);
    if (next === AppTheme.mode) {
      return;
    }
    AppTheme.mode = next;
    try {
      AppTheme.pref?.putSync(KEY_MODE, next);
      AppTheme.pref?.flush().catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'flush theme failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save mode failed: %{public}s', JSON.stringify(err));
    }
    AppTheme.applyNativeColorMode();
    AppTheme.applySystemBar();
    AppTheme.publish();
    hilog.info(DOMAIN, TAG, 'mode -> %{public}d', next);
  }

  private static publish(): void {
    AppStorage.setOrCreate<boolean>(THEME_DARK_KEY, AppTheme.isDark());
    const current: number | undefined = AppStorage.get<number>(THEME_VERSION_KEY);
    AppStorage.setOrCreate<number>(THEME_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }

  static modeText(mode: ThemeMode): string {
    if (mode === ThemeMode.LIGHT) {
      return '浅色';
    }
    if (mode === ThemeMode.DARK) {
      return '深色';
    }
    return '跟随系统';
  }

  static attachWindow(stage: window.WindowStage): void {
    AppTheme.windowStage = stage;
    AppTheme.applyNativeColorMode();
    AppTheme.applySystemBar();
  }

  /** 页面加载后同步原生控件主题，日历等系统弹窗不继承 WithTheme 的局部颜色。 */
  private static applyNativeColorMode(): void {
    if (AppTheme.windowStage === undefined || AppTheme.applicationContext === undefined) {
      return;
    }
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (AppTheme.mode === ThemeMode.DARK) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (AppTheme.mode === ThemeMode.LIGHT) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      AppTheme.applicationContext.setColorMode(colorMode);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'set native color mode failed: %{public}s', JSON.stringify(err));
    }
  }

  private static applySystemBar(): void {
    const stage: window.WindowStage | undefined = AppTheme.windowStage;
    if (stage === undefined) {
      return;
    }
    try {
      const win: window.Window = stage.getMainWindowSync();
      const p: AppPalette = AppTheme.palette();
      win.setWindowBackgroundColor(p.bg1);
      win.setWindowSystemBarProperties({
        statusBarContentColor: p.textPrimary,
        navigationBarContentColor: p.textPrimary
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'applySystemBar failed: %{public}s', JSON.stringify(err));
    }
  }

  static currentText(): string {
    if (AppTheme.mode === ThemeMode.FOLLOW) {
      return `跟随系统（当前${AppTheme.isDark() ? '深色' : '浅色'}）`;
    }
    return AppTheme.modeText(AppTheme.mode);
  }
}
