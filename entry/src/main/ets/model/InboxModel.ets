import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'InboxStore';
const PREF_NAME: string = 'lingxing_inbox';
const KEY_LIST: string = 'inbox_list';

/**
 * 好友发来、还没被处理的一条待办
 *
 * 为什么不直接扔进主页？因为任何人都能给你发 —— 先进收件箱，
 * 你自己决定"收下"（变成今天的泡泡）还是"忽略"。多一步，主页就不会被塞满。
 */
export interface IncomingTodo {
  /** 服务端消息 id：去重的唯一依据 */
  remoteId: string;
  fromUid: string;
  fromName: string;
  text: string;
  createdAt: number;
}

/**
 * 收件箱本地存储（Preferences）
 *
 * 注意：这里存的是"已经送达本机、还没处理"的消息，
 * 不是"服务器上还没送达"的队列 —— 后者属于传输层的事（见 TodoTransport）。
 */
export class InboxStore {
  private static pref: preferences.Preferences | undefined = undefined;
  private static ready: boolean = false;
  private static items: IncomingTodo[] = [];

  static init(context: common.Context): void {
    if (InboxStore.ready) {
      return;
    }
    try {
      InboxStore.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      InboxStore.ready = true;
      InboxStore.items = InboxStore.readAll();
      hilog.info(DOMAIN, TAG, 'InboxStore ready, %{public}d items', InboxStore.items.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  private static readAll(): IncomingTodo[] {
    const pref: preferences.Preferences | undefined = InboxStore.pref;
    if (!InboxStore.ready || pref === undefined) {
      return [];
    }
    try {
      const raw: string = pref.getSync(KEY_LIST, '') as string;
      if (raw.length === 0) {
        return [];
      }
      return JSON.parse(raw) as IncomingTodo[];
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  private static writeAll(): void {
    const pref: preferences.Preferences | undefined = InboxStore.pref;
    if (!InboxStore.ready || pref === undefined) {
      return;
    }
    try {
      pref.putSync(KEY_LIST, JSON.stringify(InboxStore.items));
      pref.flushSync();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 当前收件箱（新的在前） */
  static list(): IncomingTodo[] {
    return InboxStore.items.slice();
  }

  /** 待处理条数 */
  static count(): number {
    return InboxStore.items.length;
  }

  /**
   * 批量入库，按 remoteId 去重（同一条消息重复拉取不会变成两条）
   * @returns 真正新增的条数
   */
  static addMany(incoming: IncomingTodo[]): number {
    let added: number = 0;
    for (let i = 0; i < incoming.length; i++) {
      const it: IncomingTodo = incoming[i];
      if (InboxStore.has(it.remoteId)) {
        continue;
      }
      InboxStore.items.unshift(it);
      added++;
    }
    if (added > 0) {
      InboxStore.writeAll();
    }
    return added;
  }

  private static has(remoteId: string): boolean {
    for (let i = 0; i < InboxStore.items.length; i++) {
      if (InboxStore.items[i].remoteId === remoteId) {
        return true;
      }
    }
    return false;
  }

  /** 移除一条（收下或忽略后都走这里） */
  static remove(remoteId: string): void {
    const kept: IncomingTodo[] = InboxStore.items.filter((item: IncomingTodo) => item.remoteId !== remoteId);
    if (kept.length === InboxStore.items.length) {
      return;
    }
    InboxStore.items = kept;
    InboxStore.writeAll();
  }

  /** 清空 */
  static clear(): void {
    InboxStore.items = [];
    InboxStore.writeAll();
  }
}
