/**
 * 术语候选提取。
 *
 * 术语表要解决的是「同一个人名在不同段落被译成三个名字」。
 * 手动一条条敲太慢，所以先做一轮候选：把原文里反复出现的大写专名挑出来，
 * 按频次排序。这一步刻意用规则而不是模型 —— 规则零成本、瞬时返回、
 * 结果稳定，用户扫一眼就能判断，比等一次请求再检查一堆幻觉名词划算。
 *
 * 判断依据来自同人文本的实际分布：
 *  - 多词大写短语（Sherlock Holmes / Hogwarts Express）几乎一定是专名；
 *  - 单个大写词需要更高的出现次数，因为句首任何词都会大写；
 *  - 如果一个词的小写形式也频繁独立出现，它就是普通词（Will / will）。
 */
export interface TermCandidateItem {
  text: string;
  count: number;
}

const PATTERN: string = '[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,}){0,2}';

/** 句首高频词与常见虚词。命中即丢，宁可漏也不要让用户被噪音淹掉 */
const STOP: string[] = [
  'the', 'and', 'but', 'for', 'with', 'from', 'that', 'this', 'these', 'those', 'what', 'when', 'where',
  'which', 'while', 'who', 'whom', 'whose', 'why', 'how', 'his', 'her', 'hers', 'him', 'she', 'they',
  'them', 'their', 'theirs', 'you', 'your', 'yours', 'our', 'ours', 'its', 'not', 'was', 'were', 'are',
  'been', 'being', 'have', 'has', 'had', 'does', 'did', 'doing', 'there', 'then', 'than', 'now', 'just',
  'like', 'know', 'said', 'says', 'would', 'could', 'should', 'will', 'shall', 'can', 'may', 'might',
  'must', 'about', 'into', 'over', 'after', 'before', 'because', 'through', 'between', 'under', 'above',
  'against', 'again', 'still', 'never', 'always', 'even', 'only', 'very', 'more', 'most', 'some', 'any',
  'all', 'both', 'each', 'other', 'another', 'also', 'here', 'back', 'away', 'down', 'off', 'out', 'up',
  'yes', 'yeah', 'okay', 'god', 'damn', 'hell', 'please', 'sorry', 'thank', 'thanks', 'well', 'oh',
  'chapter', 'part', 'note', 'author', 'summary', 'prologue', 'epilogue', 'end', 'one', 'two', 'three',
  'first', 'last', 'next', 'new', 'old', 'good', 'bad', 'right', 'left', 'thing', 'things', 'time',
  'day', 'night', 'moment', 'second', 'minute', 'hour', 'today', 'tomorrow', 'yesterday', 'monday',
  'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'
];

export class TermCandidate {
  /**
   * @param text 原文拼接文本（已去掉译文，避免候选里混进中文译名）
   * @param minCount 多词短语的最小出现次数
   * @param limit 返回条数上限
   */
  static extract(text: string, minCount: number, limit: number): TermCandidateItem[] {
    const out: TermCandidateItem[] = [];
    if (text.length === 0) {
      return out;
    }
    const counts = new Map<string, number>();
    const re = new RegExp(PATTERN, 'g');
    let m = re.exec(text);
    while (m !== null) {
      const word = m[0];
      const words = word.split(' ');
      if (words.length === 1) {
        if (!TermCandidate.isStop(word)) {
          counts.set(word, (counts.get(word) ?? 0) + 1);
        }
      } else {
        // 多词短语：命中率极高，单独用一个高位权重，保证排在单名前
        counts.set(word, (counts.get(word) ?? 0) + 3);
      }
      m = re.exec(text);
    }

    const items: TermCandidateItem[] = [];
    counts.forEach((count: number, key: string) => {
      const words = key.split(' ');
      const need = words.length > 1 ? minCount : minCount + 1;
      if (count < need) {
        return;
      }
      if (words.length === 1 && TermCandidate.looksLikeCommonWord(key, text)) {
        return;
      }
      const item: TermCandidateItem = { text: key, count: count };
      items.push(item);
    });

    items.sort((a: TermCandidateItem, b: TermCandidateItem) => {
      if (b.count !== a.count) {
        return b.count - a.count;
      }
      return a.text < b.text ? -1 : 1;
    });
    for (let i = 0; i < items.length && i < limit; i++) {
      out.push(items[i]);
    }
    return out;
  }

  private static isStop(word: string): boolean {
    return STOP.indexOf(word.toLowerCase()) >= 0;
  }

  /**
   * 小写形式独立出现多次，说明它更像普通词。
   * 这条规则专治 Will / May / Rose 这类「既是人名又是常用词」的坑。
   *
   * 必须拿原文（而不是转成小写的副本）来数：全小写文本里每个 Holmes 都长得像
   * "holmes"，那样等于把人名全判成普通词。indexOf 区分大小写，
   * 用小写词去搜原文，命中的天然只有真正的小写用法。
   */
  private static looksLikeCommonWord(word: string, text: string): boolean {
    const w = word.toLowerCase();
    let lowCount = 0;
    let from = 0;
    while (true) {
      const at = text.indexOf(` ${w}`, from);
      if (at < 0) {
        break;
      }
      const end = at + 1 + w.length;
      const next = end < text.length ? text.charAt(end) : ' ';
      if (!TermCandidate.isLetter(next)) {
        lowCount++;
      }
      from = at + 1;
      if (lowCount > 3) {
        break;
      }
    }
    return lowCount > 3;
  }

  private static isLetter(c: string): boolean {
    if (c.length === 0) {
      return false;
    }
    const code = c.charCodeAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  /** 拉丁字母太少时直接放弃 —— 中文原文没有大小写信号，规则法无从下手 */
  static worthExtracting(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    let latin = 0;
    const step = Math.max(1, Math.floor(text.length / 2000));
    for (let i = 0; i < text.length; i += step) {
      const c = text.charCodeAt(i);
      if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
        latin++;
      }
    }
    return latin > 200;
  }
}
