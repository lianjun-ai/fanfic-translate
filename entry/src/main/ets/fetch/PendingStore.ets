import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FicHub, FicMeta } from './FicHub';
import { Log } from '../common/Logger';

/**
 * 待入库区：智能检索下载的 EPUB 先落在这里，不进书架。
 *
 * 设计要点：
 * - 目录用 filesDir 而不是 cacheDir：cacheDir 可能被系统清理，
 *   用户"先攒着回头再看"的预期不能靠运气。
 * - 每本 EPUB 配一个同名 .json 边车文件存元信息（标题/作者/来源链接），
 *   重启应用后列表还能完整展示。
 * - 不设数量上限：以前会在超出 12 本时静默淘汰最旧的，用户会莫名其妙
 *   发现书没了。现在要腾空间由用户自己在列表里移除。
 */

/** 章节清单里的一条：章号 + 标题 + 来源网页 */
export interface ChapterRef {
  /** 章标题里的序号（读不出为 0） */
  no: number;
  title: string;
  url: string;
}

/** 待入库条目（边车 JSON 的结构） */
export interface PendingItem {
  title: string;
  author: string;
  chapters: number;
  words: number;
  /** FicHub 原样返回的状态行 */
  info: string;
  /** 源站作品页地址 */
  sourceUrl: string;
  /** EPUB 在沙箱里的绝对路径 */
  epubPath: string;
  savedAt: number;
  /**
   * 每章的标题与来源链接（按书的顺序）。旧边车没有这个字段（undefined），
   * 一切相关逻辑都要按「没有就降级」处理，不阻断主流程。
   */
  chapterIndex?: ChapterRef[];
  /**
   * 抓取失败、还没有拿到正文的章节链接（跨回合续跑的依据）：
   * 模型 check_pending 查到它，就能在下个回合用 add_chapters 补抓，
   * 不用靠对话记忆记住哪几页失败。补上的链接会被移除。旧边车缺省。
   */
  failedUrls?: string[];
}

export class PendingStore {
  private static dirOf(ctx: common.UIAbilityContext): string {
    return `${ctx.filesDir}/pending_epub`;
  }

  /**
   * EPUB 已由调用方下载好，这里把它搬进待入库目录并补边车。
   *
   * 关键点：下载产物原本落在 cacheDir（FicHub.downloadEpub 的落点），
   * 而 cacheDir 会被系统随时清理，list() 又只扫 filesDir —— 如果只写
   * 边车不搬文件，待入库列表永远是空的。所以这里必须 copy 进 filesDir。
   */
  static async save(ctx: common.UIAbilityContext, meta: FicMeta, epubPath: string,
    chapterIndex?: ChapterRef[], failedUrls?: string[]): Promise<PendingItem> {
    const dir = PendingStore.dirOf(ctx);
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const dest = `${dir}/${Date.now()}_${FicHub.fileSafeName(meta.title)}${PendingStore.extOf(epubPath)}`;
    if (epubPath !== dest) {
      fs.copyFileSync(epubPath, dest);
      try {
        fs.unlinkSync(epubPath);
      } catch (e) {
        // 临时文件删不掉不影响入库，交给系统清 cacheDir
      }
    }
    const item: PendingItem = {
      title: meta.title,
      author: meta.author,
      chapters: meta.chapters,
      words: meta.words,
      info: meta.info,
      sourceUrl: meta.sourceUrl,
      epubPath: dest,
      savedAt: Date.now()
    };
    if (chapterIndex !== undefined && chapterIndex.length > 0) {
      item.chapterIndex = chapterIndex;
    }
    if (failedUrls !== undefined && failedUrls.length > 0) {
      item.failedUrls = failedUrls;
    }
    const sidecar = `${dest}.json`;
    const f = fs.openSync(sidecar, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, JSON.stringify(item));
    } finally {
      fs.closeSync(f);
    }
    Log.i(`待入库：《${item.title}》${dest}`);
    return item;
  }

  /** 保留源文件的扩展名（.epub / .txt），认不出就按 epub 处理 */
  private static extOf(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.txt')) {
      return '.txt';
    }
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return '.html';
    }
    return '.epub';
  }

  /** 重启后也能列出；EPUB 已丢失的条目顺手清掉 */
  static async list(ctx: common.UIAbilityContext): Promise<PendingItem[]> {
    const dir = PendingStore.dirOf(ctx);
    if (!fs.accessSync(dir)) {
      return [];
    }
    const names: string[] = fs.listFileSync(dir);
    const items: PendingItem[] = [];
    for (let i = 0; i < names.length; i++) {
      if (!names[i].endsWith('.json')) {
        continue;
      }
      const sidecar = `${dir}/${names[i]}`;
      try {
        const item = JSON.parse(fs.readTextSync(sidecar)) as PendingItem;
        if (!fs.accessSync(item.epubPath)) {
          fs.unlinkSync(sidecar);
          continue;
        }
        items.push(item);
      } catch (e) {
        Log.w(`待入库条目损坏，跳过：${sidecar}`);
      }
    }
    items.sort((a: PendingItem, b: PendingItem) => b.savedAt - a.savedAt);
    return items;
  }

  /** 入库成功或用户放弃时删除 EPUB 与边车 */
  static async remove(ctx: common.UIAbilityContext, item: PendingItem): Promise<void> {
    try {
      fs.unlinkSync(item.epubPath);
    } catch (e) {
      // 文件可能已经不在了，忽略
    }
    try {
      fs.unlinkSync(`${item.epubPath}.json`);
    } catch (e) {
      // 同上
    }
  }
}
