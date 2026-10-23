/**
 * 好友数据模型
 *
 * 真人好友关系只能由服务端维护 —— 谁是谁的好友、对方是否在线、
 * 消息有没有送达，这些本地永远算不出来（详见 service/TodoTransport.ets）。
 *
 * 但 uid 这一层现在就要立好：它就是服务端那一侧的主键。
 * 本地假数据按同样的规则写死 uid，将来把 FRIEND_LIST 换成
 * fetchFriends() 的返回值即可，页面一行都不用动。
 */

/** 好友 */
export interface FriendItem {
  /** 服务端唯一 id（本地假数据也照真格式写） */
  uid: string;
  id: number;
  name: string;
  signature: string;
  avatarColor: string;
  online: boolean;
}

/**
 * 好友列表假数据
 * TODO 接后端后：改为 TodoService.fetchFriends() 拉取
 */
export const FRIEND_LIST: FriendItem[] = [
  { uid: 'u_lin', id: 1, name: '林深', signature: '写代码和写诗一样浪漫', avatarColor: '#5B6EF5', online: true },
  { uid: 'u_wan', id: 2, name: '苏晚', signature: '产品狗的自我修养', avatarColor: '#FF9F43', online: true },
  { uid: 'u_chen', id: 3, name: '陈默', signature: '像素就是我的语言', avatarColor: '#A855F7', online: false },
  { uid: 'u_jiang', id: 4, name: '江离', signature: '后端搬砖中，勿扰', avatarColor: '#10B981', online: false },
  { uid: 'u_wen', id: 5, name: '温言', signature: '今天也是在找 Bug 的一天', avatarColor: '#F43F5E', online: true },
  { uid: 'u_gu', id: 6, name: '顾北', signature: '运营人的日常碎碎念', avatarColor: '#0EA5E9', online: false },
  { uid: 'u_bai', id: 7, name: '白鹭', signature: '自由职业，随时随地', avatarColor: '#8B5CF6', online: false },
  { uid: 'u_shen', id: 8, name: '沈聿', signature: '正在准备考研，加油', avatarColor: '#14B8A6', online: false }
];

/**
 * 我的邀请码（**已废弃，仅供未登录时兜底展示**）
 *
 * 真身是自己的 uid —— 服务端就是拿 uid 建的关系，所以"邀请码"不能另外编一串，
 * 编了对方输入了也对不上人。已登录时统一用 TodoService.myInviteCode()（= 真 uid）。
 */
export const MY_INVITE_CODE: string = 'LXXJ-8F3K';

/** 昵称兜底：uid 找不到人时也要能在泡泡上落个款 */
const FALLBACK_NAME: string = '好友';
/** 兜底强调色 */
const FALLBACK_ACCENT: string = '#5B6EF5';

/**
 * 头像色板：和界面上其他强调色同一批，取哪个由 uid 决定，不随机
 * （随机会导致同一个人每次刷新换个颜色，看起来像换了个号）
 */
const ACCENT_PALETTE: string[] = [
  '#5B6EF5', '#FF9F43', '#A855F7', '#10B981',
  '#F43F5E', '#0EA5E9', '#8B5CF6', '#14B8A6'
];

/**
 * 按 uid 取强调色。
 *
 * 服务端只给 uid 和昵称，颜色得本地补；但补的时候不能用随机数
 * —— 不然同一颗泡泡每次重绘换个边色。这里对 uid 做一次稳定的散列，
 * 同一个人、任何一台设备，算出来都是同一个色。
 */
export function accentForUid(uid: string): string {
  if (uid.length === 0) {
    return FALLBACK_ACCENT;
  }
  let sum: number = 0;
  for (let i: number = 0; i < uid.length; i++) {
    // charCodeAt 拿到的码值乘个 31 再累加：经典的字符串散列，够稳
    sum = (sum * 31 + uid.charCodeAt(i)) % 100000;
  }
  return ACCENT_PALETTE[sum % ACCENT_PALETTE.length];
}

// ═══════════════════════════════════════════════════════════════
//  当前好友列表
// ═══════════════════════════════════════════════════════════════

/**
 * 界面上认的那份好友列表。
 *
 * **初值刻意是空的，不预置上面那份假数据。**
 *
 * 这里曾经出过"脏数据一闪而过"：初值若是 FRIEND_LIST，真后端模式下已登录启动时
 * TodoService.init() 只顾着把 token 交给传输层、没有清这张表，好友页就先按内存里
 * 的假人渲染一遍（林深 / 苏晚 …），等 refreshFriends 拉回真列表才被顶掉 ——
 * 看上去就是几条好友闪一下又没了。假数据只留给 Mock 模式，由 TodoService.init()
 * 显式注入（见 service/TodoService.ts 的 init），真后端模式一律先空着。
 *
 * 之所以放在模块级而不是塞进某个类：泡泡渲染时（BubbleView）要按 uid 反查
 * 名字和颜色，那地方拿不到 Service 实例，只能查这张"当前表"。
 */
let currentFriends: FriendItem[] = [];

/** 整体替换当前好友列表（TodoService 拉到真数据后调） */
export function setFriendList(list: FriendItem[]): void {
  currentFriends = list.slice();
}

/** 当前生效的好友列表 */
export function friendList(): FriendItem[] {
  return currentFriends.slice();
}

/** 按 uid 找好友 */
export function friendByUid(uid: string): FriendItem | undefined {
  for (let i = 0; i < currentFriends.length; i++) {
    if (currentFriends[i].uid === uid) {
      return currentFriends[i];
    }
  }
  return undefined;
}

/** 按 uid 取昵称，找不到就给"好友" */
export function friendName(uid: string): string {
  const f: FriendItem | undefined = friendByUid(uid);
  return f === undefined ? FALLBACK_NAME : f.name;
}

/**
 * 按 uid 取强调色，用来给泡泡描一圈来源色边
 *
 * 列表里查不到（比如刚被删掉的好友发来的历史泡泡）也不要全掉成一个色：
 * 退回 accentForUid 至少能让"不同的人"看起来还是不同的。
 */
export function friendAccent(uid: string): string {
  const f: FriendItem | undefined = friendByUid(uid);
  return f === undefined ? accentForUid(uid) : f.avatarColor;
}
