/**
 * 桌面卡片 · 今天的零星小记（2×2）
 *
 * ⚠️ 这是**卡片 UI**，跑在 launcher 拉起的卡片进程里，限制比普通页面多得多：
 *   · 不要 import 任何模块（基础组件和 postCardAction 都是全局的，够用了）
 *   · 不要自定义子组件、不要 @Builder 传参 —— 数据全部由 formBindingData 注入，
 *     卡片自己不做任何计算，只负责"把给到的字符串摆开"
 *   · 事件只有 postCardAction 一条路，点了就是让 App 起来
 *
 * 所以这里的写法看着有点笨（两行待办硬写两遍），但这是卡片上最不容易出岔子的一种。
 * 想加行数：保持 buildData 里的槽位与这里一一对应即可。
 */

let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct TodoCard {
  @LocalStorageProp('dateLabel') dateLabel: string = '';
  @LocalStorageProp('remain') remain: string = '0';
  @LocalStorageProp('doneText') doneText: string = '';
  @LocalStorageProp('emptyText') emptyText: string = '今天还没记下什么';
  /** '0' / '1' / '2'：有几行待办要摆 */
  @LocalStorageProp('slotCount') slotCount: string = '0';
  @LocalStorageProp('t0') t0: string = '';
  @LocalStorageProp('c0') c0: string = '#7E8CA0';
  @LocalStorageProp('n0') n0: string = '';
  @LocalStorageProp('t1') t1: string = '';
  @LocalStorageProp('c1') c1: string = '#7E8CA0';
  @LocalStorageProp('n1') n1: string = '';

  build() {
    Column() {
      // ── 顶部：名字 + 日期 ──
      Row() {
        Text('零星小记')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1F2329')
        Blank()
        Text(this.dateLabel)
          .fontSize(10)
          .fontColor('#8A90A0')
      }
      .width('100%')
      .height(16)

      // ── 还剩几件 ──
      Row() {
        Text(this.remain)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#5B6EF5')
        Text('件待办')
          .fontSize(11)
          .fontColor('#8A90A0')
          .margin({ left: 3, bottom: 4 })
        Blank()
        Text(this.doneText)
          .fontSize(10)
          .fontColor('#8A90A0')
          .margin({ bottom: 4 })
      }
      .width('100%')
      .height(32)
      .alignItems(VerticalAlign.Bottom)

      // ── 两条待办（空态就一句话）──
      Column() {
        if (this.slotCount !== '0') {
          Row() {
            Column()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.c0)
              .margin({ right: 7 })
            Text(this.t0)
              .fontSize(12)
              .fontColor('#1F2329')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.n0)
              .fontSize(10)
              .fontColor('#D9305E')
              .margin({ left: 6 })
          }
          .width('100%')
          .height(20)
        }

        if (this.slotCount === '2') {
          Row() {
            Column()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.c1)
              .margin({ right: 7 })
            Text(this.t1)
              .fontSize(12)
              .fontColor('#1F2329')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.n1)
              .fontSize(10)
              .fontColor('#D9305E')
              .margin({ left: 6 })
          }
          .width('100%')
          .height(20)
        }

        if (this.slotCount === '0') {
          Text(this.emptyText)
            .fontSize(11)
            .fontColor('#8A90A0')
            .maxLines(2)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)

      // ── 点一下进 App 直接开记 ──
      Button('＋ 记一笔')
        .width('100%')
        .height(26)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#5B6EF5')
        .borderRadius(13)
        .onClick(() => {
          postCardAction(this, {
            action: 'router',
            abilityName: 'EntryAbility',
            params: {
              fromCard: 'create'
            }
          });
        })
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#E4EAF9')
    .borderRadius(16)
  }
}
