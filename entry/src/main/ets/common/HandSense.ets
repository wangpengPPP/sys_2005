import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { motion } from '@kit.MultimodalAwarenessKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'HandSense';
const PREF_NAME: string = 'lingxing_hand';
const KEY_MODE: string = 'hand_mode';

const MOTION_SYSCAP: string = 'SystemCapability.MultimodalAwareness.Motion';

/**
 * 落点取样的环带：左右各占屏宽的 34%，中间那块不表态。
 *
 * 只在设备不支持系统握姿感知时才会用到（见 HandSource.TOUCH）。
 * 中间那一大块最没信息量 —— 两只手都够得着，记下来只会把噪声掺进判断里。
 */
const EDGE_RATIO: number = 0.34;
/** 滑动窗口：只记住最近这么多次落点，人会换姿势，旧样本不该永远作数 */
const WINDOW: number = 16;
/** 攒够这么多次落点才开始表态，免得刚上手就猜错 */
const MIN_SAMPLES: number = 8;
/** 一边比另一边多出这么多次才翻边 —— 留出滞回，不然会在临界线上来回跳 */
const FLIP_MARGIN: number = 5;

/**
 * 操作手模式。
 *
 * AUTO 听系统的；手动锁定用来盖过系统判断 —— 有人习惯左手拿右手点，
 * 这种时候"握持手"和"操作手"会给出相反的答案，得让用户说了算。
 */
export enum HandMode {
  AUTO = 0,
  RIGHT = 1,
  LEFT = 2
}

/**
 * 当前结论是从哪儿来的，从最可信排到最将就。
 *
 * 系统给了两级能力：握持手（哪只手拿着）和操作手（哪只手在点屏幕）。
 * 我们想要的是"拿着"那只手 —— 按钮是给拇指够的，拇指长在握持手上。
 */
export enum HandSource {
  /** 还没拿到任何结论 */
  NONE = 0,
  /** 系统握持手感知（API 20+，机型支持才有） */
  HOLDING = 1,
  /** 系统操作手感知（API 15+，覆盖面更广） */
  OPERATING = 2,
  /** 落点推断：设备两项都不支持时的兜底 */
  TOUCH = 3
}

/** 握姿版本号：谁要跟着左右换边，盯这个（见 pages/Index.ets） */
export const HAND_VERSION_KEY: string = 'handVersion';

/** 握持手回调：定义在模块级，off 的时候要拿同一个引用 */
function onHoldingHand(status: motion.HoldingHandStatus): void {
  HandSense.applyHolding(status);
}

function onOperatingHand(status: motion.OperatingHandStatus): void {
  HandSense.applyOperating(status, false);
}

export class HandSense {
  private static pref: preferences.Preferences | undefined = undefined;
  private static mode: HandMode = HandMode.AUTO;
  private static source: HandSource = HandSource.NONE;
  /** 自动模式下的结论：是不是左手 */
  private static autoLeft: boolean = false;
  /** 出过结论没有 —— 只影响"我的"页那行说明怎么写 */
  private static decided: boolean = false;
  /** 系统订阅着没有，避免重复 on 出多份回调 */
  private static listening: boolean = false;
  /** 最近若干次落点：-1 偏左，+1 偏右（兜底方案用） */
  private static samples: number[] = [];

  static init(context: common.Context): void {
    try {
      HandSense.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      const saved: number = HandSense.pref.getSync(KEY_MODE, HandMode.AUTO) as number;
      HandSense.mode = HandSense.normalize(saved);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
      HandSense.mode = HandMode.AUTO;
    }
    HandSense.publish();
    hilog.info(DOMAIN, TAG, 'hand ready: mode=%{public}d', HandSense.mode);
  }

  /**
   * 订阅系统握姿感知。
   *
   * 两级能力挨个试：握持手 → 操作手 → 都没有就记下来走落点推断。
   * 不支持的机型会抛 801（Capability not supported），属于预期路径，不当错误报。
   */
  static start(): void {
    if (HandSense.listening) {
      return;
    }
    if (canIUse(MOTION_SYSCAP)) {
      try {
        motion.on('holdingHandChanged', onHoldingHand);
        HandSense.source = HandSource.HOLDING;
        HandSense.listening = true;
      } catch (err) {
        hilog.info(DOMAIN, TAG, 'holding hand unsupported: %{public}s', JSON.stringify(err));
      }
    }
    if (!HandSense.listening && canIUse(MOTION_SYSCAP)) {
      try {
        motion.on('operatingHandChanged', onOperatingHand);
        HandSense.source = HandSource.OPERATING;
        HandSense.listening = true;
      } catch (err) {
        hilog.info(DOMAIN, TAG, 'operating hand unsupported: %{public}s', JSON.stringify(err));
      }
    }
    if (!HandSense.listening) {
      HandSense.source = HandSource.TOUCH;
    }
    // 订阅之后补问一次当前状态：回调要等用户换手才来，那之前按钮会一直摆错边
    HandSense.readCurrent();
    HandSense.publish();
    hilog.info(DOMAIN, TAG, 'source -> %{public}d', HandSense.source);
  }

  static stop(): void {
    if (!HandSense.listening) {
      return;
    }
    try {
      if (HandSense.source === HandSource.HOLDING) {
        motion.off('holdingHandChanged', onHoldingHand);
      } else if (HandSense.source === HandSource.OPERATING) {
        motion.off('operatingHandChanged', onOperatingHand);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'off failed: %{public}s', JSON.stringify(err));
    }
    HandSense.listening = false;
  }

  /**
   * 现问一次系统，用来补上"订阅了但回调还没来"这段空窗。
   *
   * 握持手没有同步查询接口，只能借操作手的结果先摆个位置 ——
   * 大概率一致，真不一致等握持手回调一到就纠正。
   */
  private static readCurrent(): void {
    if (HandSense.decided || !HandSense.listening) {
      return;
    }
    try {
      HandSense.applyOperating(motion.getRecentOperatingHandStatus(), true);
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'read operating hand failed: %{public}s', JSON.stringify(err));
    }
  }

  static applyHolding(status: motion.HoldingHandStatus): void {
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      HandSense.settle(true);
    } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      HandSense.settle(false);
    }
    // 双手 / 未握持 / 未知：保持现状。
    // 把手机搁桌上就翻边、拿起来再翻回来，比一直摆错边更烦人
  }

  /**
   * 操作手结果。
   *
   * @param bootstrap 仅用于首次摸底。操作手是"哪只手在点"，和"哪只手拿着"不是一回事，
   *                  用户真换手之后就该以握持手为准，别被点屏幕的手带偏
   */
  static applyOperating(status: motion.OperatingHandStatus, bootstrap: boolean): void {
    if (!bootstrap && HandSense.source === HandSource.HOLDING) {
      return;
    }
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      HandSense.settle(true);
    } else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      HandSense.settle(false);
    }
  }

  /**
   * 记一次落点 —— 只在系统两项能力都不可用时才作数。
   *
   * 调用方必须先剔掉底栏那一条（含新增按钮）：底栏自己会跟着换边，
   * 把它算进来就成了自己教自己，按钮挪到哪边样本就偏哪边。
   */
  static sample(x: number, width: number): void {
    if (HandSense.mode !== HandMode.AUTO || width <= 0) {
      return;
    }
    // 系统已经表态了就不听落点；系统没表态（或压根不支持）才靠它
    if (HandSense.decided && HandSense.source !== HandSource.TOUCH) {
      return;
    }
    const ratio: number = x / width;
    let vote: number = 0;
    if (ratio <= EDGE_RATIO) {
      vote = -1;
    } else if (ratio >= 1 - EDGE_RATIO) {
      vote = 1;
    } else {
      return;
    }

    HandSense.samples.push(vote);
    if (HandSense.samples.length > WINDOW) {
      HandSense.samples.shift();
    }
    if (HandSense.samples.length < MIN_SAMPLES) {
      return;
    }

    let sum: number = 0;
    for (let i = 0; i < HandSense.samples.length; i++) {
      sum += HandSense.samples[i];
    }
    if (Math.abs(sum) < FLIP_MARGIN) {
      return;
    }
    const wantLeft: boolean = sum < 0;
    if (HandSense.decided && wantLeft === HandSense.autoLeft) {
      return;
    }
    HandSense.samples = [];
    // 不动 source：这台设备的"能力来源"不该被一次落点改写，
    // 不然传感器随后给出的结论会被落点盖掉
    HandSense.settle(wantLeft);
  }

  /**
   * 落一个结论。
   *
   * 只把版本号推给界面，不出任何提示 —— 换手是用户自己做的动作，
   * 按钮已经跟着滑过去了，再弹一句说明纯属打扰。
   */
  private static settle(left: boolean): void {
    if (HandSense.decided && left === HandSense.autoLeft) {
      return;
    }
    const changed: boolean = HandSense.decided;
    HandSense.autoLeft = left;
    HandSense.decided = true;
    HandSense.publish();
    if (changed) {
      hilog.info(DOMAIN, TAG, 'settled -> %{public}s', left ? 'left' : 'right');
    }
  }

  private static normalize(v: number): HandMode {
    if (v === HandMode.RIGHT || v === HandMode.LEFT) {
      return v;
    }
    return HandMode.AUTO;
  }

  static currentMode(): HandMode {
    return HandSense.mode;
  }

  /** 新增按钮该摆哪边 —— 界面只问这一个问题 */
  static isLeft(): boolean {
    if (HandSense.mode === HandMode.LEFT) {
      return true;
    }
    if (HandSense.mode === HandMode.RIGHT) {
      return false;
    }
    return HandSense.autoLeft;
  }

  static setMode(mode: HandMode): void {
    const next: HandMode = HandSense.normalize(mode);
    if (next === HandSense.mode) {
      return;
    }
    HandSense.mode = next;
    try {
      HandSense.pref?.putSync(KEY_MODE, next);
      HandSense.pref?.flush().catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'flush hand failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save hand failed: %{public}s', JSON.stringify(err));
    }
    // 从"手动"切回"自动"时补问一次，否则要等用户换手才有新结论
    if (next === HandMode.AUTO) {
      HandSense.readCurrent();
    }
    HandSense.publish();
    hilog.info(DOMAIN, TAG, 'mode -> %{public}d', next);
  }

  private static publish(): void {
    const current: number | undefined = AppStorage.get<number>(HAND_VERSION_KEY);
    AppStorage.setOrCreate<number>(HAND_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }

  static modeText(mode: HandMode): string {
    if (mode === HandMode.RIGHT) {
      return '右手';
    }
    if (mode === HandMode.LEFT) {
      return '左手';
    }
    return '自动';
  }

  /** 「我的」页那行小字：把"现在按什么摆、结论哪来的"说清楚 */
  static currentText(): string {
    if (HandSense.mode === HandMode.LEFT) {
      return '已锁定左手，新增按钮固定在左边';
    }
    if (HandSense.mode === HandMode.RIGHT) {
      return '已锁定右手，新增按钮固定在右边';
    }
    if (!HandSense.decided) {
      return HandSense.source === HandSource.TOUCH
        ? '本机不支持系统握姿感知，正按你点屏幕的位置推断'
        : '等系统识别握持手…';
    }
    if (HandSense.source === HandSource.HOLDING) {
      return `系统识别到你用${HandSense.autoLeft ? '左' : '右'}手握持，按钮跟着走`;
    }
    if (HandSense.source === HandSource.OPERATING) {
      return `系统识别到你用${HandSense.autoLeft ? '左' : '右'}手操作，按钮跟着走`;
    }
    return `按你点屏幕的位置推断为${HandSense.autoLeft ? '左' : '右'}手`;
  }
}
