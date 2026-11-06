import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Dedupe } from './Dedupe';
import { Log } from '../common/Logger';

const DB_NAME: string = 'fanfic_translate.db';
const DB_VERSION: number = 4;

/**
 * 建表语句。字段与《需求开发文档》6.2 一一对应：
 * work / chapter / paragraph / term / progress / job 六张表。
 * paragraph 的 runs 是 JSON 字符串，结构为 Run[]，不是纯文本。
 */
const SCHEMA: string[] = [
  `CREATE TABLE IF NOT EXISTS work (
     id TEXT PRIMARY KEY,
     title TEXT NOT NULL,
     author TEXT NOT NULL DEFAULT '',
     source_type TEXT NOT NULL DEFAULT 'file',
     source_url TEXT NOT NULL DEFAULT '',
     language TEXT NOT NULL DEFAULT 'en',
     tags TEXT NOT NULL DEFAULT '',
     cover_path TEXT NOT NULL DEFAULT '',
     word_count INTEGER NOT NULL DEFAULT 0,
     chapter_count INTEGER NOT NULL DEFAULT 0,
     dedupe_key TEXT NOT NULL DEFAULT '',
     fingerprint TEXT NOT NULL DEFAULT '',
     shelf_id TEXT NOT NULL DEFAULT '',
     sort_no INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS chapter (
     id TEXT PRIMARY KEY,
     work_id TEXT NOT NULL,
     index_no INTEGER NOT NULL,
     title TEXT NOT NULL DEFAULT '',
     status TEXT NOT NULL DEFAULT 'pending',
     summary TEXT NOT NULL DEFAULT '',
     translated_at INTEGER NOT NULL DEFAULT 0,
     source_url TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_chapter_order ON chapter (work_id, index_no)`,
  `CREATE TABLE IF NOT EXISTS paragraph (
     id TEXT PRIMARY KEY,
     chapter_id TEXT NOT NULL,
     index_no INTEGER NOT NULL,
     type TEXT NOT NULL DEFAULT 'text',
     runs TEXT NOT NULL,
     translated_runs TEXT NOT NULL DEFAULT '',
     status TEXT NOT NULL DEFAULT 'pending',
     updated_at INTEGER NOT NULL DEFAULT 0
   )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_paragraph_order ON paragraph (chapter_id, index_no)`,
  `CREATE TABLE IF NOT EXISTS term (
     id TEXT PRIMARY KEY,
     work_id TEXT NOT NULL,
     source TEXT NOT NULL,
     target TEXT NOT NULL,
     note TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_term_unique ON term (work_id, source)`,
  `CREATE TABLE IF NOT EXISTS progress (
     work_id TEXT PRIMARY KEY,
     chapter_id TEXT NOT NULL,
     paragraph_index INTEGER NOT NULL DEFAULT 0,
     offset INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL DEFAULT 0
   )`,
  `CREATE TABLE IF NOT EXISTS job (
     id TEXT PRIMARY KEY,
     work_id TEXT NOT NULL,
     chapter_id TEXT NOT NULL DEFAULT '',
     status TEXT NOT NULL DEFAULT 'queued',
     total INTEGER NOT NULL DEFAULT 0,
     done INTEGER NOT NULL DEFAULT 0,
     failed INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS shelf (
     id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     sort_no INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL
   )`
];

export class Db {
  private static store: relationalStore.RdbStore | null = null;
  private static pending: Promise<relationalStore.RdbStore> | null = null;
  private static context: common.Context | null = null;

  /** 由 EntryAbility.onCreate 调用一次 */
  static init(context: common.Context): Promise<relationalStore.RdbStore> {
    Db.context = context;
    return Db.get();
  }

  static get(): Promise<relationalStore.RdbStore> {
    if (Db.store !== null) {
      return Promise.resolve(Db.store);
    }
    if (Db.pending !== null) {
      return Db.pending;
    }
    if (Db.context === null) {
      return Promise.reject(new Error('Db 未初始化，请先调用 Db.init(context)'));
    }
    const ctx = Db.context;
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    Db.pending = relationalStore.getRdbStore(ctx, config)
      .then((s: relationalStore.RdbStore) => {
        Db.store = s;
        return Db.migrate(s);
      })
      .then((s: relationalStore.RdbStore) => {
        Db.pending = null;
        return s;
      })
      .catch((err: Error) => {
        Db.pending = null;
        Log.e(`打开数据库失败: ${err.message}`);
        throw err as Error;
      });
    return Db.pending;
  }

  private static async migrate(store: relationalStore.RdbStore): Promise<relationalStore.RdbStore> {
    for (let i = 0; i < SCHEMA.length; i++) {
      await store.executeSql(SCHEMA[i]);
    }

    // v1 → v2：work 表补两列。CREATE TABLE IF NOT EXISTS 不会给已存在的旧表加列，
    // 所以必须显式检查再 ALTER；写成幂等的，重复启动不会报错。
    await Db.addColumn(store, 'work', 'dedupe_key', "TEXT NOT NULL DEFAULT ''");
    await Db.addColumn(store, 'work', 'fingerprint', "TEXT NOT NULL DEFAULT ''");
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_work_dedupe ON work (dedupe_key)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_work_fingerprint ON work (fingerprint)');

    // 加列之前导入的书键是空的，不补一次就永远查不出重复
    await Dedupe.backfill(store);

    // v2 → v3：书架分组 + 手动排序。
    // sort_no 全为 0 时排序无从谈起，所以新加列时按「最近更新在前」给现有书编号。
    await Db.addColumn(store, 'work', 'shelf_id', "TEXT NOT NULL DEFAULT ''");
    const addedSort = await Db.addColumn(store, 'work', 'sort_no', 'INTEGER NOT NULL DEFAULT 0');
    if (addedSort) {
      await Db.backfillSortNo(store);
    }
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_work_sort ON work (sort_no)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_work_shelf ON work (shelf_id)');

    // v3 → v4：chapter 表加来源链接。抓取管线现在记录每章的来源网页，
    // 补章/追更按链接定位；旧章保持空串，一切逻辑按空降级。
    await Db.addColumn(store, 'chapter', 'source_url', "TEXT NOT NULL DEFAULT ''");

    store.version = DB_VERSION;
    Log.i(`数据库就绪，version=${DB_VERSION}`);
    return store;
  }

  /**
   * 排序号回填：按最近更新排一遍 0..n-1。
   *
   * 没有这一步，所有旧书的 sort_no 都是 0，上下移动就成了挪空步。
   * 只在刚加列时执行一次，量级是书架里书的数量，可以放心逐条 update。
   */
  private static async backfillSortNo(store: relationalStore.RdbStore): Promise<void> {
    const rs = await store.querySql('SELECT id FROM work ORDER BY updated_at DESC');
    const ids: string[] = [];
    try {
      const idx = rs.getColumnIndex('id');
      while (rs.goToNextRow()) {
        ids.push(rs.getString(idx));
      }
    } finally {
      rs.close();
    }
    for (let i = 0; i < ids.length; i++) {
      await store.executeSql('UPDATE work SET sort_no = ? WHERE id = ?', [i, ids[i]]);
    }
    Log.i(`排序号回填完成：${ids.length} 本`);
  }

  /** 返回是否真的新增了这一列（用于判断要不要做一次性数据回填） */
  private static async addColumn(store: relationalStore.RdbStore, table: string,
    column: string, ddl: string): Promise<boolean> {
    try {
      if (await Db.hasColumn(store, table, column)) {
        return false;
      }
      await store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`);
      Log.i(`已添加列 ${table}.${column}`);
      return true;
    } catch (e) {
      // 列已存在（并发或旧版本残留）不该阻断启动
      Log.w(`添加列 ${table}.${column} 跳过：${(e as Error).message}`);
      return false;
    }
  }

  private static async hasColumn(store: relationalStore.RdbStore, table: string,
    column: string): Promise<boolean> {
    const rs = await store.querySql(`PRAGMA table_info(${table})`);
    let found = false;
    try {
      const idx = rs.getColumnIndex('name');
      while (rs.goToNextRow()) {
        if (rs.getString(idx) === column) {
          found = true;
          break;
        }
      }
    } finally {
      rs.close();
    }
    return found;
  }

  /** 事务包装：保证作品/章节/段落要么全进，要么全不进 */
  static async transaction(work: (store: relationalStore.RdbStore) => Promise<void>): Promise<void> {
    const store = await Db.get();
    store.beginTransaction();
    try {
      await work(store);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw e as Error;
    }
  }
}
