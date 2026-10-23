import { cloudCommon } from '@kit.CloudFoundationKit';

/**
 * ═══════════════════════════════════════════════════════════════
 *  AGC（AppGallery Connect）接入配置
 * ═══════════════════════════════════════════════════════════════
 *
 * 需要在 AGC 控制台做的四件事（做完把下面的常量填上）：
 *
 *  1. 创建项目 + 应用，包名必须和 AppScope/app.json5 里的 bundleName 完全一致
 *  2. 开通「华为账号」：项目设置 → 常规 → 应用 → 拿到 Client ID，填到 AGC_CLIENT_ID，
 *     同时把 Client Secret 填到云函数的环境变量（绝不能放客户端）
 *  3. 开通「云函数」和「云数据库」，建一个存储区（名字填到 CLOUD_DB_ZONE）
 *  4. 把应用的签名证书 SHA256 指纹登记到 AGC（项目设置 → 常规 → 应用 → SHA256 证书指纹），
 *     否则华为账号登录会报 1001500001 Failed to check the fingerprint
 *
 * 另外 module.json5 的 metadata 里也要有 client_id（已加，值要换成同一个）。
 */

/**
 * AGC 分配的应用 Client ID（OAuth 2.0 客户端 ID）。
 *
 * 这个值会同时出现在两个地方，且必须完全一致：
 *   1. 这里 —— 供 isAgcConfigured() 判断"能不能点登录"
 *   2. module.json5 的 metadata.client_id —— Account Kit 真正读的是这里
 * 只在代码里改、忘了 module.json5，现象是能点登录但拿不到授权码。
 */
export const AGC_CLIENT_ID: string = '6917618950985710167';

/** 云数据库存储区名（与 AGC 控制台里创建的一致） */
export const CLOUD_DB_ZONE: string = 'LxxjZone';

/** 数据落在中国大陆 */
export const CLOUD_REGION: cloudCommon.CloudRegion = cloudCommon.CloudRegion.CHINA;

/**
 * 云函数名：一个函数用 action 分流，省得部署四个。
 *
 * ⚠️ 必须全小写。AGC 控制台对函数名有字符限制（只允许小写字母、数字、连字符），
 * 填 `todoApi` 会被拒绝，所以云端实际叫 `todoapi`。
 * 这个名字是**云端函数名**，与本地目录 `cloudfunctions/todoApi/` 无关，不用改目录。
 */
export const CLOUD_FUNCTION: string = 'todoapi';

/** 配置齐了没 */
export function isAgcConfigured(): boolean {
  return AGC_CLIENT_ID.length > 0;
}
