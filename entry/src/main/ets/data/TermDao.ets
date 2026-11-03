import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Term, newId, runsToPlainText, parseRuns } from '../model/Models';

const TABLE: string = 'term';

function toTerm(rs: relationalStore.ResultSet): Term {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    workId: rs.getString(rs.getColumnIndex('work_id')),
    source: rs.getString(rs.getColumnIndex('source')),
    target: rs.getString(rs.getColumnIndex('target')),
    note: rs.getString(rs.getColumnIndex('note'))
  };
}

/**
 * 术语表。M3 只负责把它读出来注入提示词，
 * 增删改的界面放到 M4 —— 但没有这一层，翻译管线就少一个入口。
 */
export class TermDao {
  static async listByWork(workId: string): Promise<Term[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId).orderByAsc('source');
    const rs = await store.query(predicates);
    const out: Term[] = [];
    while (rs.goToNextRow()) {
      out.push(toTerm(rs));
    }
    rs.close();
    return out;
  }

  /** 同一作品下原文唯一，重复则覆盖译名 */
  static async upsert(workId: string, source: string, target: string, note: string): Promise<void> {
    const store = await Db.get();
    const src = source.trim();
    if (src.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId).equalTo('source', src);
    const rs = await store.query(predicates);
    const exists = rs.goToNextRow();
    const id = exists ? rs.getString(rs.getColumnIndex('id')) : '';
    rs.close();

    const bucket: relationalStore.ValuesBucket = {
      'target': target.trim(),
      'note': note.trim()
    };
    if (exists) {
      const p = new relationalStore.RdbPredicates(TABLE);
      p.equalTo('id', id);
      await store.update(bucket, p);
      return;
    }
    bucket['id'] = newId();
    bucket['work_id'] = workId;
    bucket['source'] = src;
    await store.insert(TABLE, bucket);
  }

  static async remove(id: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    await store.delete(predicates);
  }

  /**
   * 取本作品的原文语料，供专名候选提取使用。
   *
   * 这里用的是原文（runs）而不是译文：候选是给「还没定译名」的专名准备的，
   * 译文里已经是中文字，提取不出任何东西。
   * 只按行顺序取前若干段，而不是全量 —— 一百万字全扫一遍不如取前一半的十分之一，
   * 专名在开头出现的密度已经足够判断。
   */
  static async corpus(workId: string, maxParas: number): Promise<string> {
    const store = await Db.get();
    const sql = `SELECT p.runs FROM paragraph p INNER JOIN chapter c ON p.chapter_id = c.id
                 WHERE c.work_id = ? AND p.type != 'divider'
                 ORDER BY c.index_no ASC, p.index_no ASC LIMIT ?`;
    const args: relationalStore.ValueType[] = [workId, maxParas];
    const rs = await store.querySql(sql, args);
    let text = '';
    try {
      const idx = rs.getColumnIndex('runs');
      while (rs.goToNextRow()) {
        text += `${runsToPlainText(parseRuns(rs.getString(idx)))}\n`;
        if (text.length > 120000) {
          break;
        }
      }
    } finally {
      rs.close();
    }
    return text;
  }
}
