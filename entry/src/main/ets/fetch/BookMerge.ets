import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { relationalStore } from '@kit.ArkData';
import { EpubParser } from '../parser/EpubParser';
import { HtmlFileParser } from '../parser/HtmlFileParser';
import { TxtParser } from '../parser/TxtParser';
import { ParsedChapter, ParsedWork } from '../parser/ParserTypes';
import { WebChapter, WebToBook } from './WebToBook';
import { FicMeta } from './FicHub';
import { ChapterRef, PendingItem, PendingStore } from './PendingStore';
import { Dedupe } from '../data/Dedupe';
import { Db } from '../data/Db';
import { WorkDao } from '../data/WorkDao';
import { ChapterDao } from '../data/ChapterDao';
import { ParagraphDao } from '../data/ParagraphDao';
import { Work, Chapter, ChapterStatus, Paragraph, ParaStatus, countWords, newId, plainRun, stringifyRuns, runsToPlainText } from '../model/Models';
import { Log } from '../common/Logger';

/** 合并统计：交给模型核对章数对不对（合完是不是从头到尾连续） */
export interface MergeStats {
  chapters: number;
  /** 去重丢掉的章数 */
  dropped: number;
  /** 是否按章号重排过 */
  ordered: boolean;
  /** 合并了几个来源 */
  sources: number;
  firstTitle: string;
  lastTitle: string;
}

export interface MergeOutcome {
  item: PendingItem;
  stats: MergeStats;
}

/** 补章结果：target 是待入库条目还是书架作品，模型照着 note 转述即可 */
export interface AppendOutcome {
  /** 'pending'（合成新的待入库条目）或 'shelf'（直接补进书架作品） */
  kind: string;
  title: string;
  /** 实际补进的章数 */
  added: number;
  /** 撞上已有章被跳过的 */
  skipped: number;
  /** 补完后的总章数 */
  totalChapters: number;
  /** 缺章提示（按章号算出来的空洞），没有为空串 */
  gaps: string;
  /** 想按章号插位但标题读不出章号、只能追加在末尾的新章数 */
  unnumbered: number;
  firstTitle: string;
  lastTitle: string;
  /** pending 路径的新条目；shelf 路径为 null */
  item: PendingItem | null;
}

/** 补章目标：待入库条目或书架作品二选一 */
export interface TargetRef {
  kind: string;
  item: PendingItem | null;
  work: Work | null;
}

/** 带章号的一章，用于重排 */
interface NumberedChapter {
  no: number;
  idx: number;
  ch: ParsedChapter;
}

/** 插库排序时的一个槽位：已有章（chapterId 非空）或新章（parsed 非空） */
interface Slot {
  chapterId: string;
  parsed: ParsedChapter | null;
  no: number;
  idx: number;
}

/** normalize 的结果：去重重排后的章节 + 统计 */
interface NormalizeResult {
  chapters: ParsedChapter[];
  dropped: number;
  ordered: boolean;
}

/**
 * 书的「增补引擎」：合并、补章、追更统一走这一条路。
 *
 * 目标可以是待入库条目（内容合成一本新的待入库 HTML）也可以是书架作品
 * （章节直接插库，按章号重排 index_no）。唯一原则：已有章绝不覆盖——
 * 译文、阅读进度、摘要都挂在旧章上，动不得；冲突章默认保留旧版。
 *
 * 之前 merge_books 只能合并待入库、且合并即删原件；书架补章则完全无解
 * （只能整本重抓）。根因是章节的来源链接在抓取时就丢了。现在抓取管线
 * 把每章链接存进边车（PendingItem.chapterIndex）和 chapter.source_url，
 * 这里的对齐与插入才有数据可用。
 */
export class BookMerge {

  // ---------- 目标解析 ----------

  /**
   * 把模型给的 target 字符串解析成补章目标。
   * 先待入库后书架；两边都匹配不上返回 null（调用方回清单让模型自愈）。
   */
  static async resolveTarget(ctx: common.UIAbilityContext, tok: string): Promise<TargetRef | null> {
    const t = tok.trim();
    if (t.length === 0) {
      return null;
    }
    const pend = await PendingStore.list(ctx);
    for (let i = 0; i < pend.length; i++) {
      const it = pend[i];
      if (it.epubPath === t || it.sourceUrl === t || it.title === t) {
        return { kind: 'pending', item: it, work: null };
      }
    }
    const works = await WorkDao.list();
    for (let i = 0; i < works.length; i++) {
      const w = works[i];
      if (w.id === t || w.sourceUrl === t || Dedupe.norm(w.title) === Dedupe.norm(t)) {
        return { kind: 'shelf', item: null, work: w };
      }
    }
    return null;
  }

  // ---------- 追加入口 ----------

  /**
   * 把 sources（待入库条目或网页链接）的章节补进 target。
   * 待入库目标：合成一本新的待入库条目，旧的（目标+来源）默认清掉。
   * 书架目标：新章直接插库，已有章不动，进度与译文天然安全。
   */
  static async append(ctx: common.UIAbilityContext, target: TargetRef, sourceItems: PendingItem[],
    sourceUrls: string[], titleArg: string, authorArg: string, keepOriginals: boolean,
    numbers: number[], onProgress: (msg: string) => void): Promise<AppendOutcome> {
    // 收集新章：待入库来源解析 + 边车链接回填；网页来源现抓
    const fresh: ParsedChapter[] = [];
    for (let i = 0; i < sourceItems.length; i++) {
      onProgress(`正在读取《${sourceItems[i].title}》…`);
      const parsed = await BookMerge.parseItem(ctx, sourceItems[i]);
      BookMerge.joinUrls(sourceItems[i], parsed);
      for (let c = 0; c < parsed.chapters.length; c++) {
        fresh.push(parsed.chapters[c]);
      }
    }
    if (sourceUrls.length > 0) {
      const dir = `${ctx.cacheDir}/finder_dl`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      for (let i = 0; i < sourceUrls.length; i++) {
        onProgress(`正在抓取 ${sourceUrls[i]}…`);
        const page = await WebToBook.fetchPage(sourceUrls[i], dir);
        if (!page.ok) {
          throw new Error(`第 ${i + 1} 个网页没抓到正文：${page.note}`);
        }
        const url = page.url.length > 0 ? page.url : sourceUrls[i];
        const cut = WebToBook.splitChapters(page.paragraphs, [url], BookMerge.rangeOf(page.paragraphs.length));
        if (cut !== null) {
          for (let c = 0; c < cut.length; c++) {
            fresh.push({ title: cut[c].title, paragraphs: cut[c].paragraphs, url: cut[c].url });
          }
        } else {
          fresh.push({ title: page.title.length > 0 ? page.title : `补章 ${i + 1}`, paragraphs: page.paragraphs, url: url });
        }
      }
    }
    if (fresh.length === 0) {
      throw new Error('来源里没有解析出任何章节');
    }
    // 模型显式给的章号：网页标题读不出「第N章」时（LOFTER 帖子页标题经常是
    // 文章名甚至站点名），靠它定位插入位置，否则只能追加在末尾
    BookMerge.applyNumbers(fresh, numbers);

    if (target.kind === 'pending' && target.item !== null) {
      return BookMerge.appendPending(ctx, target.item, fresh, sourceItems,
        titleArg, authorArg, keepOriginals, onProgress);
    }
    if (target.kind === 'shelf' && target.work !== null) {
      return BookMerge.appendShelf(ctx, target.work, fresh, onProgress);
    }
    throw new Error('补章目标类型不对');
  }

  // ---------- 待入库目标：合成新条目 ----------

  private static async appendPending(ctx: common.UIAbilityContext, target: PendingItem,
    fresh: ParsedChapter[], sourceItems: PendingItem[], titleArg: string, authorArg: string,
    keepOriginals: boolean, onProgress: (msg: string) => void): Promise<AppendOutcome> {
    onProgress(`正在读取目标《${target.title}》…`);
    const parsed = await BookMerge.parseItem(ctx, target);
    BookMerge.joinUrls(target, parsed);
    const all: ParsedChapter[] = [];
    for (let c = 0; c < parsed.chapters.length; c++) {
      all.push(parsed.chapters[c]);
    }
    for (let i = 0; i < fresh.length; i++) {
      all.push(fresh[i]);
    }

    const norm = BookMerge.normalize(all);
    if (norm.chapters.length === 0) {
      throw new Error('合并后一章都不剩，中止');
    }

    onProgress('正在合成一本…');
    const workTitle = titleArg.length > 0 ? titleArg : target.title;
    const workAuthor = authorArg.length > 0 ? authorArg : target.author;
    const item = await BookMerge.writePending(ctx, workTitle, workAuthor,
      `合并 ${1 + sourceItems.length} 本${norm.dropped > 0 ? ` · 去掉 ${norm.dropped} 章重复` : ''}`,
      target.sourceUrl, norm.chapters, onProgress);

    if (!keepOriginals) {
      await PendingStore.remove(ctx, target);
      for (let i = 0; i < sourceItems.length; i++) {
        await PendingStore.remove(ctx, sourceItems[i]);
      }
    }
    Log.i(`补章（待入库）：《${workTitle}》→ ${norm.chapters.length} 章（新增 ${fresh.length - norm.dropped}，重复合并 ${norm.dropped}）`);
    return {
      kind: 'pending',
      title: workTitle,
      added: fresh.length - norm.dropped,
      skipped: norm.dropped,
      totalChapters: norm.chapters.length,
      gaps: BookMerge.gapNote(norm.chapters.map((c: ParsedChapter): string => c.title)),
      unnumbered: 0,
      firstTitle: norm.chapters[0].title,
      lastTitle: norm.chapters[norm.chapters.length - 1].title,
      item: item
    };
  }

  // ---------- 书架目标：章节插库 ----------

  private static async appendShelf(ctx: common.UIAbilityContext, work: Work,
    fresh: ParsedChapter[], onProgress: (msg: string) => void): Promise<AppendOutcome> {
    onProgress(`正在读取书架《${work.title}》的章节…`);
    const existing = await ChapterDao.listByWork(work.id);

    // 撞重：书架章只能按标题键比（正文在 paragraph 表，不为查重去读全量段落）
    const seen = new Set<string>();
    for (let i = 0; i < existing.length; i++) {
      const k = Dedupe.norm(existing[i].title);
      if (k.length > 0) {
        seen.add(`t:${k}`);
      }
    }
    const toAdd: ParsedChapter[] = [];
    let skipped = 0;
    for (let i = 0; i < fresh.length; i++) {
      const k = BookMerge.chapterKey(fresh[i]);
      if (k.startsWith('t:') && seen.has(k)) {
        skipped++;
        continue;
      }
      if (k.startsWith('t:')) {
        seen.add(k);
      }
      toAdd.push(fresh[i]);
    }

    // 排序：只要求旧章多数读得出章号（新章读不出章号的接在末尾）。
    // 不能要求新章也过八成门槛——补两三章时，一个标题读不出号就全军覆没，
    // 全部追加在末尾（正是「缺的第 20、30 章补进了却在书尾」的根因）。
    let numbered = 0;
    for (let i = 0; i < existing.length; i++) {
      if (WebToBook.chapterNumber(existing[i].title) > 0) {
        numbered++;
      }
    }
    const reorder = existing.length > 0 && numbered >= Math.ceil(existing.length * 0.8);

    // 最终顺序：旧章的相对顺序永不动（译文/进度/摘要都挂在旧章上），
    // 只决定新章插在哪——按章号找到最后一个不大于它的旧章，插到其后
    const slots: Slot[] = [];
    for (let i = 0; i < existing.length; i++) {
      slots.push({
        chapterId: existing[i].id,
        parsed: null,
        no: WebToBook.chapterNumber(existing[i].title),
        idx: i
      });
    }
    const tail: Slot[] = [];
    for (let i = 0; i < toAdd.length; i++) {
      const no = WebToBook.chapterNumber(toAdd[i].title);
      const slot: Slot = { chapterId: '', parsed: toAdd[i], no: no, idx: existing.length + i };
      if (!reorder || no <= 0) {
        tail.push(slot);
        continue;
      }
      // 从后往前找插入锚点（已有章或先插进来的新章，章号 ≤ 新章号）
      let pos = -1;
      for (let j = slots.length - 1; j >= 0; j--) {
        if (slots[j].no > 0 && slots[j].no <= no) {
          pos = j;
          break;
        }
      }
      if (pos < 0) {
        slots.unshift(slot);
      } else {
        slots.splice(pos + 1, 0, slot);
      }
    }
    for (let i = 0; i < tail.length; i++) {
      slots.push(tail[i]);
    }
    const unnumbered = reorder ? tail.length : 0;

    onProgress(`正在写入书架（新增 ${toAdd.length} 章）…`);
    const now = Date.now();
    await Db.transaction(async (store: relationalStore.RdbStore) => {
      // 唯一索引 (work_id, index_no)：先把旧章全部搬开再逐个落位，
      // 要不然插到中间时序号会和后面的章相撞
      await store.executeSql('UPDATE chapter SET index_no = index_no + 1000000 WHERE work_id = ?', [work.id]);
      let added = 0;
      for (let i = 0; i < slots.length; i++) {
        const s = slots[i];
        if (s.parsed === null) {
          await store.executeSql('UPDATE chapter SET index_no = ? WHERE id = ?', [i, s.chapterId]);
          continue;
        }
        const chapterId = newId();
        const chapter: Chapter = {
          id: chapterId,
          workId: work.id,
          indexNo: i,
          title: s.parsed.title,
          status: ChapterStatus.PENDING,
          summary: '',
          translatedAt: 0,
          sourceUrl: s.parsed.url !== undefined ? s.parsed.url : ''
        };
        await ChapterDao.insertIn(store, chapter);
        const rows: Paragraph[] = [];
        for (let pi = 0; pi < s.parsed.paragraphs.length; pi++) {
          const pp = s.parsed.paragraphs[pi];
          const runs = pp.runs.length > 0 ? pp.runs : [plainRun('')];
          rows.push({
            id: newId(),
            chapterId: chapterId,
            indexNo: pi,
            type: pp.type,
            runs: stringifyRuns(runs),
            translatedRuns: '',
            status: ParaStatus.PENDING,
            updatedAt: now
          });
        }
        await ParagraphDao.insertBatchIn(store, rows);
        added++;
      }
      // 作品行同步：总章数、字数（只累加新章）、更新时间
      let newWords = 0;
      for (let i = 0; i < toAdd.length; i++) {
        for (let p = 0; p < toAdd[i].paragraphs.length; p++) {
          newWords += countWords(runsToPlainText(toAdd[i].paragraphs[p].runs));
        }
      }
      await store.executeSql('UPDATE work SET chapter_count = ?, word_count = word_count + ?, updated_at = ? WHERE id = ?',
        [slots.length, newWords, now, work.id]);
      Log.i(`补章（书架）：《${work.title}》+${added} 章 → ${slots.length} 章`);
    });

    const titles: string[] = [];
    for (let i = 0; i < existing.length; i++) {
      titles.push(existing[i].title);
    }
    for (let i = 0; i < toAdd.length; i++) {
      titles.push(toAdd[i].title);
    }
    let firstTitle = '';
    let lastTitle = '';
    if (slots.length > 0) {
      const first = slots[0];
      const last = slots[slots.length - 1];
      firstTitle = first.parsed !== null ? first.parsed.title :
        BookMerge.titleOf(existing, first.chapterId);
      lastTitle = last.parsed !== null ? last.parsed.title :
        BookMerge.titleOf(existing, last.chapterId);
    }
    return {
      kind: 'shelf',
      title: work.title,
      added: toAdd.length,
      skipped: skipped,
      totalChapters: slots.length,
      gaps: BookMerge.gapNote(titles),
      unnumbered: unnumbered,
      firstTitle: firstTitle,
      lastTitle: lastTitle,
      item: null
    };
  }

  private static titleOf(existing: Chapter[], chapterId: string): string {
    for (let i = 0; i < existing.length; i++) {
      if (existing[i].id === chapterId) {
        return existing[i].title;
      }
    }
    return '';
  }

  // ---------- 公共件 ----------

  /** 章节的来源链接；可选字段收窄成非空串 */
  private static urlOf(ch: ParsedChapter): string {
    if (ch.url === undefined) {
      return '';
    }
    return ch.url;
  }

  /**
   * 去重 + 重排（合并与补章共用）。
   * 章号/标题归一化后相同算同一章；绝大多数章读得出章号才按章号重排。
   */
  private static normalize(all: ParsedChapter[]): NormalizeResult {
    const seen = new Set<string>();
    const kept: ParsedChapter[] = [];
    let dropped = 0;
    for (let i = 0; i < all.length; i++) {
      const key = BookMerge.chapterKey(all[i]);
      if (key.length > 0 && seen.has(key)) {
        dropped++;
        continue;
      }
      if (key.length > 0) {
        seen.add(key);
      }
      kept.push(all[i]);
    }
    let numbered = 0;
    for (let i = 0; i < kept.length; i++) {
      if (WebToBook.chapterNumber(kept[i].title) > 0) {
        numbered++;
      }
    }
    const ordered = numbered >= Math.ceil(kept.length * 0.8);
    let final: ParsedChapter[] = kept;
    if (ordered) {
      const list: NumberedChapter[] = [];
      for (let i = 0; i < kept.length; i++) {
        list.push({ no: WebToBook.chapterNumber(kept[i].title), idx: i, ch: kept[i] });
      }
      list.sort((a: NumberedChapter, b: NumberedChapter) => a.no !== b.no ? a.no - b.no : a.idx - b.idx);
      const out: ParsedChapter[] = [];
      for (let i = 0; i < list.length; i++) {
        out.push(list[i].ch);
      }
      final = out;
    }
    return { chapters: final, dropped: dropped, ordered: ordered };
  }

  /** 把待入库条目的章节清单（边车）按标题回填到解析出的章节上 */
  private static joinUrls(item: PendingItem, parsed: ParsedWork): void {
    if (item.chapterIndex === undefined) {
      return;
    }
    const idx = item.chapterIndex;
    for (let i = 0; i < parsed.chapters.length; i++) {
      const ch = parsed.chapters[i];
      const key = Dedupe.norm(ch.title);
      if (key.length === 0) {
        continue;
      }
      for (let j = 0; j < idx.length; j++) {
        if (Dedupe.norm(idx[j].title) !== key) {
          continue;
        }
        if (idx[j].url.length > 0) {
          ch.url = idx[j].url;
        }
        // 边车里记了章号而标题里读不出来 → 补进标题，插入排序和缺章报告才有据可依
        if (idx[j].no > 0 && WebToBook.chapterNumber(ch.title) === 0) {
          ch.title = `第${idx[j].no}章 ${ch.title}`;
        }
        break;
      }
    }
  }

  /**
   * 模型显式给的章号（add_chapters 的 numbers 参数，与章节按顺序对应）：
   * 标题里读不出章号的章，按顺序补上「第N章」前缀。
   * 补了号的章才能插到正确位置、进缺章报告；读不出的只能追加在末尾。
   */
  private static applyNumbers(chapters: ParsedChapter[], numbers: number[]): void {
    if (numbers.length === 0) {
      return;
    }
    let k = 0;
    for (let i = 0; i < chapters.length && k < numbers.length; i++) {
      if (WebToBook.chapterNumber(chapters[i].title) > 0) {
        continue;
      }
      const n = Math.floor(numbers[k]);
      k++;
      if (n > 0) {
        chapters[i].title = chapters[i].title.length > 0 ? `第${n}章 ${chapters[i].title}` : `第${n}章`;
      }
    }
  }

  /** 0..n-1 的页序数组（单页来源切章时用） */
  private static rangeOf(n: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < n; i++) {
      out.push(0);
    }
    return out;
  }

  /** 待入库落盘：序列化 + 边车（带章节清单） */
  private static async writePending(ctx: common.UIAbilityContext, title: string, author: string,
    info: string, sourceUrl: string, chapters: ParsedChapter[],
    onProgress: (msg: string) => void): Promise<PendingItem> {
    const list: WebChapter[] = [];
    let chars = 0;
    const refs: ChapterRef[] = [];
    for (let i = 0; i < chapters.length; i++) {
      list.push({
        title: chapters[i].title,
        paragraphs: chapters[i].paragraphs,
        url: BookMerge.urlOf(chapters[i])
      });
      refs.push({
        no: WebToBook.chapterNumber(chapters[i].title),
        title: chapters[i].title,
        url: BookMerge.urlOf(chapters[i])
      });
      for (let p = 0; p < chapters[i].paragraphs.length; p++) {
        chars += runsToPlainText(chapters[i].paragraphs[p].runs).length;
      }
    }
    const html = WebToBook.buildHtml(title, list);
    const dir = `${ctx.cacheDir}/finder_dl`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const path = `${dir}/merge_${Date.now()}.html`;
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, html);
    } finally {
      fs.closeSync(f);
    }
    const meta: FicMeta = {
      title: title,
      author: author,
      chapters: list.length,
      words: chars,
      info: info,
      epubUrl: '',
      sourceUrl: sourceUrl
    };
    return PendingStore.save(ctx, meta, path, refs);
  }

  /**
   * 按章号找空洞：「目录显示 170 章、应为 172」时直接报出缺哪几章。
   * 只在八成以上章读得出章号时才算——否则全是误报。最多列 15 个，防刷屏。
   */
  static gapNote(titles: string[]): string {
    const nos: number[] = [];
    let numbered = 0;
    for (let i = 0; i < titles.length; i++) {
      const n = WebToBook.chapterNumber(titles[i]);
      if (n > 0) {
        nos.push(n);
        numbered++;
      }
    }
    if (nos.length === 0 || numbered < Math.ceil(titles.length * 0.8)) {
      return '';
    }
    const set = new Set<number>();
    let max = 0;
    for (let i = 0; i < nos.length; i++) {
      set.add(nos[i]);
      if (nos[i] > max) {
        max = nos[i];
      }
    }
    const missing: number[] = [];
    for (let i = 1; i <= max && missing.length < 15; i++) {
      if (!set.has(i)) {
        missing.push(i);
      }
    }
    if (missing.length === 0) {
      return '';
    }
    return `按章号看缺：${missing.join('、')}（共 ${missing.length} 章）`;
  }

  // ---------- 旧版整本合并（兼容入口，走同一套 normalize + writePending） ----------

  static async merge(ctx: common.UIAbilityContext, items: PendingItem[],
    title: string, author: string, onProgress: (msg: string) => void): Promise<MergeOutcome> {
    const all: ParsedChapter[] = [];
    for (let i = 0; i < items.length; i++) {
      onProgress(`正在读取第 ${i + 1}/${items.length} 本：《${items[i].title}》…`);
      const parsed = await BookMerge.parseItem(ctx, items[i]);
      BookMerge.joinUrls(items[i], parsed);
      for (let c = 0; c < parsed.chapters.length; c++) {
        all.push(parsed.chapters[c]);
      }
      Log.i(`合并读取：《${items[i].title}》${parsed.chapters.length} 章`);
    }
    if (all.length === 0) {
      throw new Error('这几本都没解析出章节，无法合并');
    }
    const norm = BookMerge.normalize(all);
    onProgress('正在合成一本…');
    const workTitle = title.length > 0 ? title : items[0].title;
    const workAuthor = author.length > 0 ? author : items[0].author;
    const item = await BookMerge.writePending(ctx, workTitle, workAuthor,
      `合并 ${items.length} 本${norm.dropped > 0 ? ` · 去掉 ${norm.dropped} 章重复` : ''}`,
      items[0].sourceUrl, norm.chapters, onProgress);
    const stats: MergeStats = {
      chapters: norm.chapters.length,
      dropped: norm.dropped,
      ordered: norm.ordered,
      sources: items.length,
      firstTitle: norm.chapters[0].title,
      lastTitle: norm.chapters[norm.chapters.length - 1].title
    };
    Log.i(`合并完成：《${workTitle}》${items.length} 本 → ${norm.chapters.length} 章（去重 ${norm.dropped}，重排 ${norm.ordered}）`);
    return { item: item, stats: stats };
  }

  /** 按扩展名选解析器，与导入管线同一套（.epub 也能合并，比如 FicHub 下来的书） */
  private static async parseItem(ctx: common.UIAbilityContext, item: PendingItem): Promise<ParsedWork> {
    const lower = item.epubPath.toLowerCase();
    const slash = item.epubPath.lastIndexOf('/');
    const fileName = slash >= 0 ? item.epubPath.substring(slash + 1) : item.epubPath;
    if (lower.endsWith('.epub')) {
      const stamp = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
      const extractDir = `${ctx.cacheDir}/merge_${stamp}`;
      try {
        return await EpubParser.parse(item.epubPath, extractDir);
      } finally {
        try {
          if (fs.accessSync(extractDir)) {
            fs.rmdirSync(extractDir);
          }
        } catch (e) {
          Log.w('清理解压目录失败');
        }
      }
    }
    if (lower.endsWith('.txt')) {
      return await TxtParser.parse(item.epubPath, fileName);
    }
    return await HtmlFileParser.parse(item.epubPath, fileName);
  }

  /** 去重键：标题归一化；标题为空退化成正文前 120 字 */
  private static chapterKey(ch: ParsedChapter): string {
    const t = Dedupe.norm(ch.title);
    if (t.length > 0) {
      return `t:${t}`;
    }
    let sample = '';
    for (let i = 0; i < ch.paragraphs.length && sample.length < 120; i++) {
      sample += runsToPlainText(ch.paragraphs[i].runs);
    }
    const s = Dedupe.norm(sample);
    return s.length > 0 ? `c:${s.substring(0, 120)}` : '';
  }
}
