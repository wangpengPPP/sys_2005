import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IncomingTodo } from '../../model/InboxModel';
import { accentForUid, FriendItem } from '../../model/FriendModel';
import { SendResult, TodoTransport } from '../TodoTransport';
import { CLOUD_FUNCTION } from './AgcConfig';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgcTransport';
/** 云函数调用超时（ms） */
const FN_TIMEOUT: number = 10000;

/** 云函数统一返回外壳 */
interface FnReply {
  ok: boolean;
  message: string;
}

/** action = login 的返回 */
export interface LoginReply extends FnReply {
  uid: string;
  nickName: string;
  avatarUri: string;
  token: string;
}

/** action = inbox 的返回 */
interface InboxReply extends FnReply {
  items: IncomingTodo[];
}

/** 云端返回的好友：只有身份和展示资料，其余由本地补 */
export interface FriendDto {
  uid: string;
  name: string;
  avatarUri: string;
}

/** action = friends 的返回 */
interface FriendsReply extends FnReply {
  friends: FriendDto[];
}

/** action = addfriend 的返回 */
interface AddFriendReply extends FnReply {
  friend: FriendDto;
}

/**
 * 云端只给身份和昵称头像，页面上要用的"颜色 / 顺序 / 签名"本地补。
 *
 * 颜色按 uid 取：同一个人换台手机看也是同一个色，不会每次刷新都变。
 * online 一律 false —— 服务端现在没有在线状态这个概念，
 * 与其编个假的"在线"，不如老实留着（界面上就是暗的那个小点）。
 */
function toFriendItem(dto: FriendDto, index: number): FriendItem {
  const tail: string = dto.uid.length > 4 ? dto.uid.slice(-4) : dto.uid;
  return {
    uid: dto.uid,
    id: index + 1,
    name: (dto.name !== undefined && dto.name.length > 0) ? dto.name : `好友${tail}`,
    signature: '',
    avatarColor: accentForUid(dto.uid),
    online: false
  };
}

// ---- 请求体：都声明成 interface，ArkTS 不接受匿名对象字面量 ----

interface LoginPayload {
  action: string;
  code: string;
  /** 华为账号授权的昵称（profile scope 才有，空串表示没拿到） */
  nickName: string;
  /** 华为账号头像地址 */
  avatarUri: string;
}

interface SendPayload {
  action: string;
  token: string;
  toUid: string;
  text: string;
}

interface TokenPayload {
  action: string;
  token: string;
}

interface AckPayload {
  action: string;
  token: string;
  remoteIds: string[];
}

/** 加好友 / 删好友：只多带一个对方 uid */
interface FriendPayload {
  action: string;
  token: string;
  friendUid: string;
}

/**
 * ═══════════════════════════════════════════════════════════════
 *  AGC 云函数传输层
 * ═══════════════════════════════════════════════════════════════
 *
 * 只调一个云函数（名字见 AgcConfig 的 CLOUD_FUNCTION，云端全小写 `todoapi`），
 * 用 action 分流：
 *   login  { code }                 → 用授权码换 uid，签发会话 token
 *   send   { token, toUid, text }   → 写一条待办
 *   inbox  { token }                → 拉取发给我的、还没收下的
 *   ack    { token, remoteIds }     → 标记已送达，防止重复推
 *
 * 为什么全部走云函数、不让客户端直连云数据库？
 * 因为「好友给你发待办」本质是**跨用户写** —— 让客户端直接写库，
 * 就得把库权限放开成"任意人可写任意行"，谁都能往你收件箱塞东西。
 * 云函数拿的是管理端权限，读写都在服务端校验，客户端只递一个会话 token。
 */
export class AgcTodoTransport implements TodoTransport {
  /** 会话 token，由 TodoService 在登录成功后注入，避免这里反向依赖账号模块 */
  private static token: string = '';

  static setToken(token: string): void {
    AgcTodoTransport.token = token;
  }

  /** 调一次云函数，返回结果文本（统一按 JSON 解） */
  private static async invoke(payload: string): Promise<string> {
    const params: cloudFunction.FunctionParams = {
      name: CLOUD_FUNCTION,
      data: payload,
      timeout: FN_TIMEOUT
    };
    const res: cloudFunction.FunctionResult = await cloudFunction.call(params);
    const raw: string | Object = res.result;
    return typeof raw === 'string' ? raw : JSON.stringify(raw);
  }

  /**
   * 登录：授权码 → 可信 uid + 会话 token
   *
   * 昵称头像一并带过去，但它们**只当展示资料**：uid 一律由服务端拿 code 换出来，
   * 客户端报什么身份都不算数。就算这里传空串，登录也照样成功（云端会给兜底名）。
   */
  static async login(code: string, nickName: string, avatarUri: string): Promise<LoginReply> {
    const body: LoginPayload = { action: 'login', code: code, nickName: nickName, avatarUri: avatarUri };
    const text: string = await AgcTodoTransport.invoke(JSON.stringify(body));
    return JSON.parse(text) as LoginReply;
  }

  sendTodo(toUid: string, text: string): Promise<SendResult> {
    const body: SendPayload = {
      action: 'send',
      token: AgcTodoTransport.token,
      toUid: toUid,
      text: text
    };
    return AgcTodoTransport.invoke(JSON.stringify(body))
      .then((raw: string): SendResult => JSON.parse(raw) as SendResult)
      .catch((err: BusinessError): SendResult => {
        hilog.error(DOMAIN, TAG, 'send failed: %{public}s', JSON.stringify(err));
        return { ok: false, remoteId: '', message: '发不出去，检查一下网络' };
      });
  }

  pullInbox(): Promise<IncomingTodo[]> {
    const body: TokenPayload = { action: 'inbox', token: AgcTodoTransport.token };
    return AgcTodoTransport.invoke(JSON.stringify(body))
      .then((raw: string): IncomingTodo[] => {
        const reply: InboxReply = JSON.parse(raw) as InboxReply;
        return reply.items === undefined ? [] : reply.items;
      })
      .catch((err: BusinessError): IncomingTodo[] => {
        hilog.error(DOMAIN, TAG, 'pull failed: %{public}s', JSON.stringify(err));
        return [];
      });
  }

  /**
   * 好友列表：服务端是真身，本地一份不留（换设备登录要能看到同一份）
   *
   * 注意是**实例方法**：TodoTransport 接口里声明的是实例成员，
   * 写成 static 的话类就不算实现了这个接口（ArkTS 会直接报编译错）。
   */
  async fetchFriends(): Promise<FriendItem[]> {
    const body: TokenPayload = { action: 'friends', token: AgcTodoTransport.token };
    const text: string = await AgcTodoTransport.invoke(JSON.stringify(body));
    const reply: FriendsReply = JSON.parse(text) as FriendsReply;
    if (!reply.ok) {
      throw new Error(reply.message.length > 0 ? reply.message : '好友列表拉取失败');
    }
    const list: FriendDto[] = reply.friends === undefined ? [] : reply.friends;
    return list.map((d: FriendDto, i: number): FriendItem => toFriendItem(d, i));
  }

  /** 加好友：传对方 uid（他的"邀请码"就是他的 uid） */
  async addFriend(friendUid: string): Promise<FriendItem> {
    const body: FriendPayload = {
      action: 'addfriend',
      token: AgcTodoTransport.token,
      friendUid: friendUid
    };
    const text: string = await AgcTodoTransport.invoke(JSON.stringify(body));
    const reply: AddFriendReply = JSON.parse(text) as AddFriendReply;
    if (!reply.ok) {
      throw new Error(reply.message.length > 0 ? reply.message : '添加失败');
    }
    return toFriendItem(reply.friend, 0);
  }

  /** 删好友：两边的关系行一起删 */
  async delFriend(friendUid: string): Promise<void> {
    const body: FriendPayload = {
      action: 'delfriend',
      token: AgcTodoTransport.token,
      friendUid: friendUid
    };
    const text: string = await AgcTodoTransport.invoke(JSON.stringify(body));
    const reply: FnReply = JSON.parse(text) as FnReply;
    if (!reply.ok) {
      throw new Error(reply.message.length > 0 ? reply.message : '删除失败');
    }
  }

  ackInbox(remoteIds: string[]): Promise<void> {
    const body: AckPayload = {
      action: 'ack',
      token: AgcTodoTransport.token,
      remoteIds: remoteIds
    };
    return AgcTodoTransport.invoke(JSON.stringify(body))
      .then((): void => {
      })
      .catch((): void => {
      });
  }
}
