/**
 * 桌面卡片 · 提供方（FormExtensionAbility）
 *
 * 它是一个独立进程里的"卡片后端"：launcher 把卡片画出来，喂给它的内容由这里给。
 * 所以卡片上永远看不到"过期的数字"以外的麻烦 —— 数据在这儿算，算完塞进 formBindingData。
 *
 * 刷新有三条腿，缺一条就会看到旧数据：
 *   ① 添卡那一刻      —— onAddForm 直接返回最新快照
 *   ② App 里改了数据  —— FormCardService.syncAll() 主动推（App 侧挂点）
 *   ③ 谁都没动但日子在走 —— setFormNextRefreshTime 让系统每 5 分钟叫我们一次
 *                          （跨零点、以及"App 被杀着没开"的情况，只能靠这条）
 */

import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { formBindingData, formInfo, formProvider, FormExtensionAbility } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CARD_REFRESH_MINUTES, FormCardService } from '../service/FormCardService';

const DOMAIN: number = 0x0000;
const TAG: string = 'TodoCardAbility';

export default class TodoCardAbility extends FormExtensionAbility {

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = TodoCardAbility.pickFormId(want);
    hilog.info(DOMAIN, TAG, 'onAddForm id=%{public}s', formId);
    if (formId.length > 0) {
      FormCardService.recordFormId(this.context, formId);
      TodoCardAbility.scheduleNextRefresh(formId);
    }
    // 卡片进程必须清一遍 Preferences 缓存：主进程刚写进去的数据，
    // 不清缓存这边读到的还是上一个时刻的快照
    return FormCardService.buildData(this.context, true);
  }

  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onUpdateForm id=%{public}s', formId);
    const data: formBindingData.FormBindingData = FormCardService.buildData(this.context, true);
    formProvider.updateForm(formId, data).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
    });
    // 每刷一次就再约下一次 —— 这是一条靠自己续期的链，
    // 断了（比如系统清理）就得等用户重新添卡或 App 打开时再补
    TodoCardAbility.scheduleNextRefresh(formId);
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm id=%{public}s', formId);
    FormCardService.forgetFormId(this.context, formId);
  }

  /** 卡片被临时转为普通卡片（缓存态）—— 不用做什么 */
  onCastToNormalForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onCastToNormalForm id=%{public}s', formId);
  }

  /** 卡片自己发上来的消息（当前卡片上没有这个入口，占个位） */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent id=%{public}s msg=%{public}s', formId, message);
  }

  /**
   * 约下一次自动刷新。
   * 系统给第三方卡片的下限就是 5 分钟，报更小的值会被拒绝并抛错，所以别去试 1 分钟。
   */
  private static scheduleNextRefresh(formId: string): void {
    formProvider.setFormNextRefreshTime(formId, CARD_REFRESH_MINUTES)
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setFormNextRefreshTime failed: %{public}s', JSON.stringify(err));
      });
  }

  /** formId 藏在 want.parameters 里，键名由 formInfo 给出 */
  private static pickFormId(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const value: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    if (value === undefined || value === null) {
      return '';
    }
    return value as string;
  }
}
