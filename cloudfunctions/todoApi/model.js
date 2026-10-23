'use strict';

/**
 * 云数据库对象类型（Server Model）
 *
 * ⚠️ 字段名、类型必须和 AGC 控制台「云数据库」里创建的对象类型**逐字一致**，
 *    否则云函数读写时会报字段不匹配。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么这几个类必须带 getFieldTypeMap() 等 5 个方法？
 *
 * @hw-agconnect/cloud-server 在 collection(Model) 时会调 Utils.clazzCheck()，
 * 它 new 一个实例后要求下面 5 个方法**全部存在**，缺一个就抛 CLASS_INVALID：
 *
 *   getFieldTypeMap()      字段名 → 字段类型（值取 FieldType 枚举的字符串）
 *   getClassName()         对象类型名，必须与 AGC 控制台里建的表名一字不差
 *   getPrimaryKeyList()    主键字段名数组，至少一个
 *   getIndexList()         索引列表（SDK 目前不消费，留空即可）
 *   getEncryptedFieldList() 加密字段列表，没有就留空数组
 *
 * 这 5 个方法正是 AGC「Generate Server Model / 导出服务端对象类型」生成的东西。
 * 本文件是按同样的形状手写的，因此**第 1.4 步（导出 Server Model）可以跳过**。
 * 若日后你在控制台导出了官方文件，直接覆盖本文件即可，index.js 不用动。
 * ─────────────────────────────────────────────────────────────
 *
 * 需要在 AGC 控制台建这三张表（都在同一个存储区 LxxjZone 里）：
 *
 *   LxxjUser      主键 uid
 *     uid         String   华为账号 unionId，账号体系主键
 *     openId      String   应用级标识
 *     unionId     String   开发者级标识
 *     nickName    String   昵称
 *     avatarUri   String   头像地址
 *     token       String   会话 token（客户端拿它调云函数）
 *     tokenAt     Long     会话签发时间戳，用来判过期
 *     createdAt   Long     首次登录时间戳
 *
 *   LxxjTodo      主键 remoteId
 *     remoteId    String   消息 id，去重就靠它
 *     fromUid     String   发送者 uid
 *     fromName    String   发送者昵称（冗余一份，免得每次都要 join）
 *     toUid       String   接收者 uid
 *     text        String   那句话，几个字
 *     createdAt   Long     发送时间戳
 *     delivered   Boolean  接收端是否已拉走过（true 就不再推）
 *
 *   LxxjFriend    主键 id   —— 好友关系，本期先建好表，加好友界面后续接
 *     id          String   双向关系的固定键，见 utils.js 里的 relationKey()
 *     uid         String   主体
 *     friendUid   String   好友
 *     state       Integer  0=待接受 1=已接受 2=已拉黑
 *     createdAt   Long
 */

class LxxjUser {
  constructor() {
    this.uid = '';
    this.openId = '';
    this.unionId = '';
    this.nickName = '';
    this.avatarUri = '';
    this.token = '';
    this.tokenAt = 0;
    this.createdAt = 0;
  }

  getFieldTypeMap() {
    const fieldTypeMap = new Map();
    fieldTypeMap.set('uid', 'String');
    fieldTypeMap.set('openId', 'String');
    fieldTypeMap.set('unionId', 'String');
    fieldTypeMap.set('nickName', 'String');
    fieldTypeMap.set('avatarUri', 'String');
    fieldTypeMap.set('token', 'String');
    fieldTypeMap.set('tokenAt', 'Long');
    fieldTypeMap.set('createdAt', 'Long');
    return fieldTypeMap;
  }

  getClassName() {
    return 'LxxjUser';
  }

  getPrimaryKeyList() {
    const primaryKeyList = [];
    primaryKeyList.push('uid');
    return primaryKeyList;
  }

  getIndexList() {
    const indexList = [];
    return indexList;
  }

  getEncryptedFieldList() {
    const encryptedFieldList = [];
    return encryptedFieldList;
  }
}

class LxxjTodo {
  constructor() {
    this.remoteId = '';
    this.fromUid = '';
    this.fromName = '';
    this.toUid = '';
    this.text = '';
    this.createdAt = 0;
    this.delivered = false;
  }

  getFieldTypeMap() {
    const fieldTypeMap = new Map();
    fieldTypeMap.set('remoteId', 'String');
    fieldTypeMap.set('fromUid', 'String');
    fieldTypeMap.set('fromName', 'String');
    fieldTypeMap.set('toUid', 'String');
    fieldTypeMap.set('text', 'String');
    fieldTypeMap.set('createdAt', 'Long');
    fieldTypeMap.set('delivered', 'Boolean');
    return fieldTypeMap;
  }

  getClassName() {
    return 'LxxjTodo';
  }

  getPrimaryKeyList() {
    const primaryKeyList = [];
    primaryKeyList.push('remoteId');
    return primaryKeyList;
  }

  getIndexList() {
    const indexList = [];
    return indexList;
  }

  getEncryptedFieldList() {
    const encryptedFieldList = [];
    return encryptedFieldList;
  }
}

class LxxjFriend {
  constructor() {
    this.id = '';
    this.uid = '';
    this.friendUid = '';
    this.state = 0;
    this.createdAt = 0;
  }

  getFieldTypeMap() {
    const fieldTypeMap = new Map();
    fieldTypeMap.set('id', 'String');
    fieldTypeMap.set('uid', 'String');
    fieldTypeMap.set('friendUid', 'String');
    fieldTypeMap.set('state', 'Integer');
    fieldTypeMap.set('createdAt', 'Long');
    return fieldTypeMap;
  }

  getClassName() {
    return 'LxxjFriend';
  }

  getPrimaryKeyList() {
    const primaryKeyList = [];
    primaryKeyList.push('id');
    return primaryKeyList;
  }

  getIndexList() {
    const indexList = [];
    return indexList;
  }

  getEncryptedFieldList() {
    const encryptedFieldList = [];
    return encryptedFieldList;
  }
}

module.exports = { LxxjUser, LxxjTodo, LxxjFriend };
