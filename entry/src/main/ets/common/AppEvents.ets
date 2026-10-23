/**
 * 跨页面/跨组件的事件键（走 AppStorage）。
 *
 * 单独放一个文件是为了避免循环 import：
 * Index 里 import HomePage，HomePage 若反过来 import Index 取常量就会成环。
 */

/**
 * 「新建」触发信号。
 *
 * 新建圆钮挂在 Index 层（页签栏右侧），而新建弹框在 HomePage 层，
 * 两者跨组件，用 AppStorage 传一个**时间戳**过去：
 * 每次点击写入的值都不同，@Watch 一定触发。
 * （用自增计数不行：HomePage 被重建后自身计数归零，
 *  再点一次写进去的值可能恰好等于它当前持有的值，@Watch 就不响应了。）
 */
export const CREATE_REQUEST_KEY: string = 'createRequestTick';

/**
 * 「从桌面卡片进来了」信号。
 *
 * 卡片上的「记一笔」按钮用 postCardAction 把 App 拉起来（want 里带 fromCard=create），
 * 但 EntryAbility 发的这个信号不能直接等于 CREATE_REQUEST_KEY：
 * 卡片进来时 App 可能正停在「好友」或「我的」页，而弹框挂在主页上 ——
 * 得先让 Index 切回主页，主页才谈得上弹框。
 * 所以先给 Index 一个信号，由 Index 切完页签再转发 CREATE_REQUEST_KEY。
 */
export const CARD_ENTRY_KEY: string = 'cardEntryTick';

/** 详情弹层可见时，由主框架隐藏底栏和新建按钮并接管返回键。 */
export const DETAIL_VISIBLE_KEY: string = 'noteDetailVisible';

/**
 * 日历弹层可见时，理由同上。
 *
 * 系统自带的 CalendarPickerDialog 没法给某一天加标记，
 * 所以日历是主页自绘的 —— 它同样盖住整屏，底栏必须先让开，
 * 返回键也必须先收日历，否则一按就退出应用。
 */
export const CALENDAR_VISIBLE_KEY: string = 'noteCalendarVisible';
