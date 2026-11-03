import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Paragraph, ParaStatus } from '../model/Models';

const TABLE: string = 'paragraph';
const BATCH: number = 400;

function toParagraph(rs: relationalStore.ResultSet): Paragraph {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    chapterId: rs.getString(rs.getColumnIndex('chapter_id')),
    indexNo: rs.getLong(rs.getColumnIndex('index_no')),
    type: rs.getString(rs.getColumnIndex('type')),
    runs: rs.getString(rs.getColumnIndex('runs')),
    translatedRuns: rs.getString(rs.getColumnIndex('translated_runs')),
    status: rs.getString(rs.getColumnIndex('status')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
  };
}

export class ParagraphDao {
  static bucket(p: Paragraph): relationalStore.ValuesBucket {
    return {
      'id': p.id,
      'chapter_id': p.chapterId,
      'index_no': p.indexNo,
      'type': p.type,
      'runs': p.runs,
      'translated_runs': p.translatedRuns,
      'status': p.status,
      'updated_at': p.updatedAt
    };
  }

  /** 分批写入。一本三十万字的书约两三千段，一次性 batchInsert 会撑爆单条 SQL */
  static async insertBatchIn(store: relationalStore.RdbStore, list: Paragraph[]): Promise<void> {
    let i = 0;
    while (i < list.length) {
      const chunk: relationalStore.ValuesBucket[] = [];
      const end = Math.min(i + BATCH, list.length);
      for (let k = i; k < end; k++) {
        chunk.push(ParagraphDao.bucket(list[k]));
      }
      await store.batchInsert(TABLE, chunk);
      i = end;
    }
  }

  static async listByChapter(chapterId: string): Promise<Paragraph[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('chapter_id', chapterId).orderByAsc('index_no');
    const rs = await store.query(predicates);
    const out: Paragraph[] = [];
    while (rs.goToNextRow()) {
      out.push(toParagraph(rs));
    }
    rs.close();
    return out;
  }

  static async listPending(chapterId: string): Promise<Paragraph[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('chapter_id', chapterId).equalTo('status', ParaStatus.PENDING).orderByAsc('index_no');
    const rs = await store.query(predicates);
    const out: Paragraph[] = [];
    while (rs.goToNextRow()) {
      out.push(toParagraph(rs));
    }
    rs.close();
    return out;
  }

  /** 译文落库。runs 与 translated_runs 结构一致，样式分布可继承 */
  static async saveTranslation(id: string, translatedRuns: string, status: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = {
      'translated_runs': translatedRuns,
      'status': status,
      'updated_at': Date.now()
    };
    await store.update(bucket, predicates);
  }

  static async updateStatus(ids: string[], status: string): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    const store = await Db.get();
    for (let i = 0; i < ids.length; i++) {
      const predicates = new relationalStore.RdbPredicates(TABLE);
      predicates.equalTo('id', ids[i]);
      const bucket: relationalStore.ValuesBucket = { 'status': status, 'updated_at': Date.now() };
      await store.update(bucket, predicates);
    }
  }

  static async countByChapter(chapterId: string): Promise<number> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('chapter_id', chapterId);
    const rs = await store.query(predicates, ['id']);
    const n = rs.rowCount;
    rs.close();
    return n < 0 ? 0 : n;
  }
}
