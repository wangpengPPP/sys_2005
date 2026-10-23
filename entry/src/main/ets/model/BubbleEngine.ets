import { sensor } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bubble } from './BubbleModel';

const DOMAIN: number = 0x0001;
const TAG: string = 'BubbleEngine';

// ---------------- 物理参数（想调手感改这里就行） ----------------

/** 水平方向：传感器读数（m/s²）→ 屏幕加速度（vp/s²）的换算系数。越大越"跟手"，手机一歪泡泡就走 */
const GRAVITY_SCALE: number = 320;
/**
 * 传感器读数 → 屏幕坐标系的符号（**Pura 70 Pro 真机两轮实测校准**）。
 *
 * 不要照 SDK 那句"along the x/y-axis of the device"去推轴向 —— 这台设备的传感器
 * 坐标系与屏幕坐标系整体差了 180°：
 *   - x：传感器读数与屏幕 x **反向** → -1（翻正后手机往哪边歪、泡泡往哪边滚）
 *   - y：传感器读数与屏幕 y **同向**，即传感器 y 轴本身就朝下 → +1
 *     （写成 -y 的话整屏泡泡会往上飘）
 * 以后若又发现某一边整体反向，**只翻对应那个常量**，别动系数、别动别处。
 */
const SENSOR_X_SIGN: number = -1;
const SENSOR_Y_SIGN: number = 1;
/**
 * 垂直方向：同样采用真实重力（vp/s² per m/s²），但**刻意与 GRAVITY_SCALE 分开**。
 *
 * 手持竖屏时，屏幕 y 轴上恒定压着约 9.8 m/s² 的重力分量（这不是"倾斜"，是重力本身），
 * 若沿用 GRAVITY_SCALE(320)，垂直加速度会到 3100+，泡泡一帧就被压穿出界。
 * 55 × 9.8 ≈ 539 —— 正好落在原来固定垂坠值(520)的量级，力度手感不变，
 * 但方向改由真实重力决定：竖屏向下沉、手机倒过来向上浮、屏幕平放则悬停。
 */
const VERTICAL_SCALE: number = 55;
/** 没有重力传感器时（模拟器等）使用的固定垂坠加速度（向下） */
const FALLBACK_G: number = 760;
/** 「发射」初速度（vp/s）：未完成区按住泡泡时向上弹出去的速度，要够快才像"瞬间" */
const LAUNCH_SPEED: number = 2200;
/**
 * 空气阻力系数（1/s）：v *= 1 - DRAG*dt
 * 终端速度 ≈ 加速度 / DRAG，速度建立的时间常数 ≈ 1/DRAG。
 * 原来 1.0 意味着要 1 秒才追上 63% 的速度 —— 手感发"钝"，所以调大。
 */
const DRAG: number = 1.8;
/** 撞壁后保留的速度比例，越小越"不弹" */
const WALL_RESTITUTION: number = 0.30;
/** 泡泡互撞的弹性系数 */
const COLLISION_RESTITUTION: number = 0.32;
/** 传感器读数平滑系数，越大越跟手、越小越顺滑 */
const SENSOR_SMOOTH: number = 0.32;
/** 传感器采样间隔（纳秒），20ms ≈ 50Hz */
const SENSOR_INTERVAL_NS: number = 20000000;
/** 传感器数据超时（ms）：超时视为不可用，回退到默认重力 */
const SENSOR_TIMEOUT: number = 2500;
/** 传感器状态写进 AppStorage 的键，「我的」页读它做自检 */
export const SENSOR_KIND_KEY: string = 'gravitySensorKind';
/** 物理步进间隔（ms），16 ≈ 60fps */
const FRAME_INTERVAL: number = 16;
/** 单帧最大时间步长（s），防止卡顿后泡泡"穿透"墙壁 */
const MAX_DT: number = 0.05;

/** 区域标识 */
export type AreaKind = 'todo' | 'done';

/**
 * 泡泡物理引擎
 *
 * 每帧做四件事：
 *   1. 由重力传感器更新重力向量（设备怎么斜，泡泡就往哪边滚）
 *   2. 重力 + 阻力积分出速度与位置
 *   3. 泡泡之间两两排斥，避免叠在一起看不清字
 *   4. 撞到区域边界反弹
 *
 * 重力只有一套：水平、垂直全部来自真实重力传感器，上下两个区域共用同一套值。
 * 分区不靠"反向的力"，而靠各自容器的边界约束（见 layoutArea / resolveBounds）——
 * 上区的泡泡最多沉到上区容器底部，下区的沉到下区容器底部，两块不会混在一起。
 *
 * 引擎只负责改 Bubble 的 cx/cy，UI 侧靠 @ObjectLink 自动刷新。
 */
export class BubbleEngine {
  private bubbles: Bubble[] = [];
  private running: boolean = false;
  private timer: number = -1;
  private lastTs: number = 0;

  // ---- 重力向量（vp/s²）：上下两个区域共用同一套真实重力，不再按区域反向 ----
  private gx: number = 0;
  /** 垂直方向：向下为正 */
  private gy: number = FALLBACK_G;

  // ---- 原始传感器读数（已换算到屏幕坐标系） ----
  private rawGx: number = 0;
  private rawGy: number = 0;
  private smoothGx: number = 0;
  private smoothGy: number = 0;
  private lastSensorTs: number = 0;

  // ---- 传感器注册状态 ----
  /** 已绑定的传感器 id，-1 表示没绑上 */
  private boundId: number = -1;
  /** 当前用的是哪种传感器：gravity / accelerometer / none */
  private sensorKind: string = 'none';
  /** 最近一帧重力是否真的来自传感器（false = 走的是固定垂坠兜底） */
  private sensorAlive: boolean = false;

  /** 重力传感器回调（箭头函数属性，保证 this 指向本实例） */
  private onGravityData: (data: sensor.GravityResponse) => void =
    (data: sensor.GravityResponse): void => {
      this.applySensor(data.x, data.y);
    };

  /** 加速度计回调：静止时读数≈重力，可当重力用 */
  private onAccelData: (data: sensor.AccelerometerResponse) => void =
    (data: sensor.AccelerometerResponse): void => {
      this.applySensor(data.x, data.y);
    };

  /**
   * 两种传感器读数落到同一个地方，统一到"屏幕坐标 + 向下为正"：
   *  - `rawGx > 0` = 重力指向屏幕右侧（泡泡往右滚）
   *  - `rawGy > 0` = 重力指向屏幕下方（泡泡往下落）
   *
   * 两个轴的符号见 SENSOR_X_SIGN / SENSOR_Y_SIGN 的注释（真机实测值，别按文档推）。
   */
  private applySensor(x: number, y: number): void {
    this.rawGx = x * SENSOR_X_SIGN;
    this.rawGy = y * SENSOR_Y_SIGN;
    this.lastSensorTs = Date.now();
  }

  /** 传感器类型（给「我的」页自检用） */
  getSensorKind(): string {
    return this.sensorKind;
  }

  /** 重力此刻是否真的在驱动泡泡 */
  isSensorAlive(): boolean {
    return this.sensorAlive;
  }

  // ---- 手势交互状态 ----
  /** 正被手指拖动的泡泡 id，-1 表示没有 */
  private draggingId: number = -1;

  /**
   * 泡泡被"发射"飞出本区顶部时的回调（未完成区按住往上弹）
   * HomePage 在这个回调里把它改成已完成、交给上半区继续接管
   */
  onEscapedUp: (b: Bubble) => void = (b: Bubble): void => {
  };

  /** 泡泡被"发射"落出本区底部时的回调（已完成区按住往下落） */
  onEscapedDown: (b: Bubble) => void = (b: Bubble): void => {
  };

  /** 绑定数据源 */
  setBubbles(list: Bubble[]): void {
    this.bubbles = list;
  }

  /** 手指按下开始拖动：物理引擎对这颗泡泡放手，位置全交给手势 */
  beginDrag(id: number): void {
    this.draggingId = id;
  }

  /** 松手：交还给物理引擎，泡泡按各自区域的重力自然归位 */
  endDrag(): void {
    this.draggingId = -1;
  }

  /** 把一颗未完成的泡泡向上发射出去（按住泡泡触发） */
  launchUp(b: Bubble): void {
    if (b.done || b.dragging) {
      return;
    }
    b.flying = true;
    // 竖直向上，速度给足 —— 视觉上是"一下子弹上去"，不是慢慢飘
    b.vx = 0;
    b.vy = -LAUNCH_SPEED;
  }

  /** 把一颗已完成的泡泡向下发射回去（按住泡泡触发） */
  launchDown(b: Bubble): void {
    if (!b.done || b.dragging) {
      return;
    }
    b.flying = true;
    b.vx = 0;
    b.vy = LAUNCH_SPEED;
  }

  /** 新增一个泡泡（已在区域内时立即约束到边界内） */
  add(b: Bubble): void {
    this.bubbles.push(b);
    this.clampToBounds(b);
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 启动物理循环（重复调用安全） */
  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.lastTs = 0;
    this.bindSensor();
    this.timer = setInterval((): void => {
      this.tick();
    }, FRAME_INTERVAL);
  }

  /** 停止物理循环并释放传感器 */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.unbindSensor();
  }

  /**
   * 区域尺寸变化时调用：注入边界。
   * 首次投放的泡泡做随机散布，已投放的只做边界收敛（旋转屏幕时不会跑到区域外）。
   */
  layoutArea(done: boolean, w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    const list: Bubble[] = this.bubbles;
    for (let i = 0; i < list.length; i++) {
      const b: Bubble = list[i];
      if (b.done !== done) {
        continue;
      }
      b.boundLeft = 0;
      b.boundTop = 0;
      b.boundRight = w;
      b.boundBottom = h;
      if (!b.placed) {
        this.scatter(b, w, h);
        b.placed = true;
      } else {
        this.clampToBounds(b);
      }
    }
  }

  /** 把泡泡随机撒进区域（初次投放） */
  private scatter(b: Bubble, w: number, h: number): void {
    const margin: number = b.r + 4;
    const spanX: number = Math.max(1, w - margin * 2);
    const spanY: number = Math.max(1, h - margin * 2);
    // 初次落位就偏向自己那一侧：上区的靠上冒、下区的靠下沉，首帧不会"从对面滚过来"
    const yRatio: number = b.done
      ? Math.random() * 0.55
      : 0.45 + Math.random() * 0.55;
    b.cx = margin + Math.random() * spanX;
    b.cy = margin + Math.min(1, yRatio) * spanY;
    // 给一点随机初速度，落位时像泡泡一样轻轻荡开（初速方向与重力一致，都是往下落）
    b.vx = (Math.random() - 0.5) * 90;
    b.vy = (Math.random() - 0.5) * 90 + 60;
  }

  /** 把泡泡夹回边界内（防止区域变小后泡泡卡在界外） */
  private clampToBounds(b: Bubble): void {
    const minX: number = b.boundLeft + b.r;
    const maxX: number = b.boundRight - b.r;
    const minY: number = b.boundTop + b.r;
    const maxY: number = b.boundBottom - b.r;
    b.cx = maxX > minX ? Math.min(Math.max(b.cx, minX), maxX) : (b.boundLeft + b.boundRight) / 2;
    b.cy = maxY > minY ? Math.min(Math.max(b.cy, minY), maxY) : (b.boundTop + b.boundBottom) / 2;
  }

  // ---------------- 物理步进 ----------------

  private tick: () => void = (): void => {
    const now: number = Date.now();
    if (this.lastTs === 0) {
      this.lastTs = now;
      return;
    }
    let dt: number = (now - this.lastTs) / 1000;
    this.lastTs = now;
    if (dt <= 0) {
      return;
    }
    if (dt > MAX_DT) {
      dt = MAX_DT;
    }
    this.updateGravity();
    this.integrate(dt);
    this.resolveCollisions();
    this.resolveBounds();
    this.checkEscaped();
  };

  /** 由重力传感器得出重力向量；传感器不可用时退回固定垂坠 */
  private updateGravity(): void {
    const now: number = Date.now();
    const alive: boolean = this.boundId !== -1 && (now - this.lastSensorTs) < SENSOR_TIMEOUT;
    this.sensorAlive = alive;
    if (alive) {
      this.smoothGx = this.smoothGx + (this.rawGx - this.smoothGx) * SENSOR_SMOOTH;
      this.smoothGy = this.smoothGy + (this.rawGy - this.smoothGy) * SENSOR_SMOOTH;
      // 水平：完全跟随设备左右倾斜
      this.gx = this.smoothGx * GRAVITY_SCALE;
      // 垂直：同样跟随真实重力。竖屏正持时 smoothGy ≈ +9.8（重力自身的分量，不是倾斜），
      // 乘 VERTICAL_SCALE 后约 539 vp/s²，力度与原来的固定垂坠值相当；
      // 手机倒置时 smoothGy 转负、泡泡整体向上浮，屏幕平放时趋近 0、泡泡悬停。
      this.gy = this.smoothGy * VERTICAL_SCALE;
    } else {
      // 模拟器等没有重力传感器：只保留一个向下的固定垂坠，水平不动
      this.gx = 0;
      this.gy = FALLBACK_G;
    }
  }

  /** 重力 + 阻力积分 */
  private integrate(dt: number): void {
    const list: Bubble[] = this.bubbles;
    const damp: number = Math.max(0, 1 - DRAG * dt);
    for (let i = 0; i < list.length; i++) {
      const b: Bubble = list[i];
      // 正被手指拖着的泡泡不受重力，位置由手势直接给
      if (b.dragging || b.id === this.draggingId) {
        continue;
      }
      // 上下两区共用同一套真实重力：都朝重力方向落，分区由各自容器边界兜住
      b.vx = (b.vx + this.gx * dt) * damp;
      b.vy = (b.vy + this.gy * dt) * damp;
      b.cx = b.cx + b.vx * dt;
      b.cy = b.cy + b.vy * dt;
    }
  }

  /** 泡泡之间两两排斥，避免叠在一起 */
  private resolveCollisions(): void {
    const list: Bubble[] = this.bubbles;
    const n: number = list.length;
    for (let i = 0; i < n; i++) {
      const a: Bubble = list[i];
      // 拖拽中或正在飞行（发射）的泡泡不参与碰撞，直接穿过去
      if (a.dragging || a.flying) {
        continue;
      }
      for (let j = i + 1; j < n; j++) {
        const b: Bubble = list[j];
        // 分属两个区域的泡泡互不干涉
        if (b.dragging || b.flying || a.done !== b.done) {
          continue;
        }
        let dx: number = b.cx - a.cx;
        let dy: number = b.cy - a.cy;
        const minDist: number = a.r + b.r + 4;
        let distSq: number = dx * dx + dy * dy;
        if (distSq >= minDist * minDist) {
          continue;
        }
        let dist: number = Math.sqrt(distSq);
        if (dist < 0.01) {
          // 完全重合时给一个确定的方向，避免除零
          dx = 1;
          dy = 0;
          dist = 0.01;
        }
        const nx: number = dx / dist;
        const ny: number = dy / dist;

        // 位置分离
        const push: number = (minDist - dist) * 0.5;
        a.cx -= nx * push;
        a.cy -= ny * push;
        b.cx += nx * push;
        b.cy += ny * push;

        // 法向相对速度 < 0 说明正在靠近，交换部分动量
        const relV: number = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
        if (relV < 0) {
          const impulse: number = relV * (1 + COLLISION_RESTITUTION) * 0.5;
          a.vx += nx * impulse;
          a.vy += ny * impulse;
          b.vx -= nx * impulse;
          b.vy -= ny * impulse;
        }
      }
    }
  }

  /** 撞壁反弹 */
  private resolveBounds(): void {
    const list: Bubble[] = this.bubbles;
    for (let i = 0; i < list.length; i++) {
      const b: Bubble = list[i];
      // 拖拽中的泡泡由手势全权控制，不参与边界约束
      if (b.dragging || b.id === this.draggingId) {
        continue;
      }
      const minX: number = b.boundLeft + b.r;
      const maxX: number = b.boundRight - b.r;
      const minY: number = b.boundTop + b.r;
      const maxY: number = b.boundBottom - b.r;

      if (maxX <= minX) {
        b.cx = (b.boundLeft + b.boundRight) / 2;
        b.vx = 0;
      } else if (b.cx < minX) {
        b.cx = minX;
        b.vx = Math.abs(b.vx) * WALL_RESTITUTION;
      } else if (b.cx > maxX) {
        b.cx = maxX;
        b.vx = -Math.abs(b.vx) * WALL_RESTITUTION;
      }

      // 发射中的泡泡要能冲出本区顶部，飞去对面区域，所以不做上下约束
      if (b.flying) {
        continue;
      }

      if (maxY <= minY) {
        b.cy = (b.boundTop + b.boundBottom) / 2;
        b.vy = 0;
      } else if (b.cy < minY) {
        b.cy = minY;
        b.vy = Math.abs(b.vy) * WALL_RESTITUTION;
      } else if (b.cy > maxY) {
        b.cy = maxY;
        b.vy = -Math.abs(b.vy) * WALL_RESTITUTION;
      }
    }
  }

  /** 发射出去的泡泡整个飞离本区后，通知外部接管（换完成状态、交给对面区域） */
  private checkEscaped(): void {
    const list: Bubble[] = this.bubbles;
    for (let i = 0; i < list.length; i++) {
      const b: Bubble = list[i];
      if (!b.flying) {
        continue;
      }
      if (b.cy < b.boundTop - b.r * 0.6) {
        b.flying = false;
        this.onEscapedUp(b);
      } else if (b.cy > b.boundBottom + b.r * 0.6) {
        b.flying = false;
        this.onEscapedDown(b);
      }
    }
  }

  // ---------------- 重力传感器 ----------------

  /**
   * 绑定重力来源。
   *
   * 按可靠性依次试：重力传感器（GRAVITY=257，融合传感器，直接给重力分量）
   * → 加速度计（ACCELEROMETER=1，静止时读数≈重力）。
   * 每次先用 getSingleSensorSync 问一下系统有没有这颗传感器 ——
   * 比等 sensor.on 抛错更早失败，日志也更清楚。
   * 全都不行时 sensorKind = 'none'，物理循环会退回固定垂坠（水平方向就不跟手了，
   * 但至少泡泡还能正常分区落位）。
   */
  private bindSensor(): void {
    if (this.boundId !== -1) {
      return;
    }
    const withInterval: sensor.Options = { interval: SENSOR_INTERVAL_NS };
    // ① 重力传感器 + 指定采样率
    if (this.tryBind(sensor.SensorId.GRAVITY, true, withInterval)) {
      return;
    }
    // ② 加速度计 + 指定采样率
    if (this.tryBind(sensor.SensorId.ACCELEROMETER, false, withInterval)) {
      return;
    }
    // ③ 有些设备不接受自定义采样间隔 → 用默认间隔再来一轮
    if (this.tryBind(sensor.SensorId.GRAVITY, true, undefined)) {
      return;
    }
    if (this.tryBind(sensor.SensorId.ACCELEROMETER, false, undefined)) {
      return;
    }
    this.sensorKind = 'none';
    AppStorage.setOrCreate<string>(SENSOR_KIND_KEY, 'none');
    hilog.error(DOMAIN, TAG, 'no usable gravity source on this device');
  }

  /**
   * 试着绑一颗传感器
   * @param id 传感器 id
   * @param isGravity 是不是重力传感器（决定用哪个回调）
   * @param options 采样选项，undefined 表示用系统默认间隔
   * @returns 绑上了返回 true
   */
  private tryBind(id: sensor.SensorId, isGravity: boolean, options: sensor.Options | undefined): boolean {
    try {
      // 先确认这颗传感器存在，不存在会抛 14500101
      sensor.getSingleSensorSync(id);
      if (isGravity) {
        sensor.on(sensor.SensorId.GRAVITY, this.onGravityData, options);
      } else {
        sensor.on(sensor.SensorId.ACCELEROMETER, this.onAccelData, options);
      }
      this.boundId = id;
      this.sensorKind = isGravity ? 'gravity' : 'accelerometer';
      AppStorage.setOrCreate<string>(SENSOR_KIND_KEY, this.sensorKind);
      hilog.info(DOMAIN, TAG, 'sensor bound: %{public}s, id=%{public}d, interval=%{public}s',
        this.sensorKind, id, options === undefined ? 'default' : 'custom');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'sensor id=%{public}d unavailable: %{public}s', id, JSON.stringify(err));
      return false;
    }
  }

  private unbindSensor(): void {
    if (this.boundId === -1) {
      return;
    }
    try {
      if (this.boundId === sensor.SensorId.GRAVITY) {
        sensor.off(sensor.SensorId.GRAVITY, this.onGravityData);
      } else {
        sensor.off(sensor.SensorId.ACCELEROMETER, this.onAccelData);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'unbind sensor failed: %{public}s', JSON.stringify(err));
    }
    this.boundId = -1;
    this.sensorAlive = false;
  }
}
