import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IncomingTodo } from '../model/InboxModel';
import { FRIEND_LIST, FriendItem } from '../model/FriendModel';
import { AgcTodoTransport } from './agc/AgcTodoTransport';

const DOMAIN: number = 0x0001;
const TAG: string = 'TodoTransport';

/**
 * ═══════════════════════════════════════════════════════════════
 *  传输层：好友待办的「网线口」
 * ═══════════════════════════════════════════════════════════════
 *
 * 这是全项目唯一需要联网的地方。上层（TodoService / 页面）只认
 * 下面这个 TodoTransport 接口，不知道对面是本地假数据还是真服务器。
 *
 * 想让"好友给你发一条"真正跨设备生效，只需要：
 *   1. 起一个后端（或接 AGC 云数据库），实现三个接口：
 *        POST /todo/send    { toUid, text }        → { remoteId }
 *        GET  /todo/inbox                           → [ IncomingTodo ]
 *        POST /todo/ack     { remoteIds: [...] }    → ok
 *   2. 把 HTTP_BASE_URL 填上真实地址
 *   3. 把 createTransport() 的开关从 Mock 换成 Http
 *
 * 除此之外，UI、泡泡、存储、物理引擎一行都不用动。
 */
export interface SendResult {
  ok: boolean;
  /** 服务端返回的消息 id，本地留一份用来去重 / 回执 */
  remoteId: string;
  /** 失败时给人看的原因 */
  message: string;
}

export interface TodoTransport {
  /** 给某个好友发一条提醒 */
  sendTodo(toUid: string, text: string): Promise<SendResult>;
  /** 拉取"发给我、还没送达本机"的消息 */
  pullInbox(): Promise<IncomingTodo[]>;
  /** 告诉服务端这几条已经收到，可以出队（防止重复推送） */
  ackInbox(remoteIds: string[]): Promise<void>;
  /** 我的好友列表（真身永远在服务端） */
  fetchFriends(): Promise<FriendItem[]>;
  /** 添加好友，传对方 uid（邀请码） */
  addFriend(friendUid: string): Promise<FriendItem>;
  /** 删除好友 */
  delFriend(friendUid: string): Promise<void>;
}

// ═══════════════════════════════════════════════════════════════
//  一、MockTransport —— 本地模拟，今天就能跑
// ═══════════════════════════════════════════════════════════════

/** 模拟网络时延（ms）：太快反而不像"发出去"了 */
const MOCK_LATENCY: number = 420;

/**
 * 本地模拟的"服务器"
 *
 * pending 数组扮演服务端上"排队等着推给你"的消息；
 * 首次启动预置两条，让收件箱一进来就有东西看。
 * 因为 InboxStore 按 remoteId 去重，这两条重复投递也只会收一次。
 */
export class MockTransport implements TodoTransport {
  private static inst: MockTransport | undefined = undefined;
  private pending: IncomingTodo[] = [];
  private seq: number = 0;

  static instance(): MockTransport {
    if (MockTransport.inst === undefined) {
      MockTransport.inst = new MockTransport();
    }
    return MockTransport.inst;
  }

  constructor() {
    this.pending.push({
      remoteId: 'demo_lin_1',
      fromUid: 'u_lin',
      fromName: '林深',
      text: '帮我带杯咖啡',
      createdAt: Date.now() - 60000
    });
    this.pending.push({
      remoteId: 'demo_wan_1',
      fromUid: 'u_wan',
      fromName: '苏晚',
      text: '明早九点开会',
      createdAt: Date.now() - 30000
    });
  }

  sendTodo(toUid: string, text: string): Promise<SendResult> {
    return new Promise<SendResult>((resolve: (r: SendResult) => void) => {
      setTimeout((): void => {
        this.seq++;
        const result: SendResult = {
          ok: true,
          remoteId: `mock_out_${this.seq}_${Date.now()}`,
          message: '已送达'
        };
        hilog.info(DOMAIN, TAG, 'mock send to %{public}s: %{public}s', toUid, text);
        resolve(result);
      }, MOCK_LATENCY);
    });
  }

  pullInbox(): Promise<IncomingTodo[]> {
    const queued: IncomingTodo[] = this.pending.slice();
    return new Promise<IncomingTodo[]>((resolve: (r: IncomingTodo[]) => void) => {
      setTimeout((): void => {
        resolve(queued);
      }, MOCK_LATENCY / 2);
    });
  }

  ackInbox(remoteIds: string[]): Promise<void> {
    this.pending = this.pending.filter((it: IncomingTodo) => !remoteIds.includes(it.remoteId));
    return new Promise<void>((resolve: () => void) => {
      resolve();
    });
  }

  /** Mock 下的好友就是那几条假数据，加/删只在内存里动一动 */
  fetchFriends(): Promise<FriendItem[]> {
    return new Promise<FriendItem[]>((resolve: (r: FriendItem[]) => void) => {
      setTimeout((): void => {
        resolve(FRIEND_LIST.slice());
      }, MOCK_LATENCY / 2);
    });
  }

  addFriend(friendUid: string): Promise<FriendItem> {
    return new Promise<FriendItem>((resolve: (r: FriendItem) => void, reject: (e: Error) => void) => {
      setTimeout((): void => {
        for (let i: number = 0; i < FRIEND_LIST.length; i++) {
          if (FRIEND_LIST[i].uid === friendUid) {
            resolve(FRIEND_LIST[i]);
            return;
          }
        }
        reject(new Error('Mock 模式下只有内置那几个 uid'));
      }, MOCK_LATENCY);
    });
  }

  delFriend(friendUid: string): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, MOCK_LATENCY / 2);
    });
  }

  /** 演示用：假装某个好友此刻给你发了一条，推进服务端队列 */
  simulateIncoming(fromUid: string, fromName: string, text: string): IncomingTodo {
    const item: IncomingTodo = {
      remoteId: `mock_in_${Date.now()}`,
      fromUid: fromUid,
      fromName: fromName,
      text: text,
      createdAt: Date.now()
    };
    this.pending.push(item);
    return item;
  }
}

// ═══════════════════════════════════════════════════════════════
//  二、HttpTransport —— 真后端，等你有服务器了再开
// ═══════════════════════════════════════════════════════════════

/** 后端地址：自建填你的域名，用 AGC 云数据库则换成云函数调用 */
const HTTP_BASE_URL: string = 'https://api.example.com';// TODO 换成真实地址

/** 登录态令牌：登录接口拿到后存起来（Preferences / 内存都行） */
let authToken: string = '';

export class HttpTransport implements TodoTransport {
  /** 等待发送的正文 */
  private body(obj: string): string {
    return obj;
  }

  private header(): Record<string, string> {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${authToken}`
    };
    return h;
  }

  sendTodo(toUid: string, text: string): Promise<SendResult> {
    const payload: string = `{"toUid":"${toUid}","text":"${text}"}`;
    return new Promise<SendResult>((resolve: (r: SendResult) => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/todo/send`, {
        method: http.RequestMethod.POST,
        header: this.header(),
        extraData: this.body(payload),
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((res: http.HttpResponse) => {
        if (res.responseCode !== 200) {
          resolve({ ok: false, remoteId: '', message: `发送失败（${res.responseCode}）` });
          return;
        }
        const parsed: SendResult = JSON.parse(res.result as string) as SendResult;
        resolve(parsed);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'send failed: %{public}s', err.message);
        resolve({ ok: false, remoteId: '', message: '网络不通，稍后再试' });
      });
    });
  }

  pullInbox(): Promise<IncomingTodo[]> {
    return new Promise<IncomingTodo[]>((resolve: (r: IncomingTodo[]) => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/todo/inbox`, {
        method: http.RequestMethod.GET,
        header: this.header(),
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((res: http.HttpResponse) => {
        if (res.responseCode !== 200) {
          resolve([]);
          return;
        }
        resolve(JSON.parse(res.result as string) as IncomingTodo[]);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'pull failed: %{public}s', err.message);
        resolve([]);
      });
    });
  }

  ackInbox(remoteIds: string[]): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/todo/ack`, {
        method: http.RequestMethod.POST,
        header: this.header(),
        extraData: `{"remoteIds":${JSON.stringify(remoteIds)}}`,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then(() => {
        resolve();
      }).catch(() => {
        resolve();
      });
    });
  }

  fetchFriends(): Promise<FriendItem[]> {
    return new Promise<FriendItem[]>((resolve: (r: FriendItem[]) => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/friend/list`, {
        method: http.RequestMethod.GET,
        header: this.header(),
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((res: http.HttpResponse) => {
        if (res.responseCode !== 200) {
          resolve([]);
          return;
        }
        resolve(JSON.parse(res.result as string) as FriendItem[]);
      }).catch(() => {
        resolve([]);
      });
    });
  }

  addFriend(friendUid: string): Promise<FriendItem> {
    return new Promise<FriendItem>((resolve: (r: FriendItem) => void, reject: (e: Error) => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/friend/add`, {
        method: http.RequestMethod.POST,
        header: this.header(),
        extraData: `{"friendUid":${JSON.stringify(friendUid)}}`,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((res: http.HttpResponse) => {
        if (res.responseCode !== 200) {
          reject(new Error(`添加失败（${res.responseCode}）`));
          return;
        }
        resolve(JSON.parse(res.result as string) as FriendItem);
      }).catch((err: Error) => {
        reject(new Error('网络不通，稍后再试'));
      });
    });
  }

  delFriend(friendUid: string): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      http.createHttp().request(`${HTTP_BASE_URL}/friend/del`, {
        method: http.RequestMethod.POST,
        header: this.header(),
        extraData: `{"friendUid":${JSON.stringify(friendUid)}}`,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then(() => {
        resolve();
      }).catch(() => {
        resolve();
      });
    });
  }
}

// ═══════════════════════════════════════════════════════════════
//  三、开关：想上线就换成 AGC
// ═══════════════════════════════════════════════════════════════

/** 传输层实现 */
export enum TransportKind {
  /** 本地模拟：不用服务器就能跑通整条链路，开发和演示用 */
  MOCK = 0,
  /** AGC 云函数：真上线用这个 */
  AGC = 1,
  /** 自建后端：HttpTransport，随时可切 */
  HTTP = 2
}

/** 用哪个实现 —— 2026-10-14 云函数 todoapi 部署联调通过，切到 AGC */
export const TRANSPORT_KIND: TransportKind = TransportKind.AGC;

export function createTransport(): TodoTransport {
  if (TRANSPORT_KIND === TransportKind.AGC) {
    return new AgcTodoTransport();
  }
  if (TRANSPORT_KIND === TransportKind.HTTP) {
    return new HttpTransport();
  }
  return MockTransport.instance();
}
