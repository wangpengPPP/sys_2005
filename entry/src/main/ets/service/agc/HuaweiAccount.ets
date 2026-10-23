import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { formatClockTime } from '../../common/DateUtil';
import { isAgcConfigured } from './AgcConfig';

const DOMAIN: number = 0x0001;
const TAG: string = 'HuaweiAccount';
const PREF_NAME: string = 'lingxing_account';
const KEY_ACCOUNT: string = 'hw_account';

/**
 * 会话有效期：30 天。
 *
 * 本地存着的 token 是"上一次换回来的会话"，它一定有寿命 —— 服务端会失效、
 * 用户会在别处改密码、久到一定程度就该重新走一次授权。
 * 之前这个账号是**一旦登录就永远算登录**，装完放两个月再打开还是"已登录"，
 * 那时拿 token 去调云函数只会被服务端拒掉，UI 上却看不出任何问题。
 * 现在到点由客户端自己先作废，宁可让用户重新点一次登录。
 */
export const SESSION_TTL_MS: number = 30 * 24 * 60 * 60 * 1000;

/** 华为账号登录一次拿到的身份信息（本地留一份，下次启动免登录） */
export interface HwAccount {
  /** 应用级用户标识（同一个开发者账号下不同应用不一样） */
  openId: string;
  /** 开发者级用户标识（同一个开发者账号下所有应用一致，做账号体系用它） */
  unionId: string;
  /** 服务端会话 token，由云函数签发 */
  token: string;
  /** 会话签发时间 */
  signedAt: number;
  /** 昵称 / 头像：走 profile scope 才有，没有就用云端默认昵称 */
  nickName: string;
  avatarUri: string;
}

/** 登录结果：华为账号那边能直接给的就这些，uid 要云函数换 */
export interface HwAuthCode {
  code: string;
  openId: string;
  unionId: string;
  /** 昵称：走 profile scope 才有，没有就是空串（云端会给兜底名） */
  nickName: string;
  /** 头像地址：同上；注意华为头像链接会失效，拿到后建议尽快下载 */
  avatarUri: string;
}

/**
 * 华为账号登录（Account Kit）
 *
 * 只做一件事：调起登录页 / 走静默登录，拿到 **authorizationCode**。
 * 这个 code 是一次性的、5 分钟有效期 —— 必须立刻交给服务端换成 uid，
 * 客户端拿到的 openId/unionId 不能直接信（能伪造），只能当展示用。
 *
 * 用 AuthorizationWithHuaweiIDRequest（授权请求）而不是 LoginWithHuaweiIDRequest（登录请求）：
 * 登录请求拿不到头像昵称，只能拿到 code/openID/unionID，云端会兜底成"用户xxxx"。
 * 授权请求带上 scope:['profile'] + permission:['serviceauthcode']，
 * 一次拿全：昵称 / 头像 / authorizationCode / unionID。
 * forceAuthorization=false 时，之前授权过就静默返回，只有首次才拉一次授权页。
 */
export class HuaweiAccount {
  private static pref: preferences.Preferences | undefined = undefined;
  private static ready: boolean = false;
  private static account: HwAccount | undefined = undefined;

  static init(context: common.Context): void {
    if (HuaweiAccount.ready) {
      return;
    }
    try {
      HuaweiAccount.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      HuaweiAccount.ready = true;
      const raw: string = HuaweiAccount.pref.getSync(KEY_ACCOUNT, '') as string;
      if (raw.length > 0) {
        HuaweiAccount.account = JSON.parse(raw) as HwAccount;
        hilog.info(DOMAIN, TAG, 'restored account %{public}s', HuaweiAccount.account.unionId);
        // 恢复出来的账号可能早就过期了，启动时就地作废，别让 UI 显示一个假的"已登录"
        if (HuaweiAccount.expireIfStale()) {
          hilog.info(DOMAIN, TAG, 'restored account expired, cleared');
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  /** AGC 那边配好了没（没配的话点登录必然失败，UI 要提前说清楚） */
  static isConfigured(): boolean {
    return isAgcConfigured();
  }

  /** 手里这份登录态是不是已经过了有效期 */
  static isExpired(): boolean {
    const acc: HwAccount | undefined = HuaweiAccount.account;
    if (acc === undefined) {
      return false;
    }
    // signedAt 是后加的字段，早期数据没有：那种一律当"刚签发"，不去冤枉老用户
    if (acc.signedAt === undefined || acc.signedAt === null || acc.signedAt <= 0) {
      return false;
    }
    return Date.now() - acc.signedAt > SESSION_TTL_MS;
  }

  /** 过期就清掉；返回 true 表示"刚刚被作废了"（调用方可以提示一次） */
  static expireIfStale(): boolean {
    if (!HuaweiAccount.isExpired()) {
      return false;
    }
    hilog.info(DOMAIN, TAG, 'session expired, signing out locally');
    HuaweiAccount.signOut();
    return true;
  }

  /** 本地有没有登录态（过期的也算没有） */
  static isSignedIn(): boolean {
    return HuaweiAccount.current() !== undefined;
  }

  /** 当前账号（没登录、或登录态已过期，都返回 undefined） */
  static current(): HwAccount | undefined {
    if (HuaweiAccount.account === undefined || HuaweiAccount.isExpired()) {
      return undefined;
    }
    return HuaweiAccount.account;
  }

  // ─────────────────────────────────────────────────────────────
  //  展示用的派生值
  // ─────────────────────────────────────────────────────────────

  /**
   * 昵称：真昵称 → 「星友 + uid 尾号」 → 空串。
   *
   * 走 LoginWithHuaweiIDRequest 时是不带 profile scope 的，拿不到真昵称，
   * 那时云端会给一个默认名；万一云端也没给，就用 uid 尾号凑一个能区分的名字，
   * 免得界面上到处是"已登录"这种没有信息量的字。
   */
  static displayName(): string {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined) {
      return '';
    }
    if (acc.nickName !== undefined && acc.nickName !== null && acc.nickName.length > 0) {
      return acc.nickName;
    }
    const tail: string = HuaweiAccount.uidTail(4);
    return tail.length > 0 ? `星友${tail}` : '已登录';
  }

  /** 头像兜底用的首字 */
  static avatarInitial(): string {
    const name: string = HuaweiAccount.displayName();
    return name.length > 0 ? name.substring(0, 1) : '星';
  }

  /** 有头像地址就用真的，没有就空串（调用方退回首字） */
  static avatarUri(): string {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined || acc.avatarUri === undefined || acc.avatarUri === null) {
      return '';
    }
    return acc.avatarUri;
  }

  /** uid 的后 n 位，前面加个省略号：…A1B2 */
  static uidTail(count: number): string {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined) {
      return '';
    }
    const uid: string = acc.unionId;
    if (uid.length <= count) {
      return uid;
    }
    return `…${uid.substring(uid.length - count)}`;
  }

  /** 完整 uid（账号详情里给，方便用户报给对面加好友） */
  static uid(): string {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    return acc === undefined ? '' : acc.unionId;
  }

  /** 这次是几点登进来的 */
  static signedAtText(): string {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined || acc.signedAt === undefined) {
      return '—';
    }
    return formatClockTime(acc.signedAt);
  }

  /** 会话还剩几天（向上取整，已过期给 0） */
  static sessionDaysLeft(): number {
    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined || acc.signedAt === undefined) {
      return 0;
    }
    const left: number = SESSION_TTL_MS - (Date.now() - acc.signedAt);
    if (left <= 0) {
      return 0;
    }
    return Math.ceil(left / (24 * 60 * 60 * 1000));
  }

  /** 会话 token：调云函数时带上，云函数用它换出可信的 uid */
  static token(): string {
    // 用 current() 而不是直接摸 account：过期会话的 token 递出去只会被服务端拒，
    // 不如在这里就当作"没有 token"
    const acc: HwAccount | undefined = HuaweiAccount.current();
    return acc === undefined ? '' : acc.token;
  }

  /** 把昵称/头像补进本地账号（云函数 login 时会回填） */
  static patchProfile(nickName: string, avatarUri: string, token: string, unionId: string, openId: string): void {
    const next: HwAccount = {
      openId: openId,
      unionId: unionId,
      token: token,
      signedAt: Date.now(),
      nickName: nickName,
      avatarUri: avatarUri
    };
    HuaweiAccount.account = next;
    HuaweiAccount.persist();
  }

  /**
   * 调起华为账号登录，拿一次性授权码
   * @param context UIAbilityContext（登录页要它才能拉起）
   */
  static async fetchAuthCode(context: common.UIAbilityContext): Promise<HwAuthCode> {
    const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
    const request: authentication.AuthorizationWithHuaweiIDRequest =
      provider.createAuthorizationWithHuaweiIDRequest();
    // 头像昵称
    request.scopes = ['profile'];
    // 服务端要用 code 换身份，必须带这个 permission 才会返回 authorizationCode
    request.permissions = ['serviceauthcode'];
    // true：用户还没授权过头像昵称时，拉起授权页让人点同意。
    // 这里必须 true —— 官方 FAQ 实锤：false 时未授权**不会弹页**，直接回调
    // 1001502002 "The application is not authorized"。已授权过则依旧静默返回。
    request.forceAuthorization = true;
    // state 防跨站伪造，服务端可比对
    request.state = util.generateRandomUUID();

    const controller: authentication.AuthenticationController =
      new authentication.AuthenticationController(context);
    const response: authentication.AuthenticationResponse = await controller.executeRequest(request);
    const authResp: authentication.AuthorizationWithHuaweiIDResponse =
      response as authentication.AuthorizationWithHuaweiIDResponse;
    const credential: authentication.AuthorizationWithHuaweiIDCredential | undefined = authResp.data;

    if (credential === undefined) {
      throw new Error('华为账号没有返回凭证');
    }
    const code: string | undefined = credential.authorizationCode;
    if (code === undefined || code.length === 0) {
      throw new Error('没拿到授权码，请确认 AGC 已开通华为账号且配置了 client_id');
    }
    const result: HwAuthCode = {
      code: code,
      openId: credential.openID ?? '',
      unionId: credential.unionID ?? '',
      nickName: credential.nickName ?? '',
      avatarUri: credential.avatarUri ?? ''
    };
    hilog.info(DOMAIN, TAG, 'auth code acquired, unionId=%{public}s nick=%{public}s',
      result.unionId, result.nickName);
    return result;
  }

  /** 退出登录：清掉本地账号（服务端会话由云函数按需失效） */
  static signOut(): void {
    HuaweiAccount.account = undefined;
    const pref: preferences.Preferences | undefined = HuaweiAccount.pref;
    if (pref === undefined) {
      return;
    }
    try {
      pref.deleteSync(KEY_ACCOUNT);
      pref.flushSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'signOut failed: %{public}s', JSON.stringify(err));
    }
  }

  private static persist(): void {
    const pref: preferences.Preferences | undefined = HuaweiAccount.pref;
    const acc: HwAccount | undefined = HuaweiAccount.account;
    if (pref === undefined || acc === undefined) {
      return;
    }
    try {
      pref.putSync(KEY_ACCOUNT, JSON.stringify(acc));
      pref.flushSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 把系统抛出的错误码翻译成人能看懂的话 */
  static explain(err: BusinessError): string {
    const code: number = err.code;
    if (code === 1001502001) {
      return '系统里还没登录华为账号';
    }
    if (code === 1001500001) {
      return '应用签名指纹没登记到 AGC（项目设置 → 常规 → 应用 → SHA256 证书指纹）';
    }
    if (code === 1001502012) {
      return '你取消了授权';
    }
    if (code === 1001502005) {
      return '网络不通，稍后再试';
    }
    // 1001502003「输入参数值无效」= 华为那边认为这次请求的身份不合法。
    // 静默登录（LoginWithHuaweiIDRequest）不传 scope，所以与权限无关，
    // 实际只可能是这两件事之一：client_id 不是"该应用"的 OAuth 2.0 客户端 ID；
    // 或打包装机用的不是手动签名的调试证书（自动签名/正式证书都不认）。
    if (code === 1001502003) {
      return 'AGC 配置对不上（1001502003）：核对 module.json5 里的 client_id 是不是该应用的'
        + '「OAuth 2.0 客户端 ID」（别填 APP ID / 项目级 Client ID），并用调试证书手动签名';
    }
    // 兜底也把原始 message 带上：华为有时用同一个码表达不同细节，
    // 只报一个数字等于什么都没说
    const detail: string = (err.message !== undefined && err.message !== null) ? err.message : '';
    return detail.length > 0 ? `登录失败（${code}）：${detail}` : `登录失败（${code}）`;
  }
}
