'use strict';

/**
 * ═══════════════════════════════════════════════════════════════
 *  零星小记 · 好友待办云函数（AGC Cloud Functions）
 * ═══════════════════════════════════════════════════════════════
 *
 * 入口：index.myHandler
 * 依赖：@hw-agconnect/cloud-server
 * 环境变量（在 AGC 云函数配置里填，**不要写进代码**）：
 *   HW_CLIENT_ID        AGC 应用 Client ID
 *   HW_CLIENT_SECRET    AGC 应用 Client Secret
 *   CLOUD_DB_ZONE       云数据库存储区名，默认 LxxjZone
 *
 * 一个函数四个动作，用 event.action 分流：
 *   login  { code }                 → 授权码换 uid，签发会话 token
 *   send   { token, toUid, text }   → 写一条待办
 *   inbox  { token }                → 拉走发给我的、还没拉过的
 *   ack    { token, remoteIds }     → 标记已送达
 *
 * 关键点：**所有身份判断都在这里做**。客户端递上来的只有 code 或 token，
 * uid 永远由服务端查出来。客户端说自己是谁，不算数。
 */

/**
 * 第三方依赖的加载放在 try/catch 里。
 *
 * 为什么要包：部署时如果把不含 node_modules 的代码传了上去（比如只在线编辑了 index.js），
 * 这行 require 会在模块加载阶段就炸掉，控制台只会报一句天书：
 *   { "code": 180000, "message": "Call handler error: Cannot find module '@hw-agconnect/cloud-server' ..." }
 * 完全看不出是"依赖没传上去"。包住之后，缺依赖时函数依然能被调用，
 * 由 myHandler 开头的检查返回一句人话，直接告诉你怎么办。
 */
const fs = require('fs');
const path = require('path');

let cloud = null;
let cloudLoadError = '';
/** true = 依赖包压根不在（Cannot find module）；false = 包在，但初始化时自己报了错 */
let cloudDepMissing = false;
try {
  const agc = require('@hw-agconnect/cloud-server');
  cloud = agc.cloud || agc;
} catch (e) {
  cloudLoadError = (e && e.message) ? e.message : String(e);
  cloudDepMissing = /cannot find module/i.test(cloudLoadError);
}
const https = require('https');
const querystring = require('querystring');
const crypto = require('crypto');
const { LxxjUser, LxxjTodo, LxxjFriend } = require('./model');

/**
 * 云数据库句柄：懒初始化 + 失败原因记录。
 *
 * 有个 SDK 的坑要绕：`cloud` 这个默认实例是在 require 那一刻构造的，
 * 它的构造函数看到当时既没有 AGC_CONFIG 也没有 PROJECT_CREDENTIAL，就直接"躺平"
 * （不注册任何客户端）——之后哪怕把凭据补进环境变量，它也永远报
 * "Please create instance with path or set environment variable AGC_CONFIG"。
 * 所以这里不躺平的默认实例，而是在凭据就绪后用 createInstance() 现建一个：
 * 它会在构造时用此刻的环境变量解析凭据并注册。
 */
let db = null;
let dbError = '';
function getDb() {
  if (db !== null) {
    return db;
  }
  if (cloud === null) {
    return null;
  }
  try {
    const instance = cloud.createInstance(undefined, 'todoapi');
    db = instance.database({ zoneName: ZONE });
    return db;
  } catch (e) {
    dbError = (e && e.message) ? e.message : String(e);
    return null;
  }
}

/**
 * 环境变量的**默认值**。
 *
 * 真正的值在 myHandler 里按当次调用的 context 现读（见 readEnv）。
 * AGC 云函数的环境变量既可能落在 Node 进程环境里（process.env），
 * 也可能挂在运行时上下文上（context.env）—— 官方示例两种写法都出现过，
 * 不同运行时版本给的不一样。两处都读一次、谁有值用谁，
 * 免得部署完拿到 undefined，却错怪成"Secret 填错了"。
 */
let ZONE = 'LxxjZone';
let CLIENT_ID = '';
let CLIENT_SECRET = '';

/** 会话有效期：30 天不用就重登 */
const SESSION_TTL = 30 * 24 * 60 * 60 * 1000;
/** 一句话最长 16 个字，服务端也要卡，不能只信客户端 */
const MAX_TEXT_LEN = 16;
/** 昵称 / 头像入库前的安全上限。
 *  华为头像 URL 可能很长，超过对象类型里 String 字段的长度上限会报
 *  2060 "the size of a string data to be written exceeds the limit"，
 *  直接把登录炸掉。这里先截断兜底——头像链接截断了顶多图挂了，登录不能挂。
 *  字段长度本身在 AGC 对象类型里配（avatarUri 建议 2048，nickName 建议 128）。 */
const MAX_NICK_LEN = 128;
const MAX_AVATAR_LEN = 2000;
/** 云数据库 **String 类型的硬上限就是 200 个字符**（超过报 2060），控制台也改不了。
 *  华为头像 URL 常常比它长，所以入库前按这个长度截断。 */
const DB_STRING_MAX = 200;

function now() {
  return Date.now();
}

function coll(Model) {
  return getDb().collection(Model);
}

/** 云数据库 query().get() 在版本间返回过数组和 {data} 两种形状，这里统一 */
function rowsOf(res) {
  if (Array.isArray(res)) {
    return res;
  }
  if (res && Array.isArray(res.data)) {
    return res.data;
  }
  if (res && Array.isArray(res.records)) {
    return res.records;
  }
  return [];
}

/** event 可能是对象、JSON 字符串，或包在 body 里 */
function parseEvent(event) {
  if (event === null || event === undefined) {
    return {};
  }
  if (typeof event === 'string') {
    try {
      return JSON.parse(event);
    } catch (e) {
      return {};
    }
  }
  if (typeof event.body === 'string') {
    try {
      return JSON.parse(event.body);
    } catch (e) {
      return event;
    }
  }
  return event;
}

// ───────────────────────────── 环境变量 ─────────────────────────────

/**
 * 合并两处来源的环境变量：context.env 覆盖 process.env。
 *
 * 为什么不只用 process.env：Cloud Functions 的环境变量面板填完，
 * 有些运行时版本是注入子进程环境，有些是随 context 一起递进来。
 * 只用一种写法的话，另一种情况下会静默拿到 undefined。
 */
function readEnv(context) {
  const merged = {};
  const fromProcess = process.env || {};
  for (const k in fromProcess) {
    merged[k] = fromProcess[k];
  }
  const fromContext = (context && context.env) ? context.env : {};
  for (const k in fromContext) {
    const v = fromContext[k];
    if (v !== undefined && v !== null && v !== '') {
      merged[k] = v;
    }
  }
  return merged;
}

// ───────────────────────────── 华为账号 ─────────────────────────────

/** POST 一段表单，返回解析后的 JSON */
function postForm(url, body) {
  return new Promise(function (resolve, reject) {
    const data = querystring.stringify(body);
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(data)
      },
      timeout: 8000
    }, function (res) {
      let raw = '';
      res.on('data', function (chunk) {
        raw += chunk;
      });
      res.on('end', function () {
        try {
          resolve(JSON.parse(raw));
        } catch (e) {
          reject(new Error('华为账号返回了非 JSON：' + raw.slice(0, 200)));
        }
      });
    });
    req.on('timeout', function () {
      req.destroy(new Error('请求华为账号超时'));
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function base64UrlDecode(s) {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4 !== 0) {
    t += '=';
  }
  return Buffer.from(t, 'base64').toString('utf8');
}

/**
 * 解析 id_token 的 payload
 * id_token 是我们直接从华为 token 接口、经 TLS 拿到的，来源可信，
 * 因此读它的 payload 就够了，不需要再验签。
 */
function decodeIdToken(idToken) {
  const parts = String(idToken).split('.');
  if (parts.length !== 3) {
    return {};
  }
  try {
    return JSON.parse(base64UrlDecode(parts[1]));
  } catch (e) {
    return {};
  }
}

/**
 * 用一次性授权码换用户身份
 * 接口：https://oauth-login.cloud.huawei.com/oauth2/v3/token
 * 授权码有效期只有 5 分钟，且只能用一次 —— 客户端拿到后要立刻发过来
 */
async function exchangeCode(code) {
  const tokenRes = await postForm('https://oauth-login.cloud.huawei.com/oauth2/v3/token', {
    grant_type: 'authorization_code',
    code: code,
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET
  });
  if (!tokenRes || !tokenRes.id_token) {
    throw new Error('换 token 失败：' + JSON.stringify(tokenRes || {}).slice(0, 300));
  }
  const claims = decodeIdToken(tokenRes.id_token);
  const uid = claims.union_id || claims.sub;
  if (!uid) {
    throw new Error('id_token 里没有 union_id/sub');
  }
  return {
    uid: uid,
    openId: claims.open_id || '',
    unionId: claims.union_id || uid,
    nickName: claims.display_name || claims.nickname || ''
  };
}

// ───────────────────────────── 各动作 ─────────────────────────────

/** 登录：授权码 → 建/更新用户 → 签发会话 token */
async function actionLogin(payload) {
  if (!CLIENT_ID || !CLIENT_SECRET) {
    // 这句会原样冒到客户端 toast 上，所以要说清楚是"控制台那一栏没填"，
    // 而不是含糊的"服务端开小差"—— 这种情况十有八九是环境变量没配
    // 或配完没点保存（AGC 保存后要等 10 秒左右才生效）
    return {
      ok: false,
      message: '云函数缺少环境变量 HW_CLIENT_ID / HW_CLIENT_SECRET，请到 AGC 云函数配置页添加'
    };
  }
  const code = String(payload.code || '');
  if (!code) {
    return { ok: false, message: '缺少授权码' };
  }

  // 阶段①：拿授权码去华为换 token —— 失败多半是 HW_CLIENT_SECRET 不对 / 没配
  let who;
  try {
    who = await exchangeCode(code);
  } catch (e) {
    throw new Error('华为换 token 失败：' + ((e && e.message) ? e.message : String(e)));
  }

  // 阶段②：云数据库读写 —— 失败多半是 LxxjZone 存储区 / LxxjUser 对象类型没建，
  // 或 PROJECT_CREDENTIAL（Server SDK 凭据）没配 / 配错

  /**
   * 客户端顺带递上来的昵称 / 头像（走了 profile scope 才会有）。
   * 这两项**只作展示**，允许客户端伪造也无所谓 —— 身份 uid 是上面拿 code 换出来的，
   * 谁都改不了；昵称就算被人改成"宇宙第一"，也只影响他自己界面上显示的字。
   */
  const incomingNick = String(payload.nickName || '').slice(0, MAX_NICK_LEN);
  const incomingAvatar = String(payload.avatarUri || '').slice(0, MAX_AVATAR_LEN);

  const token = crypto.randomUUID().replace(/-/g, '');
  const users = coll(LxxjUser);
  let existing = [];
  try {
    existing = rowsOf(await users.query().equalTo('uid', who.uid).get());
  } catch (e) {
    throw new Error('读云数据库失败（查用户）：' + ((e && e.message) ? e.message : String(e)));
  }

  const user = new LxxjUser();
  user.uid = who.uid;
  user.openId = who.openId;
  user.unionId = who.unionId;
  // 优先级：客户端授权拿到的真昵称 → id_token 里的 → 库里已有的 → 兜底"用户xxxx"
  user.nickName = incomingNick || who.nickName
    || (existing[0] && existing[0].nickName) || ('用户' + who.uid.slice(-4));
  // 头像：能塞进 200 字就存库里（将来做好友列表要读），塞不进就留空 ——
  // 绝不为了一个头像让整个登录失败。手机上显示的头像是下面 reply 里那份完整 URL。
  user.avatarUri = (incomingAvatar.length <= DB_STRING_MAX)
    ? incomingAvatar
    : ((existing[0] && existing[0].avatarUri) || '');
  user.token = token;
  user.tokenAt = now();
  user.createdAt = (existing[0] && existing[0].createdAt) || now();
  try {
    await users.upsert(user);
  } catch (e) {
    throw new Error('写云数据库失败（建/更新用户）：' + ((e && e.message) ? e.message : String(e)));
  }

  return {
    ok: true,
    message: '',
    uid: user.uid,
    nickName: user.nickName,
    // 头像回**完整版**给客户端：手机上只是本地展示用，而且每次登录都会重新从华为取，
    // 不需要云端留存。云库那一份可能因为 200 字上限存不下，别拿它当返回来源。
    avatarUri: incomingAvatar || user.avatarUri,
    token: token
  };
}

/** 用会话 token 反查用户，查不到就是没登录 / 已过期 */
async function resolveUser(payload) {
  const token = String(payload.token || '');
  if (!token) {
    return null;
  }
  const found = rowsOf(await coll(LxxjUser).query().equalTo('token', token).get());
  if (found.length === 0) {
    return null;
  }
  const user = found[0];
  if (!user.tokenAt || now() - user.tokenAt > SESSION_TTL) {
    return null;
  }
  return user;
}

/** 读取凭据 JSON 的非敏感标识（type/project_id/region/client_id 前 8 位），
 *  用于诊断"云端按凭据找 schema 找不到"的问题——凭据若是团队级或指向别的项目，这里一目了然。 */
function credentialInfo() {
  try {
    const raw = String(process.env.PROJECT_CREDENTIAL || '');
    if (!raw) {
      return { error: 'process.env.PROJECT_CREDENTIAL 为空（env 变量没合并进 process.env）' };
    }
    const j = JSON.parse(raw);
    const cid = String(j.client_id || '');
    return {
      type: j.type || '(无 type 字段)',
      project_id: j.project_id || '(空)',
      region: j.region || '(空)',
      client_id_head: cid.slice(0, 8) + '…',
      configuration_version: j.configuration_version || '(空)'
    };
  } catch (e) {
    return { error: 'PROJECT_CREDENTIAL 不是合法 JSON：' + ((e && e.message) || String(e)) };
  }
}

/** 诊断：验证云数据库写路径（建临时用户 → 读回 → 尽力清理）。
 *  控制台测试事件 {"action":"dbping"} 触发。成功 = schema 对本实例可见；失败会把 2002007 等原样抛出。 */
async function actionDbPing() {
  const info = credentialInfo();
  try {
    const users = coll(LxxjUser);
    const probe = 'diag_' + Date.now();
    const user = new LxxjUser();
    user.uid = probe;
    user.openId = probe;
    user.unionId = probe;
    user.nickName = '诊断';
    user.avatarUri = '';
    user.token = probe;
    user.tokenAt = now();
    user.createdAt = now();
    await users.upsert(user);
    const back = rowsOf(await users.query().equalTo('uid', probe).get());
    try {
      await users.delete(user);
    } catch (e) {
      // 删除失败不影响诊断结论，只是留一条 diag_ 开头的垃圾行
    }
    return { ok: true, message: '', probe: probe, readBack: back.length, cred: info, zone: ZONE };
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    throw new Error('dbping 失败：' + msg + ' ｜凭据自检=' + JSON.stringify(info) + ' ｜zone=' + ZONE);
  }
}

/** 发一条待办 */
async function actionSend(payload, me) {
  const toUid = String(payload.toUid || '');
  const text = String(payload.text || '').trim();
  if (!toUid) {
    return { ok: false, remoteId: '', message: '不知道发给谁' };
  }
  if (!text) {
    return { ok: false, remoteId: '', message: '写一句吧' };
  }
  if (text.length > MAX_TEXT_LEN) {
    return { ok: false, remoteId: '', message: '太长啦，最多 ' + MAX_TEXT_LEN + ' 个字' };
  }
  if (toUid === me.uid) {
    return { ok: false, remoteId: '', message: '不能发给自己' };
  }

  // 对方得是真用户，避免往不存在的 uid 里灌数据
  const target = rowsOf(await coll(LxxjUser).query().equalTo('uid', toUid).get());
  if (target.length === 0) {
    return { ok: false, remoteId: '', message: '对方还没登录过，发不过去' };
  }

  const remoteId = crypto.randomUUID().replace(/-/g, '');
  const todo = new LxxjTodo();
  todo.remoteId = remoteId;
  todo.fromUid = me.uid;
  todo.fromName = me.nickName || '好友';
  todo.toUid = toUid;
  todo.text = text;
  todo.createdAt = now();
  todo.delivered = false;
  await coll(LxxjTodo).upsert(todo);

  return { ok: true, remoteId: remoteId, message: '已送达' };
}

/** 拉走发给我的、还没拉过的 */
async function actionInbox(payload, me) {
  const found = rowsOf(
    await coll(LxxjTodo).query().equalTo('toUid', me.uid).equalTo('delivered', false).get()
  );
  // 老消息排前面，收件箱里看着像聊天记录
  found.sort(function (a, b) {
    return (a.createdAt || 0) - (b.createdAt || 0);
  });

  const items = found.map(function (t) {
    return {
      remoteId: t.remoteId,
      fromUid: t.fromUid,
      fromName: t.fromName || '好友',
      text: t.text,
      createdAt: t.createdAt
    };
  });
  return { ok: true, message: '', items: items };
}

/** 标记已送达：客户端已经存到本地了，之后不再重复推 */
async function actionAck(payload, me) {
  const ids = Array.isArray(payload.remoteIds) ? payload.remoteIds : [];
  for (let i = 0; i < ids.length; i++) {
    const found = rowsOf(await coll(LxxjTodo).query().equalTo('remoteId', ids[i]).get());
    if (found.length === 0) {
      continue;
    }
    const t = found[0];
    // 只能 ack 发给自己的，防止乱改别人的消息
    if (t.toUid !== me.uid) {
      continue;
    }
    t.delivered = true;
    await coll(LxxjTodo).upsert(t);
  }
  return { ok: true, message: '' };
}

// ───────────────────────────── 好友 ─────────────────────────────

/**
 * 关系行的 id：两个 uid 拼起来。
 *
 * 好友是**双向**的：加一次要插两条（我→他、他→我），这样两个人各自的
 * 「好友列表」查询都只要按自己的 uid 扫一遍即可，不用在查询里做或运算。
 */
function relationId(a, b) {
  return a + '_' + b;
}

/** 好友里 uid 之外的展示信息（昵称/头像）要从用户表里补，关系行里不冗余存 */
async function profileOf(uid) {
  const rows = rowsOf(await coll(LxxjUser).query().equalTo('uid', uid).get());
  if (rows.length === 0) {
    return null;
  }
  return {
    uid: rows[0].uid,
    name: rows[0].nickName || ('用户' + String(rows[0].uid).slice(-4)),
    avatarUri: rows[0].avatarUri || ''
  };
}

/**
 * 我的好友列表。
 *
 * 两步：先按自己的 uid 取关系行，再逐个去用户表补昵称头像 ——
 * 云数据库没有 join，只能这样；好友量级（几十个）下这点开销无所谓。
 * 关系行指向的用户如果已经查不到（理论上不会），直接跳过，
 * 免得列表里出现一个 "undefined"。
 */
async function actionFriends(me) {
  const rels = rowsOf(await coll(LxxjFriend).query().equalTo('uid', me.uid).equalTo('state', 1).get());
  const friends = [];
  for (let i = 0; i < rels.length; i++) {
    const p = await profileOf(rels[i].friendUid);
    if (p !== null) {
      friends.push(p);
    }
  }
  return { ok: true, message: '', friends: friends };
}

/**
 * 添加好友：传对方的 uid（也就是他的"邀请码"）。
 *
 * 校验顺序按"用户最可能搞错什么"排：
 *   空 → 加了 → 对方没注册 → 已经是好友
 * 每一条都给一句人话，因为这些都是**用户**的错误，不是系统故障。
 */
async function actionAddFriend(payload, me) {
  const friendUid = String(payload.friendUid || '').trim();
  if (friendUid.length === 0) {
    return { ok: false, message: '先填对方的邀请码' };
  }
  if (friendUid === me.uid) {
    return { ok: false, message: '不能加自己' };
  }
  const target = await profileOf(friendUid);
  if (target === null) {
    return { ok: false, message: '查无此人：确认对方已用华为账号登录过零星小记' };
  }
  const dup = rowsOf(await coll(LxxjFriend).query()
    .equalTo('uid', me.uid).equalTo('friendUid', friendUid).get());
  if (dup.length > 0) {
    return { ok: false, message: '你们已经是好友了' };
  }

  const at = now();
  const mine = new LxxjFriend();
  mine.id = relationId(me.uid, friendUid);
  mine.uid = me.uid;
  mine.friendUid = friendUid;
  mine.state = 1;
  mine.createdAt = at;

  const theirs = new LxxjFriend();
  theirs.id = relationId(friendUid, me.uid);
  theirs.uid = friendUid;
  theirs.friendUid = me.uid;
  theirs.state = 1;
  theirs.createdAt = at;

  await coll(LxxjFriend).upsert(mine);
  await coll(LxxjFriend).upsert(theirs);
  return { ok: true, message: `已添加「${target.name}」`, friend: target };
}

/** 删好友：两边的关系行一起删，否则对方列表里还留着一个发不出消息的人 */
async function actionDelFriend(payload, me) {
  const friendUid = String(payload.friendUid || '').trim();
  if (friendUid.length === 0) {
    return { ok: false, message: '不知道要删谁' };
  }
  const mine = rowsOf(await coll(LxxjFriend).query()
    .equalTo('uid', me.uid).equalTo('friendUid', friendUid).get());
  const theirs = rowsOf(await coll(LxxjFriend).query()
    .equalTo('uid', friendUid).equalTo('friendUid', me.uid).get());
  if (mine.length > 0) {
    await coll(LxxjFriend).delete(mine[0]);
  }
  if (theirs.length > 0) {
    await coll(LxxjFriend).delete(theirs[0]);
  }
  return { ok: true, message: '已删除好友' };
}

// ───────────────────────────── 入口 ─────────────────────────────

let myHandler = async function (event, context, callback, logger) {
  const log = logger || console;

  // 每次调用都现读一次环境变量：云函数实例会被复用，
  // 在控制台改了变量的值之后，下一次调用就该生效，不需要等冷启动
  const env = readEnv(context);
  ZONE = env.CLOUD_DB_ZONE || ZONE;
  CLIENT_ID = env.HW_CLIENT_ID || CLIENT_ID;
  CLIENT_SECRET = env.HW_CLIENT_SECRET || CLIENT_SECRET;

  /**
   * 项目级凭据的转发：云数据库 SDK 只认 process.env.AGC_CONFIG（文件路径）和
   * process.env.PROJECT_CREDENTIAL（凭据 JSON 的**内容**），
   * 而控制台配的环境变量可能只挂在 context.env 上 —— 这里把两处合并进 process.env。
   * 必须在第一次 cloud.database() 之前做（凭据是在那一刻才读的）。
   *
   * 另配了 HW_CREDENTIAL_JSON 作为备选：部分控制台版本把 PROJECT_CREDENTIAL
   * 当系统保留字、不让用户建，那就用这个名字装凭据内容，这里转正。
   */
  const credContent = env.PROJECT_CREDENTIAL || env.HW_CREDENTIAL_JSON || '';
  if (credContent && !process.env.PROJECT_CREDENTIAL) {
    process.env.PROJECT_CREDENTIAL = String(credContent);
  }
  if (env.AGC_CONFIG && !process.env.AGC_CONFIG) {
    process.env.AGC_CONFIG = String(env.AGC_CONFIG);
  }

  // 依赖没装上 / SDK 加载失败时，与其抛 180000 天书，不如把修法直接递回给调用的人
  if (cloud === null) {
    log.error('todoapi cloud sdk load failed: ' + cloudLoadError);
    if (cloudDepMissing) {
      callback({
        ok: false,
        message: '云函数缺依赖 @hw-agconnect/cloud-server —— 上传的代码里没有 node_modules。'
          + '请上传单文件版部署包 todoApi-single.zip（依赖已内联，不依赖 node_modules）。'
      });
    } else {
      callback({
        ok: false,
        message: '云数据库 SDK 加载失败：' + cloudLoadError
          + '（常见于单文件部署包缺了 SDK 的内部配置文件 agconnect-common.json）'
      });
    }
    return;
  }

  // 云数据库初始化诊断：第一次 database() 时才读凭据，失败原因会记在 dbError 里
  if (getDb() === null) {
    log.error('todoapi database init failed: ' + dbError);
    callback({
      ok: false,
      message: '云数据库初始化失败：' + dbError
        + ' —— SDK 需要"项目级凭据"。请在 AGC 控制台「项目设置 → Server SDK」创建 API 客户端、'
        + '下载 agc-apiclient json，把它的 JSON 内容填到本函数的环境变量 PROJECT_CREDENTIAL，'
        + '保存后等 10 秒再测。'
    });
    return;
  }

  let result = { ok: false, message: '未知动作' };
  let action = '(unknown)';
  try {
    const payload = parseEvent(event);
    action = String(payload.action || '');
    log.info('todoapi action=' + action + ' zone=' + ZONE
      + ' hasId=' + (CLIENT_ID ? '1' : '0')
      + ' hasSecret=' + (CLIENT_SECRET ? '1' : '0'));

    if (action === 'login') {
      result = await actionLogin(payload);
    } else if (action === 'dbping') {
      result = await actionDbPing();
    } else {
      const me = await resolveUser(payload);
      if (me === null) {
        result = { ok: false, message: '登录态已失效，请重新登录' };
      } else if (action === 'send') {
        result = await actionSend(payload, me);
      } else if (action === 'inbox') {
        result = await actionInbox(payload, me);
      } else if (action === 'ack') {
        result = await actionAck(payload, me);
      } else if (action === 'friends') {
        result = await actionFriends(me);
      } else if (action === 'addfriend') {
        result = await actionAddFriend(payload, me);
      } else if (action === 'delfriend') {
        result = await actionDelFriend(payload, me);
      }
    }
  } catch (err) {
    const msg = (err && err.message) ? err.message : String(err);
    log.error('todoapi failed: action=' + action + ' :: ' + msg);
    if (err && err.stack) {
      log.error('todoapi stack: ' + String(err.stack).split('\n').slice(0, 4).join(' | '));
    }
    // 透传真实错误；若连 message 都没有（极少见），至少带上 action 和错误类型，
    // 免得真机只看到一句没用的"服务端开小差了"
    const typeName = (err && err.constructor && err.constructor.name) ? err.constructor.name : typeof err;
    const detail = (msg && msg.length > 0)
      ? msg
      : ('服务端开小差了（action=' + action + '，错误类型=' + typeName + '）');
    result = { ok: false, message: detail };
  }
  callback(result);
};

module.exports.myHandler = myHandler;
