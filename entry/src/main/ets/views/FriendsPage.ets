import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { FriendItem } from '../model/FriendModel';
import { IncomingTodo } from '../model/InboxModel';
import { MAX_TEXT_LENGTH } from '../model/BubbleModel';
import { ACCOUNT_VERSION_KEY, FRIEND_VERSION_KEY, TodoService } from '../service/TodoService';
import { SendResult } from '../service/TodoTransport';
import { HuaweiAccount } from '../service/agc/HuaweiAccount';
import { AppPalette, AppTheme, THEME_VERSION_KEY, THEME_DARK_KEY } from '../common/AppTheme';

/** 弹层模式 */
const MODE_INBOX: number = 0;
const MODE_SEND: number = 1;
/** 添加好友 */
const MODE_ADD: number = 2;

/**
 * 好友页
 *
 * 好友功能的落点只有一件事：**让好友给你发一条待办**。
 * 所以这一页只有两块是真的：
 *   ① 收件箱 —— 好友发来的小记先落在这里，你点「收下」才变成主页上的泡泡
 *   ② 好友列表 —— 点进去给 ta 发一条
 * 其余（群聊、朋友圈那类）先不铺，免得抢了主线。
 */
@Component
export struct FriendsPage {
  /** 主题版本号：切换主题时 +1，这一页跟着重画（见 common/AppTheme.ets） */
  @StorageProp(THEME_VERSION_KEY) themeVersion: number = 0;
  @StorageProp(THEME_DARK_KEY) themeDark: boolean = AppTheme.isDark();

  /** 当前这套配色 */
  private p(): AppPalette {
    return AppTheme.palette(this.themeDark);
  }

  @StorageProp('topSafeAreaPx') topSafeAreaPx: number = 0;
  @StorageProp('bottomSafeAreaPx') bottomSafeAreaPx: number = 0;
  @State friends: FriendItem[] = TodoService.friends();
  @State keyword: string = '';
  /**
   * 真列表拉到手了没。
   *
   * 拉之前不能写"还没有好友"——那是在冤枉用户（可能只是网络还没回来），
   * 而且列表一填上就会跳变，看着又是一次"一闪而过"。
   */
  @State friendsLoaded: boolean = false;

  // ---- 账号 ----
  @State signedIn: boolean = false;
  @State nickName: string = '';
  @State avatarUri: string = '';
  @State avatarInitial: string = '我';
  @State signingIn: boolean = false;
  /** 会话还剩几天，摆在"华为账号"那行后面，快到期时用户能提前看到 */
  @State sessionText: string = '';
  /** 登录态版本号：在「我的」页登录/退出后，这一页要跟着变（见 TodoService） */
  @StorageProp(ACCOUNT_VERSION_KEY) @Watch('onAccountChanged') accountVersion: number = 0;

  // ---- 好友列表 ----
  /** 好友列表版本号：拉取 / 加 / 删之后 TodoService 会写这个键 */
  @StorageProp(FRIEND_VERSION_KEY) @Watch('onFriendsChanged') friendVersion: number = 0;

  // ---- 收件箱 ----
  @State inbox: IncomingTodo[] = [];
  @State refreshing: boolean = false;

  // ---- 弹层 ----
  @State sheetShown: boolean = false;
  @State sheetMode: number = MODE_INBOX;
  @State targetName: string = '';
  @State draft: string = '';
  @State sending: boolean = false;

  // ---- 加好友 ----
  @State addDraft: string = '';
  @State adding: boolean = false;

  /** 当前要发给谁（uid，不参与渲染所以不用 @State） */
  private targetUid: string = '';

  aboutToAppear(): void {
    this.syncAccount();
    this.friends = TodoService.friends();
    if (!TodoService.needsSignIn() || this.signedIn) {
      this.pullInbox(false);
      this.pullFriends();
    }
    this.showPendingAccountNotice();
  }

  /** 会话过期这类"不是用户点出来"的状态变化，得跟用户交代一句 */
  private showPendingAccountNotice(): void {
    const notice: string = TodoService.consumeAccountNotice();
    if (notice.length > 0) {
      this.toast(notice);
    }
  }

  private syncAccount(): void {
    this.signedIn = TodoService.isSignedIn();
    this.nickName = HuaweiAccount.displayName();
    this.avatarUri = HuaweiAccount.avatarUri();
    this.avatarInitial = HuaweiAccount.avatarInitial();
    this.sessionText = this.signedIn ? `华为账号 · 会话剩 ${HuaweiAccount.sessionDaysLeft()} 天` : '';
  }

  /**
   * 登录态在别处变了（在「我的」页登录/退出，或应用回到前台时发现会话到期）。
   * 这里跟着刷新，并且：
   *   · 刚变成已登录 → 拉一次收件箱（登录后第一件想做的事就是"有没有人给我发过东西"）
   *   · 刚变成未登录 → 清掉界面上的收件箱（那是给上一个账号的，不该留在屏幕上）
   */
  private onAccountChanged(): void {
    const wasSignedIn: boolean = this.signedIn;
    this.syncAccount();
    if (!wasSignedIn && this.signedIn) {
      this.pullInbox(false);
      this.pullFriends();
    } else if (wasSignedIn && !this.signedIn) {
      this.inbox = [];
      this.showPendingAccountNotice();
    }
  }

  /** 好友列表在别处变了（登录后首拉 / 加好友 / 删好友），跟着重读一遍 */
  private onFriendsChanged(): void {
    this.friends = TodoService.friends();
  }

  /**
   * 拉一次好友列表；失败时本地缓存还留着，不打扰用户。
   *
   * 成不成都要把 friendsLoaded 置上：失败时摆"正在载入…"比摆一句永远不变的
   * 加载中文案更糟，索性让它落地成"还没有好友"，至少是句确定的话。
   */
  private pullFriends(): void {
    TodoService.refreshFriends().then(() => {
      this.friends = TodoService.friends();
      this.friendsLoaded = true;
    }).catch(() => {
      this.friendsLoaded = true;
    });
  }

  /** 登录华为账号：静默拿授权码 → 云函数换 uid 和会话 */
  private signIn(): void {
    if (this.signingIn) {
      return;
    }
    this.signingIn = true;
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    TodoService.signIn(ctx).then(() => {
      this.signingIn = false;
      this.syncAccount();
      this.toast(`已登录 · ${HuaweiAccount.displayName()}`);
      this.pullInbox(false);
    }).catch((e: Error) => {
      this.signingIn = false;
      // 失败原因给足展示时间：里面的信息经常是"下一步去哪做什么"
      this.getUIContext().getPromptAction().showToast({ message: e.message, duration: 2600 });
    });
  }

  private signOut(): void {
    TodoService.signOut();
    this.syncAccount();
    this.inbox = [];
    this.toast('已退出登录');
  }

  /** 退出前确认一下（与「我的」页保持同一套话术） */
  private confirmSignOut(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后会清掉本机保存的会话，好友发来的小记也就收不到了。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: this.p().danger,
        action: () => {
          this.signOut();
        }
      }
    });
  }

  /** 需要登录而没登录时挡一下，返回 true 表示已拦住 */
  private blockedByLogin(): boolean {
    if (TodoService.needsSignIn() && !this.signedIn) {
      this.toast('先登录华为账号，好友才收得到');
      return true;
    }
    return false;
  }

  private getFilteredList(): FriendItem[] {
    const key: string = this.keyword;
    return this.friends.filter((item: FriendItem) => {
      return key.length === 0 || item.name.includes(key) || item.signature.includes(key);
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }

  /**
   * 我的邀请码 = 自己的 uid（服务端就是拿它建关系的）。
   * 用弹窗而不是一句 toast：这串码得让人看清、能复制，一闪而过没法用。
   */
  private showInviteCode(): void {
    if (this.blockedByLogin()) {
      return;
    }
    const code: string = TodoService.myInviteCode();
    this.getUIContext().showAlertDialog({
      title: '我的邀请码',
      message: `把这串发给好友，ta 在「添加好友」里输入即可加你：\n\n${code}`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '复制',
        action: () => {
          const data: pasteboard.PasteData = pasteboard.createData('text/plain', code);
          pasteboard.getSystemPasteboard().setData(data).catch(() => {
          });
          this.toast('已复制，发给好友吧');
        }
      },
      secondaryButton: {
        value: '关闭',
        fontColor: this.p().textMeta,
        action: () => {
        }
      }
    });
  }

  /** 打开加好友弹层：输入对方的邀请码（就是对方的 uid） */
  private openAddFriend(): void {
    if (this.blockedByLogin()) {
      return;
    }
    this.sheetMode = MODE_ADD;
    this.addDraft = '';
    this.sheetShown = true;
  }

  private addFriend(): void {
    const uid: string = this.addDraft.trim();
    if (uid.length === 0) {
      this.toast('把对方的邀请码粘进来');
      return;
    }
    if (this.adding) {
      return;
    }
    this.adding = true;
    TodoService.addFriend(uid).then((f: FriendItem) => {
      this.adding = false;
      this.sheetShown = false;
      this.addDraft = '';
      this.toast(`已添加 · ${f.name}`);
    }).catch((e: Error) => {
      this.adding = false;
      // 云端的拒绝理由（查无此人 / 已经是好友 / 不能加自己）直通给用户
      this.toast(e.message.length > 0 ? e.message : '添加失败');
    });
  }

  /** 长按卡片删好友：先问一句，删错了没地方撤销 */
  private confirmRemoveFriend(item: FriendItem): void {
    this.getUIContext().showAlertDialog({
      title: `删除好友「${item.name}」？`,
      message: '删掉之后你们就互发不了小记了。已经收下的泡泡不受影响，会继续留在主页上。',
      primaryButton: {
        value: '再想想',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: this.p().danger,
        action: () => {
          TodoService.removeFriend(item.uid).then(() => {
            this.toast('已删除');
          }).catch((e: Error) => {
            this.toast(e.message.length > 0 ? e.message : '删除失败，稍后再试');
          });
        }
      }
    });
  }

  /** 拉一次收件箱；notice=true 时把"新到几条"讲出来 */
  private pullInbox(notice: boolean): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    TodoService.refresh().then((added: number) => {
      this.refreshing = false;
      this.inbox = TodoService.inbox();
      if (notice) {
        this.toast(added > 0 ? `收到 ${added} 条` : '暂时没有新的');
      }
    }).catch(() => {
      this.refreshing = false;
      this.inbox = TodoService.inbox();
    });
  }

  // ---------------- 交互 ----------------

  private openInbox(): void {
    if (this.blockedByLogin()) {
      return;
    }
    this.sheetMode = MODE_INBOX;
    this.inbox = TodoService.inbox();
    this.sheetShown = true;
    // 顺手拉一次，免得要用户自己点刷新
    this.pullInbox(false);
  }

  private openSend(item: FriendItem): void {
    if (this.blockedByLogin()) {
      return;
    }
    this.sheetMode = MODE_SEND;
    this.targetUid = item.uid;
    this.targetName = item.name;
    this.draft = '';
    this.sheetShown = true;
  }

  /** 收下：变成今天主页上的一颗泡泡 */
  private accept(todo: IncomingTodo): void {
    TodoService.accept(todo);
    this.inbox = TodoService.inbox();
    this.toast(`已收下 · 今天的主页多了一颗泡泡`);
  }

  private ignore(todo: IncomingTodo): void {
    TodoService.ignore(todo.remoteId);
    this.inbox = TodoService.inbox();
    this.toast('已忽略');
  }

  private send(): void {
    const text: string = this.draft.trim();
    if (text.length === 0) {
      this.toast('写一句吧');
      return;
    }
    if (this.sending) {
      return;
    }
    this.sending = true;
    TodoService.send(this.targetUid, text).then((res: SendResult) => {
      this.sending = false;
      if (res.ok) {
        this.sheetShown = false;
        this.draft = '';
        this.toast(`已送给 ${this.targetName}`);
      } else {
        this.toast(res.message);
      }
    }).catch(() => {
      this.sending = false;
      this.toast('发不出去，稍后再试');
    });
  }

  /** 演示：让某个好友"此刻发来一条"，看整条链路通不通 */
  private simulate(): void {
    TodoService.simulateIncoming().then(() => {
      this.inbox = TodoService.inbox();
      this.toast('模拟：有好友给你发了一条');
    }).catch(() => {
    });
  }

  // ---------------- UI ----------------

  @Builder
  pageHeader() {
    Column() {
      Row() {
        Text('好友')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().textPrimary)
        Blank()
        Text(`${this.friends.length} 位`)
          .fontSize(12)
          .fontColor(this.p().accentText)
          .backgroundColor(this.p().cardBg)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
      }
      .width('100%')

      Search({ value: this.keyword, placeholder: '搜索好友' })
        .width('100%')
        .height(42)
        .backgroundColor(this.p().cardBgThin)
        .borderRadius(14)
        .placeholderColor(this.p().textTertiary)
        .fontColor(this.p().textPrimary)
        .placeholderFont({ size: 14 })
        .textFont({ size: 14 })
        .margin({ top: 14 })
        .onChange((value: string) => {
          this.keyword = value;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
  }

  /** 账号条：没登录就请人登录，登录了就显示是谁 */
  @Builder
  accountCard() {
    Row() {
      if (this.signedIn) {
        Stack() {
          if (this.avatarUri.length > 0) {
            Image(this.avatarUri)
              .width(44)
              .height(44)
              .borderRadius(22)
              .objectFit(ImageFit.Cover)
              .alt($r('app.media.startIcon'))
          } else {
            Text(this.avatarInitial)
              .fontSize(17)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.p().accent)
        .clip(true)

        Column() {
          Text(this.nickName.length > 0 ? this.nickName : '已登录')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary)
          Text(this.sessionText)
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Text('退出')
          .fontSize(12)
          .fontColor(this.p().textMeta)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.p().cardBgThin)
          .borderRadius(13)
          .onClick(() => {
            this.confirmSignOut();
          })
      } else {
        Column() {
          Text('还没登录')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary)
            .width('100%')
          Text(TodoService.canSignIn()
            ? '登录后才能让好友给你发小记（不读通讯录，也不会公开手机号）'
            : '尚未接入华为账号登录：AGC 还没填 Client ID')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .maxLines(2)
            .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.signingIn ? '登录中…' : (TodoService.canSignIn() ? '华为账号登录' : '未接入'))
          .height(36)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(TodoService.canSignIn() ? this.p().accent : this.p().textMuted)
          .borderRadius(18)
          .padding({ left: 16, right: 16 })
          .enabled(!this.signingIn)
          .margin({ left: 12 })
          .onClick(() => {
            if (!TodoService.canSignIn()) {
              this.getUIContext().getPromptAction().showToast({
                message: '还没填 AGC 的 Client ID，登录暂不可用（见 service/agc/AgcConfig.ets）',
                duration: 3000
              });
              return;
            }
            this.signIn();
          })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.signedIn ? this.p().cardBgThin : this.p().accentSoft)
    .borderRadius(20)
  }

  /** 收件箱：好友发来的小记先落这儿 */
  @Builder
  inboxCard() {
    Row() {
      SymbolGlyph($r('sys.symbol.envelope'))
        .fontColor([this.p().accentText])
        .fontSize(24)
        .width(44)
        .height(44)
        .borderRadius(14)
        .backgroundColor(this.p().accentSoft)

      Column() {
        Row() {
          Text('收到的小记')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary)
          if (this.inbox.length > 0) {
            Text(`${this.inbox.length}`)
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor(this.p().danger)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(8)
              .margin({ left: 6 })
          }
        }

        Text(this.inbox.length > 0 ? '好友发来的提醒，收下才会出现在主页' : '还没有人给你发小记')
          .fontSize(12)
          .fontColor(this.p().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      Text('查看')
        .fontSize(13)
        .fontColor(this.p().accentText)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(this.p().chip)
        .borderRadius(14)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.p().cardBg)
    .border({ width: 1, color: this.p().glassBorder })
    .borderRadius(20)
    .onClick(() => {
      this.openInbox();
    })
  }

  @Builder
  quickItem(icon: Resource, title: string) {
    Row({ space: 10 }) {
      SymbolGlyph(icon).fontSize(23).fontColor([this.p().accentText])
      Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.p().textPrimary)
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([this.p().textTertiary])
    }
    .height(64).layoutWeight(1).padding({ left: 14, right: 12 })
    .backgroundColor(this.p().cardBg).borderRadius(20)
    .border({ width: 1, color: this.p().glassBorder })
    .onClick(() => {
      if (title === '我的邀请码') { this.showInviteCode(); }
      else { this.openAddFriend(); }
    })
  }

  @Builder
  quickEntries() {
    Row({ space: 10 }) {
      this.quickItem($r('sys.symbol.person_badge_plus'), '添加好友')
      this.quickItem($r('sys.symbol.qrcode'), '我的邀请码')
    }.width('100%')
  }

  @Builder
  friendCard(item: FriendItem) {
    Row() {
      Stack() {
        Text(item.name.substring(0, 1))
          .fontSize(17)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .backgroundColor(item.avatarColor)

      Column() {
        Row() {
          Text(item.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary)
          if (item.online) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.p().success)
              .margin({ left: 6 })
          }
        }

        // 服务端给的好友没有签名这一项，与其留一段空白，不如把"长按可删"写在这儿
        Text(item.signature.length > 0 ? item.signature : '长按这张卡片可以删除好友')
          .fontSize(12)
          .fontColor(this.p().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      Text('发一条')
        .fontSize(12)
        .fontColor(this.p().accentText)
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .backgroundColor(this.p().glassAreaStrong)
        .borderRadius(13)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.p().cardBg)
    .borderRadius(20)
    .onClick(() => {
      this.openSend(item);
    })
    // 长按：删除好友。用 onActionEnd（手指抬起才触发），
    // 免得还按着呢弹窗就跳出来把这次长按变成"误触"
    .gesture(LongPressGesture({ repeat: false })
      .onActionEnd(() => {
        this.confirmRemoveFriend(item);
      }))
  }

  // ---- 收件箱弹层 ----
  @Builder
  inboxItem(todo: IncomingTodo) {
    Column() {
      Row() {
        Text(todo.fromName.substring(0, 1))
          .fontSize(13)
          .fontColor(Color.White)
          .width(26)
          .height(26)
          .borderRadius(13)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.p().accent)

        Text(todo.fromName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().textPrimary)
          .margin({ left: 8 })

        Text('给你发了一条')
          .fontSize(11)
          .fontColor(this.p().textTertiary)
          .margin({ left: 6 })
      }
      .width('100%')

      Text(todo.text)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().textPrimary)
        .width('100%')
        .margin({ top: 10 })

      Row({ space: 10 }) {
        Blank()
        Text('忽略')
          .fontSize(13)
          .fontColor(this.p().textMeta)
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .backgroundColor(this.p().cardBgThin)
          .borderRadius(16)
          .onClick(() => {
            this.ignore(todo);
          })
        Text('收下')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .padding({ left: 18, right: 18, top: 7, bottom: 7 })
          .backgroundColor(this.p().accent)
          .borderRadius(16)
          .onClick(() => {
            this.accept(todo);
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.p().cardBgThin)
    .border({ width: 1, color: this.p().glassBorder })
    .borderRadius(18)
  }

  @Builder
  inboxSheet() {
    Column() {
      Text('收到的小记')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
        .width('100%')

      Text('好友的惦记，收下就会变成今天的一颗泡泡')
        .fontSize(12)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      if (this.inbox.length === 0) {
        Column() {
          Text('这里空着')
            .fontSize(14)
            .fontColor(this.p().textTertiary)
          Text('好友给你发小记时会出现在这儿')
            .fontSize(12)
            .fontColor(this.p().textQuaternary)
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.inbox, (item: IncomingTodo) => {
            ListItem() {
              this.inboxItem(item)
            }
          }, (item: IncomingTodo) => item.remoteId)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      // 演示入口：只在本地模拟模式下出现，切到 AGC 后自动消失
      if (TodoService.isMock()) {
        Text('模拟好友发来一条（本地演示，接入 AGC 后自动隐藏）')
          .fontSize(12)
          .fontColor(this.p().accentText)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 6 })
          .onClick(() => {
            this.simulate();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 16 })
  }

  // ---- 发一条弹层 ----
  @Builder
  sendSheet() {
    Column() {
      Text(`给 ${this.targetName} 发一条`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
        .width('100%')

      Text('几个字就够 —— ta 看到这两个字就想起来了')
        .fontSize(12)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .margin({ top: 4 })

      TextInput({ text: $$this.draft, placeholder: '比如：记得买牛奶' })
        .width('100%')
        .height(56)
        .fontSize(18)
        .fontColor(this.p().textPrimary)
        .backgroundColor(this.p().cardBgThin)
        .borderRadius(16)
        .placeholderColor(this.p().textTertiary)
        .placeholderFont({ size: 16 })
        .maxLength(MAX_TEXT_LENGTH)
        .margin({ top: 18 })
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
          this.send();
        })

      Row() {
        Text(`${this.draft.length}/${MAX_TEXT_LENGTH}`)
          .fontSize(12)
          .fontColor(this.p().textTertiary)
        Blank()
        Button(this.sending ? '发送中…' : '发送')
          .height(40)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.p().accent)
          .borderRadius(20)
          .padding({ left: 26, right: 26 })
          .enabled(!this.sending)
          .onClick(() => {
            this.send();
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }

  // ---- 加好友弹层 ----
  @Builder
  addSheet() {
    Column() {
      Text('添加好友')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().textPrimary)
        .width('100%')

      Text('让对方打开「好友 → 我的邀请码」，把那串码发给你')
        .fontSize(12)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .margin({ top: 4 })

      TextInput({ text: $$this.addDraft, placeholder: '粘贴对方的邀请码' })
        .width('100%')
        .height(56)
        .fontSize(16)
        .fontColor(this.p().textPrimary)
        .backgroundColor(this.p().cardBgThin)
        .borderRadius(16)
        .placeholderColor(this.p().textTertiary)
        .placeholderFont({ size: 14 })
        .margin({ top: 18 })
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
          this.addFriend();
        })

      Row() {
        Text('加完就能互相发小记')
          .fontSize(12)
          .fontColor(this.p().textTertiary)
        Blank()
        Button(this.adding ? '添加中…' : '添加')
          .height(40)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.p().accent)
          .borderRadius(20)
          .padding({ left: 26, right: 26 })
          .enabled(!this.adding)
          .onClick(() => {
            this.addFriend();
          })
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }

  private sheetHeight(): number {
    return this.sheetMode === MODE_INBOX ? 460 : (this.sheetMode === MODE_SEND ? 300 : 280);
  }

  build() {
    Column() {
      this.pageHeader()

      List({ space: 10 }) {
        if (!this.signedIn) {
          ListItem() { this.accountCard() }
        }

        ListItem() {
          this.inboxCard()
        }

        ListItem() {
          this.quickEntries()
        }

        ListItem() {
          Text('我的好友').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.p().textPrimary).padding({ top: 10, bottom: 2 })
        }
        ForEach(this.getFilteredList(), (item: FriendItem) => {
          ListItem() {
            this.friendCard(item)
          }
        }, (item: FriendItem) => item.uid)

        if (this.getFilteredList().length === 0) {
          ListItem() {
            Column() {
              Text(this.keyword.length > 0
                ? '没搜到'
                : (this.friendsLoaded ? '还没有好友' : '正在载入好友…'))
                .fontSize(14)
                .fontColor(this.p().textTertiary)
              if (this.keyword.length === 0 && this.friendsLoaded) {
                Text('点「添加好友」，把好友的邀请码粘进来')
                  .fontSize(12)
                  .fontColor(this.p().textQuaternary)
                  .margin({ top: 6 })
              }
            }
            .width('100%')
            .padding({ top: 28, bottom: 28 })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }

        // 底部留白：列表本身一直铺到屏幕底（滚动时内容从悬浮页签栏底下穿过，
        // 玻璃才有东西可模糊、光感才看得出来），但不能真被栏永久挡住，
        // 所以用一段占位把最后一张卡顶到栏上方
        ListItem() {
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.bottomSafeAreaPx) + 108)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) })
    .bindSheet($$this.sheetShown, this.sheetContent(), {
      height: this.sheetHeight(),
      dragBar: true,
      showClose: true,
      backgroundColor: this.p().cardBg,
      maskColor: this.p().scrimSheet,
      onDisappear: () => {
        this.sheetShown = false;
      }
    })
  }

  @Builder
  sheetContent() {
    if (this.sheetMode === MODE_INBOX) {
      this.inboxSheet()
    } else if (this.sheetMode === MODE_SEND) {
      this.sendSheet()
    } else {
      this.addSheet()
    }
  }
}
