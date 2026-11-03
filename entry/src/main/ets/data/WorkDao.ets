import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Work } from '../model/Models';

const TABLE: string = 'work';

function toWork(rs: relationalStore.ResultSet): Work {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    title: rs.getString(rs.getColumnIndex('title')),
    author: rs.getString(rs.getColumnIndex('author')),
    sourceType: rs.getString(rs.getColumnIndex('source_type')),
    sourceUrl: rs.getString(rs.getColumnIndex('source_url')),
    language: rs.getString(rs.getColumnIndex('language')),
    tags: rs.getString(rs.getColumnIndex('tags')),
    coverPath: rs.getString(rs.getColumnIndex('cover_path')),
    wordCount: rs.getLong(rs.getColumnIndex('word_count')),
    chapterCount: rs.getLong(rs.getColumnIndex('chapter_count')),
    dedupeKey: rs.getString(rs.getColumnIndex('dedupe_key')),
    fingerprint: rs.getString(rs.getColumnIndex('fingerprint')),
    shelfId: rs.getString(rs.getColumnIndex('shelf_id')),
    sortNo: rs.getLong(rs.getColumnIndex('sort_no')),
    createdAt: rs.getLong(rs.getColumnIndex('created_at')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
  };
}

export class WorkDao {
  static bucket(w: Work): relationalStore.ValuesBucket {
    return {
      'id': w.id,
      'title': w.title,
      'author': w.author,
      'source_type': w.sourceType,
      'source_url': w.sourceUrl,
      'language': w.language,
      'tags': w.tags,
      'cover_path': w.coverPath,
      'word_count': w.wordCount,
      'chapter_count': w.chapterCount,
      'dedupe_key': w.dedupeKey,
      'fingerprint': w.fingerprint,
      'shelf_id': w.shelfId,
      'sort_no': w.sortNo,
      'created_at': w.createdAt,
      'updated_at': w.updatedAt
    };
  }

  /** 事务内插入，复用外部 store 避免嵌套取库 */
  static async insertIn(store: relationalStore.RdbStore, w: Work): Promise<number> {
    return store.insert(TABLE, WorkDao.bucket(w));
  }

  static async insert(w: Work): Promise<number> {
    const store = await Db.get();
    return store.insert(TABLE, WorkDao.bucket(w));
  }

  /** 书架顺序：手动排序号优先，同号（旧数据）按最近更新兜底 */
  static async list(): Promise<Work[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.orderByAsc('sort_no');
    predicates.orderByDesc('updated_at');
    const rs = await store.query(predicates);
    const out: Work[] = [];
    while (rs.goToNextRow()) {
      out.push(toWork(rs));
    }
    rs.close();
    return out;
  }

  /** 新书排在最后：取当前最大序号 + 1 */
  static async nextSortNo(): Promise<number> {
    const store = await Db.get();
    const rs = await store.querySql(`SELECT MAX(sort_no) AS m FROM ${TABLE}`);
    let max = 0;
    try {
      if (rs.goToNextRow()) {
        max = rs.getLong(rs.getColumnIndex('m'));
      }
    } finally {
      rs.close();
    }
    return max + 1;
  }

  /** 移动到分组；shelfId 传空串即移出分组 */
  static async moveToShelf(id: string, shelfId: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'shelf_id': shelfId };
    await store.update(bucket, predicates);
  }

  /**
   * 按给定顺序重排一批书。
   *
   * 做法是复用这批书原本占用的序号槽位（升序取出再按新顺序发回去），
   * 所以不会和别的分组的书撞号，也不影响它们的位置。
   */
  static async reorder(ordered: Work[]): Promise<void> {
    if (ordered.length < 2) {
      return;
    }
    const slots: number[] = [];
    for (let i = 0; i < ordered.length; i++) {
      slots.push(ordered[i].sortNo);
    }
    slots.sort((x: number, y: number) => x - y);
    const store = await Db.get();
    for (let i = 0; i < ordered.length; i++) {
      await WorkDao.setSortNo(store, ordered[i].id, slots[i]);
    }
  }

  private static async setSortNo(store: relationalStore.RdbStore, id: string, sortNo: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'sort_no': sortNo };
    await store.update(bucket, predicates);
  }

  /** 全表按当前顺序重新编号 0..n-1 */
  static async normalizeSort(): Promise<void> {
    const all = await WorkDao.list();
    const store = await Db.get();
    for (let i = 0; i < all.length; i++) {
      await WorkDao.setSortNo(store, all[i].id, i);
    }
  }

  /** 删除分组时用：把该分组下的书全部退回未分组 */
  static async clearShelf(shelfId: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('shelf_id', shelfId);
    const bucket: relationalStore.ValuesBucket = { 'shelf_id': '' };
    await store.update(bucket, predicates);
  }

  static async find(id: string): Promise<Work | null> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const rs = await store.query(predicates);
    let result: Work | null = null;
    if (rs.goToNextRow()) {
      result = toWork(rs);
    }
    rs.close();
    return result;
  }

  private static async findOneBy(column: string, value: string): Promise<Work | null> {
    if (value.length === 0) {
      return null;
    }
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo(column, value);
    const rs = await store.query(predicates);
    let result: Work | null = null;
    if (rs.goToNextRow()) {
      result = toWork(rs);
    }
    rs.close();
    return result;
  }

  /** 同内容：改名也能认出来 */
  static findByFingerprint(fp: string): Promise<Work | null> {
    return WorkDao.findOneBy('fingerprint', fp);
  }

  /** 同书名同作者：重新下载的修订版走这一条 */
  static findByDedupeKey(key: string): Promise<Work | null> {
    return WorkDao.findOneBy('dedupe_key', key);
  }

  static async touch(id: string, updatedAt: number): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'updated_at': updatedAt };
    await store.update(bucket, predicates);
  }

  /** 删除作品及其所有从属数据（章节、段落、术语、进度、任务） */
  static async remove(id: string): Promise<void> {
    const store = await Db.get();
    store.beginTransaction();
    try {
      const chapterPred = new relationalStore.RdbPredicates('chapter');
      chapterPred.equalTo('work_id', id);
      const rs = await store.query(chapterPred);
      const chapterIds: string[] = [];
      while (rs.goToNextRow()) {
        chapterIds.push(rs.getString(rs.getColumnIndex('id')));
      }
      rs.close();
      for (let i = 0; i < chapterIds.length; i++) {
        const p = new relationalStore.RdbPredicates('paragraph');
        p.equalTo('chapter_id', chapterIds[i]);
        await store.delete(p);
      }
      const cp = new relationalStore.RdbPredicates('chapter');
      cp.equalTo('work_id', id);
      await store.delete(cp);
      const tp = new relationalStore.RdbPredicates('term');
      tp.equalTo('work_id', id);
      await store.delete(tp);
      const pp = new relationalStore.RdbPredicates('progress');
      pp.equalTo('work_id', id);
      await store.delete(pp);
      const jp = new relationalStore.RdbPredicates('job');
      jp.equalTo('work_id', id);
      await store.delete(jp);
      const wp = new relationalStore.RdbPredicates(TABLE);
      wp.equalTo('id', id);
      await store.delete(wp);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw e as Error;
    }
  }
}
