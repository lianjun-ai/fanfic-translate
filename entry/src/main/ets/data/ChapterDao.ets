import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Chapter, ChapterStatus } from '../model/Models';

const TABLE: string = 'chapter';

function toChapter(rs: relationalStore.ResultSet): Chapter {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    workId: rs.getString(rs.getColumnIndex('work_id')),
    indexNo: rs.getLong(rs.getColumnIndex('index_no')),
    title: rs.getString(rs.getColumnIndex('title')),
    status: rs.getString(rs.getColumnIndex('status')),
    summary: rs.getString(rs.getColumnIndex('summary')),
    translatedAt: rs.getLong(rs.getColumnIndex('translated_at'))
  };
}

export class ChapterDao {
  static bucket(c: Chapter): relationalStore.ValuesBucket {
    return {
      'id': c.id,
      'work_id': c.workId,
      'index_no': c.indexNo,
      'title': c.title,
      'status': c.status,
      'summary': c.summary,
      'translated_at': c.translatedAt
    };
  }

  static async insertIn(store: relationalStore.RdbStore, c: Chapter): Promise<number> {
    return store.insert(TABLE, ChapterDao.bucket(c));
  }

  static async listByWork(workId: string): Promise<Chapter[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId).orderByAsc('index_no');
    const rs = await store.query(predicates);
    const out: Chapter[] = [];
    while (rs.goToNextRow()) {
      out.push(toChapter(rs));
    }
    rs.close();
    return out;
  }

  static async find(id: string): Promise<Chapter | null> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const rs = await store.query(predicates);
    let result: Chapter | null = null;
    if (rs.goToNextRow()) {
      result = toChapter(rs);
    }
    rs.close();
    return result;
  }

  static async updateStatus(id: string, status: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'status': status };
    await store.update(bucket, predicates);
  }

  static async saveSummary(id: string, summary: string, status: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = {
      'summary': summary,
      'status': status,
      'translated_at': Date.now()
    };
    await store.update(bucket, predicates);
  }

  /**
   * 每本书「最新有梗概的章节」，书架卡片一次查询全部拿齐。
   *
   * 子查询取该书有梗概章节里 index_no 最大的那一行 —— 即「剧情讲到哪了」。
   * 没翻译过的书不会有行，卡片也就不显示摘要。
   */
  static async latestSummaries(): Promise<Record<string, Chapter>> {
    const store = await Db.get();
    const rs = await store.querySql(
      `SELECT c.* FROM ${TABLE} c
       WHERE c.summary != '' AND c.status = ?
         AND c.index_no = (SELECT MAX(c2.index_no) FROM ${TABLE} c2
             WHERE c2.work_id = c.work_id AND c2.summary != '' AND c2.status = ?)`,
      [ChapterStatus.TRANSLATED, ChapterStatus.TRANSLATED]);
    const out: Record<string, Chapter> = {};
    while (rs.goToNextRow()) {
      const c = toChapter(rs);
      out[c.workId] = c;
    }
    rs.close();
    return out;
  }

  /** 一本书的全部章节梗概，按章节顺序（剧情进展面板用） */
  static async summariesOf(workId: string): Promise<Chapter[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId)
      .equalTo('status', ChapterStatus.TRANSLATED)
      .notEqualTo('summary', '')
      .orderByAsc('index_no');
    const rs = await store.query(predicates);
    const out: Chapter[] = [];
    while (rs.goToNextRow()) {
      out.push(toChapter(rs));
    }
    rs.close();
    return out;
  }
}
