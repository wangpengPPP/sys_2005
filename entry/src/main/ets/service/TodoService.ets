import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Bubble, BubbleRecord, createBubble } from '../model/BubbleModel';
import { BubbleStore } from '../model/BubbleStore';
import { IncomingTodo, InboxStore } from '../model/InboxModel';
import { FRIEND_LIST, FriendItem, friendList, MY_INVITE_CODE, setFriendList } from '../model/FriendModel';
import { toDateKey } from '../common/DateUtil';
import { createTransport, MockTransport, SendResult, TodoTransport, TRANSPORT_KIND, TransportKind } from './TodoTransport';
import { AgcTodoTransport, LoginReply } from './agc/AgcTodoTransport';
import { HwAccount, HwAuthCode, HuaweiAccount } from './agc/HuaweiAccount';
import { isAgcConfigured } from './agc/AgcConfig';

const DOMAIN: number = 0x0001;
const TAG: string = 'TodoService';

/** 主页监听这个版本号：好友的小记被"收下"后就地补进当天的泡泡里 */
export const INBOX_VERSION_KEY: string = 'todoInboxVersion';

/**
 * 登录态版本号。
 *
 * 「我的」页和「好友」页各有一份账号界面镜像，两边都能发起登录/退出。
 * 以前它们各自在 aboutToAppear 里读一次 —— 在一个页面登录完切到另一个页面，
 * 看到的还是旧状态（页签切回来未必重新走 aboutToAppear）。
 * 现在登录态一变就写这个键，两边 @Watch 一起刷新。
 */
export const ACCOUNT_VERSION_KEY: string = 'todoAccountVersion';

/**
 * 好友列表版本号。
 *
 * 好友是服务端的东西，但「好友页」不是唯一关心它的地方：泡泡上要按 uid 反查
 * 昵称和颜色（BubbleView），发一条时也要知道发给谁。
 * 拉到新列表就写这个键，好友页 @Watch 一下重新取；泡泡那边查的是
 * FriendModel 里的"当前表"，不用版本号也能跟上。
 */
export const FRIEND_VERSION_KEY: string = 'todoFriendVersion';

/**
 * 待提示的账号消息（读一次就清空）。
 *
 * 会话过期不是用户点出来的，但界面必须解释一句 —— 否则用户打开 App
 * 看到自己是"未登录"，只会以为自己从没登过。
 * 之所以要经过 AppStorage 中转：这种状态变化往往发生在应用回到前台的那一刻
 * （EntryAbility.onForeground 里查的），那时页面早就渲染完了，没有地方能弹提示。
 */
export const ACCOUNT_NOTICE_KEY: string = 'todoAccountNotice';

/** 演示用的那几句话，模拟好友随手甩过来一条 */
const DEMO_TEXTS: string[] = ['记得买牛奶', '帮我带份早饭', '晚上七点老地方', '快递帮我签一下', '别忘了充电宝'];

/**
 * 好友待办 · 业务层
 *
 * 页面只跟它打交道，它负责三件事：
 *   ① 拉取：从传输层取"新到的消息"，合并进本地收件箱（按 remoteId 去重）
 *   ② 收下：把一条好友待办变成"今天的泡泡"，从收件箱移除
 *   ③ 发送：把一句话交给传输层送给某个好友
 *
 * 它是 UI 和网络之间唯一的接缝 —— 换后端只动 TodoTransport，这里不用改。
 */
export class TodoService {
  private static transport: TodoTransport | undefined = undefined;

  /** 初始化本地收件箱 + 恢复华为账号登录态（EntryAbility 里调用） */
  static init(context: common.Context): void {
    InboxStore.init(context);
    HuaweiAccount.init(context);
    // 上次登录过：把会话 token 交给传输层，下次调云函数直接带上
    // （token() 已经会挡掉过期的会话，这里不必再判一次）
    if (HuaweiAccount.isSignedIn()) {
      AgcTodoTransport.setToken(HuaweiAccount.token());
    }
    /*
     * 好友表的初值在这里统一兜底：真后端模式一律先空着，等 refreshFriends
     * 把真列表拉回来；只有 Mock 模式才把那份假好友摆出来。
     *
     * 原来这段写在 else 分支里（"没登录才清空"），等于漏掉了已登录这条最常见
     * 的路 —— 于是好友页会先拿内存里的假数据显示一遍，拉到真列表才被顶掉，
     * 表现就是"几条好友一闪而过"。现在不管登没登录都走这一句。
     */
    setFriendList(TodoService.isMock() ? FRIEND_LIST.slice() : []);
  }

  // ---------------- 账号 ----------------

  /**
   * 检查本地会话是否还活着（EntryAbility.onForeground 调）。
   *
   * 应用在后台放久了，回来时那份 token 可能已经过了自己的有效期 ——
   * 这里就地作废并把 token 从传输层撤掉，免得继续拿一个死 token 去调云函数。
   * @returns 这次调用是否真的让登录态失效了
   */
  static checkSession(): boolean {
    if (!HuaweiAccount.expireIfStale()) {
      return false;
    }
    AgcTodoTransport.setToken('');
    setFriendList(TodoService.isMock() ? FRIEND_LIST.slice() : []);
    TodoService.bumpFriends();
    // 给界面留一句话：登录是"自己没的"，得交代一下
    AppStorage.setOrCreate<string>(ACCOUNT_NOTICE_KEY, '登录已过期，重新登录一次就好');
    TodoService.bumpAccount();
    return true;
  }

  /** 取走待提示的账号消息（读一次就清空，保证只提示一次） */
  static consumeAccountNotice(): string {
    const msg: string | undefined = AppStorage.get<string>(ACCOUNT_NOTICE_KEY);
    if (msg === undefined || msg.length === 0) {
      return '';
    }
    AppStorage.setOrCreate<string>(ACCOUNT_NOTICE_KEY, '');
    return msg;
  }

  /** 本地有没有登录态 */
  static isSignedIn(): boolean {
    return HuaweiAccount.isSignedIn();
  }

  /** 当前账号 */
  static account(): HwAccount | undefined {
    return HuaweiAccount.current();
  }

  /** 当前 uid（没登录是空串） */
  static uid(): string {
    return HuaweiAccount.uid();
  }

  /** AGC 配好了没 —— 没配的话登录入口得先讲清楚，而不是点下去必然失败 */
  static canSignIn(): boolean {
    return HuaweiAccount.isConfigured();
  }

  /**
   * 登录：华为账号拿授权码 → 交云函数换 uid 和会话 token
   *
   * 之所以要过一趟云函数：授权码是一次性的、由华为签发，
   * 服务端用它换出的 uid 才是可信的。客户端自己报 uid 谁都能假冒。
   */
  static async signIn(context: common.UIAbilityContext): Promise<HwAccount> {
    if (!isAgcConfigured()) {
      throw new Error('还没填 AGC 的 Client ID（见 service/agc/AgcConfig.ets）');
    }
    let auth: HwAuthCode;
    try {
      auth = await HuaweiAccount.fetchAuthCode(context);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'account kit failed: %{public}s', JSON.stringify(err));
      throw new Error(HuaweiAccount.explain(err));
    }

    const reply: LoginReply = await AgcTodoTransport.login(auth.code, auth.nickName, auth.avatarUri);
    if (!reply.ok) {
      throw new Error(reply.message.length > 0 ? reply.message : '登录失败');
    }
    // uid 以服务端换出来的为准；服务端没给就退回客户端 SDK 报的 unionId（仅兜底）
    const unionId: string = reply.uid.length > 0 ? reply.uid : auth.unionId;
    HuaweiAccount.patchProfile(reply.nickName, reply.avatarUri, reply.token, unionId, auth.openId);
    AgcTodoTransport.setToken(reply.token);
    // 登录态变了立刻广播：另一个页面的账号卡片要跟着变
    TodoService.bumpAccount();

    const acc: HwAccount | undefined = HuaweiAccount.current();
    if (acc === undefined) {
      throw new Error('登录信息没保存成功');
    }
    hilog.info(DOMAIN, TAG, 'signed in as %{public}s', acc.unionId);
    // 登录完顺手拉一次收件箱：刚登录的人最想看"有没有人给我发过东西"，
    // 等他自己去点刷新就晚了。失败也不影响登录本身（refresh 内部已经把异常吃掉）
    TodoService.refresh().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'post-signin refresh failed: %{public}s', err.message);
    });
    // 好友列表同理：登录完第一眼就该看到自己真实的好友，而不是那份内置假数据
    TodoService.refreshFriends().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'post-signin friends failed: %{public}s', err.message);
    });
    return acc;
  }

  /** 退出登录 */
  static signOut(): void {
    HuaweiAccount.signOut();
    AgcTodoTransport.setToken('');
    // 好友是跟着账号走的：换号/退号后上一份列表不能留在屏幕上。
    // Mock 模式没有账号这回事，退回内置假数据接着演示
    setFriendList(TodoService.isMock() ? FRIEND_LIST.slice() : []);
    TodoService.bumpFriends();
    TodoService.bumpAccount();
  }

  /** 我的邀请码 = 我的 uid：对方在"添加好友"里输这串就能找到我 */
  static myInviteCode(): string {
    const me: string = TodoService.uid();
    return me.length > 0 ? me : MY_INVITE_CODE;
  }

  /** 当前这套传输实现，是不是必须先登录（本地模拟不用） */
  static needsSignIn(): boolean {
    return TRANSPORT_KIND === TransportKind.AGC;
  }

  /** 是不是还在本地模拟模式（演示入口只在这种情况下出现） */
  static isMock(): boolean {
    return TRANSPORT_KIND === TransportKind.MOCK;
  }

  private static net(): TodoTransport {
    if (TodoService.transport === undefined) {
      TodoService.transport = createTransport();
    }
    return TodoService.transport;
  }

  // ---------------- 读 ----------------

  /** 当前收件箱（新的在前） */
  static inbox(): IncomingTodo[] {
    return InboxStore.list();
  }

  /** 待处理条数：好友页角标用 */
  static pendingCount(): number {
    return InboxStore.count();
  }

  // ---------------- 拉 ----------------

  /**
   * 拉一次收件箱
   * @returns 这次新到了几条（0 表示没有新消息）
   */
  static refresh(): Promise<number> {
    return TodoService.net().pullInbox().then((incoming: IncomingTodo[]): number => {
      const added: number = InboxStore.addMany(incoming);
      if (incoming.length > 0) {
        // 已经落到本地了，告诉服务端可以出队，免得下次重复推
        const ids: string[] = incoming.map((it: IncomingTodo) => it.remoteId);
        TodoService.net().ackInbox(ids).catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'ack failed: %{public}s', err.message);
        });
      }
      return added;
    }).catch((err: Error): number => {
      hilog.error(DOMAIN, TAG, 'refresh failed: %{public}s', err.message);
      return 0;
    });
  }

  // ---------------- 收下 / 忽略 ----------------

  /**
   * 收下一条：变成「今天」未完成区的一颗泡泡，泡上带发送者的名字
   * 收下的位置交给主页随机散布，这里只管数据
   */
  static accept(todo: IncomingTodo): void {
    const dateKey: string = toDateKey(new Date());
    const existing: Bubble[] = BubbleStore.loadDate(dateKey);

    // 同一条消息只收一次（防止重复点击）
    for (let i = 0; i < existing.length; i++) {
      if (existing[i].remoteId.length > 0 && existing[i].remoteId === todo.remoteId) {
        InboxStore.remove(todo.remoteId);
        return;
      }
    }

    const record: BubbleRecord = {
      id: BubbleStore.nextId(),
      text: todo.text,
      done: false,
      createdAt: Date.now(),
      dateKey: dateKey,
      fromUid: todo.fromUid,
      fromName: todo.fromName,
      remoteId: todo.remoteId,
      // 好友发来的小记按「普通」处理：重要程度是发件人自己那台设备上的概念，
      // 传过来目前没有语义，先统一普通，免得凭空多出一颗看不懂的色点
      level: 0,
      repeat: 0,
      weekdays: 0,
      ruleId: '',
      // 同理：截止是收件人这边的事，好友发来的不带
      dueAt: 0
    };
    existing.push(createBubble(record));
    BubbleStore.saveDate(dateKey, existing);
    InboxStore.remove(todo.remoteId);
    TodoService.bumpVersion();
    hilog.info(DOMAIN, TAG, 'accepted todo from %{public}s', todo.fromName);
  }

  /** 忽略一条：只是从收件箱丢掉，不会变成泡泡 */
  static ignore(remoteId: string): void {
    InboxStore.remove(remoteId);
  }

  // ---------------- 发 ----------------

  /** 给某个好友发一条提醒 */
  static send(toUid: string, text: string): Promise<SendResult> {
    return TodoService.net().sendTodo(toUid, text);
  }

  // ---------------- 好友 ----------------

  /** 当前好友列表（本地缓存；真身在服务端，由 refreshFriends 刷新） */
  static friends(): FriendItem[] {
    return friendList();
  }

  /**
   * 拉一次好友列表，成功就整体顶掉本地那份并广播。
   *
   * 失败时**故意保留旧列表**并返回 reject：好友页要能提示"没拉到"，
   * 但也不该因为一次网络抖动就把屏幕上的人全清空。
   */
  static refreshFriends(): Promise<FriendItem[]> {
    return TodoService.net().fetchFriends().then((list: FriendItem[]): FriendItem[] => {
      setFriendList(list);
      TodoService.bumpFriends();
      hilog.info(DOMAIN, TAG, 'friends synced: %{public}d', list.length);
      return list;
    }).catch((err: Error): never => {
      hilog.error(DOMAIN, TAG, 'refresh friends failed: %{public}s', err.message);
      throw err;
    });
  }

  /**
   * 加好友：传对方的 uid（他的"邀请码"就是他的 uid）。
   * 成功后整表重拉一次 —— 服务端那边还负责了对方的资料，
   * 只把返回的这一条塞进本地，顺序和 id 会和真列表对不上。
   */
  static addFriend(friendUid: string): Promise<FriendItem> {
    return TodoService.net().addFriend(friendUid).then((added: FriendItem): FriendItem => {
      TodoService.refreshFriends().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 're-sync after add failed: %{public}s', err.message);
      });
      return added;
    });
  }

  /** 删好友：服务端两边一起删，本地先摘掉，失败再拉回来 */
  static removeFriend(friendUid: string): Promise<void> {
    return TodoService.net().delFriend(friendUid).then((): void => {
      const kept: FriendItem[] = friendList().filter((it: FriendItem) => it.uid !== friendUid);
      setFriendList(kept);
      TodoService.bumpFriends();
    });
  }

  // ---------------- 演示 ----------------

  /**
   * 演示用：假装某个好友此刻给你发来一条
   * 换到真后端后删掉即可（真消息会由 refresh 自己拉进来）
   */
  static simulateIncoming(): Promise<number> {
    const list: FriendItem[] = friendList();
    if (list.length === 0) {
      return Promise.resolve(0);
    }
    const idx: number = Math.floor(Math.random() * list.length);
    const f: FriendItem = list[idx];
    const text: string = DEMO_TEXTS[Math.floor(Math.random() * DEMO_TEXTS.length)];
    const t: TodoTransport = TodoService.net();
    if (t instanceof MockTransport) {
      t.simulateIncoming(f.uid, f.name, text);
    }
    return TodoService.refresh();
  }

  /** 通知主页：收件箱有东西被收下了，当天的泡泡要补上 */
  private static bumpVersion(): void {
    const current: number | undefined = AppStorage.get<number>(INBOX_VERSION_KEY);
    AppStorage.setOrCreate<number>(INBOX_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }

  /** 通知所有页面：登录态变了，账号界面重新读一遍 */
  private static bumpAccount(): void {
    const current: number | undefined = AppStorage.get<number>(ACCOUNT_VERSION_KEY);
    AppStorage.setOrCreate<number>(ACCOUNT_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }

  /** 通知所有页面：好友列表变了（拉取 / 加 / 删） */
  private static bumpFriends(): void {
    const current: number | undefined = AppStorage.get<number>(FRIEND_VERSION_KEY);
    AppStorage.setOrCreate<number>(FRIEND_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }
}
