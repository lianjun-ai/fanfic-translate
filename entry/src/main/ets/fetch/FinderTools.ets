import { fileIo as fs } from '@kit.CoreFileKit';
import { ToolDef } from '../provider/LlmProvider';
import { FicHub, FicMeta, ProbeResult } from './FicHub';
import { HttpFetch } from './HttpFetch';
import { WebChapter, WebPageFetched, WebToBook } from './WebToBook';
import { PendingItem, PendingStore } from './PendingStore';
import { Tavily, TavilyHit } from './Tavily';
import { WebPage, PageResult } from './WebPage';
import { FinderCtx, MAX_ROUNDS, ROUNDS_WARN_AT } from './FinderTypes';
import { Log } from '../common/Logger';

/**
 * 找文 Agent 的工具箱。
 *
 * 设计原则：每个工具是一个**能力**，不是一个**步骤**。
 * 工具描述里写清「能做什么」和「代价多大」，让模型自己决定怎么组合，
 * 而不是由我们规定"必须先探测再下载"这类流程。
 *
 * 能力边界：
 * - web_search    发现线索（便宜）
 * - fetch_page    自己看网页内容（便宜，能判断链接是不是目标作品）
 * - fichub_get    把作品页变成 EPUB 放进待入库区（英文同文库一步到位）
 * - html_to_book  把静态网页（单页或多页连载）抓成本地书（FicHub 不支持的站点的兜底路）
 * - download_file 直接下载任意文件（便宜，适合已经拿到直链）
 *
 * FicHub 只是其中一个可选工具 —— 模型完全可以只用 download_file 拿直链，
 * 或者在 FicHub 限流时改用别的路径。
 *
 * 不设下载数量上限：下多少本由用户和模型的对话决定，需要清理时用户
 * 自己在待入库区移除。唯一的预算是单回合步数（见 FinderTypes.MAX_ROUNDS）。
 */

/**
 * 工具回填里的预算字段：让模型看得见自己还剩几步。
 *
 * 之前模型对预算完全无感知，只能闷头往前跑，撞到 MAX_ROUNDS 才被硬截断，
 * 用户看到的就是「步数用完了」加一句兜底文案。把剩余量随每次工具返回
 * 告诉它，它才能自己安排收敛节奏。
 */
interface Budget {
  /** 这次工具执行完之后还剩几步 */
  steps_left: number;
  /** 只在步数偏紧时非空：一句提醒，让模型开始收尾 */
  hint: string;
}

/** 工具统一回填格式（定长结构，字段含义靠 status 区分） */
interface ToolReply {
  status: string;
  note: string;
  title: string;
  author: string;
  chapters: number;
  words: number;
  path: string;
  steps_left: number;
  hint: string;
}

interface SearchReply {
  status: string;
  count: number;
  note: string;
  results: TavilyHit[];
  steps_left: number;
  hint: string;
}

interface PageReply {
  status: string;
  http_status: number;
  title: string;
  text: string;
  truncated: boolean;
  note: string;
  steps_left: number;
  hint: string;
}

/** 一次回合里工具执行的可变状态 */
export interface FinderState {
  hits: FicMeta[];
  downloaded: PendingItem[];
  /** 已确认可转换的 url → 元信息，convert 复用，避免重复请求 FicHub */
  probed: Record<string, FicMeta>;
  /** 当前是第几轮（由主循环每轮开头写入），工具据此算出还剩几步 */
  round: number;
}

export class FinderTools {
  static newState(): FinderState {
    return { hits: [], downloaded: [], probed: {}, round: 0 };
  }

  /**
   * 预算快照：剩余步数 + 收敛提示。
   *
   * steps_left 的算法是 MAX_ROUNDS - round：本轮已经消耗掉了，剩下的是
   * 还能再请求模型的次数。剩 3 步开始催收尾，剩 0 步就明确要求别再调工具。
   */
  private static budget(st: FinderState): Budget {
    const left = MAX_ROUNDS - st.round;
    let hint = '';
    if (left <= 0) {
      hint = '步数已用尽，不要再调用任何工具，立刻把手上已有的结果整理成最终回复交给用户。';
    } else if (left <= ROUNDS_WARN_AT) {
      hint = `只剩 ${left} 步，不要再开新线索了：优先把已确认的作品拿到手，然后收尾。`;
    }
    return { steps_left: left, hint: hint };
  }

  /** 工具清单：描述里只讲能力和代价，不讲流程 */
  static defs(): ToolDef[] {
    const searchParams: Object = JSON.parse(
      '{"type":"object","properties":{"query":{"type":"string","description":"搜索词"},"max_results":{"type":"integer","description":"返回条数，默认 8"}},"required":["query"]}');
    const pageParams: Object = JSON.parse(
      '{"type":"object","properties":{"url":{"type":"string","description":"要读取的网页地址"},"max_chars":{"type":"integer","description":"正文最多保留多少字符，默认 4000"}},"required":["url"]}');
    const urlParams: Object = JSON.parse(
      '{"type":"object","properties":{"url":{"type":"string","description":"作品页地址"}},"required":["url"]}');
    const dlParams: Object = JSON.parse(
      '{"type":"object","properties":{"url":{"type":"string","description":"文件直链"},"title":{"type":"string","description":"作品名，不填就用文件名"},"author":{"type":"string","description":"作者"}},"required":["url"]}');

    const webSearch: ToolDef = {
      type: 'function',
      function: {
        name: 'web_search',
        description: '联网搜索，返回网页标题、链接与摘要。成本很低。搜索结果只是摘要，想确认内容可以再用 fetch_page 打开',
        parameters: searchParams
      }
    };
    const fetchPage: ToolDef = {
      type: 'function',
      function: {
        name: 'fetch_page',
        description: '打开一个网页并读它的可见正文（脚本样式会被去掉，长页面截断）。用来确认某个链接是不是那篇文、看章节数量、读推荐榜单',
        parameters: pageParams
      }
    };
    const probe: ToolDef = {
      type: 'function',
      function: {
        name: 'fichub_get',
        description: '把作品页变成 EPUB 并放进待入库区（用户确认后才进书架）。一步到位：先花十几秒问 FicHub 有没有缓存，命中就直接取；没命中会继续等它现场抓源站转换，可能一两分钟。站点不在支持范围或被限流时失败并说明原因',
        parameters: urlParams
      }
    };
    const download: ToolDef = {
      type: 'function',
      function: {
        name: 'download_file',
        description: '直接下载任意 URL 上的文件。EPUB/TXT 会自动放进待入库区（书名取 title 参数或文件名），其它格式只落到本地并返回路径',
        parameters: dlParams
      }
    };
    const webBook: ToolDef = {
      type: 'function',
      function: {
        name: 'html_to_book',
        description: '把网页抓成本地书放进待入库区（FicHub 不支持的站点的兜底路，如 LOFTER、晋江免费章节、博客、论坛帖子串）。urls 按阅读顺序传数组，每个网页合成一章；只抓一个网页时也可以只传一个元素的数组。只对「网页源码里就有正文」的静态页面有效，需要登录、JS 动态渲染或强反爬的页面会抓不到正文而失败',
        parameters: JSON.parse(
          '{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"},"description":"按阅读顺序排列的网页地址，1~30 个"},"title":{"type":"string","description":"书名，不填就用第一个网页的标题"},"author":{"type":"string","description":"作者"}},"required":["urls"]}')
      }
    };
    return [webSearch, fetchPage, probe, webBook, download];
  }

  /** 执行一次工具调用，返回喂回模型的 JSON */
  static async run(name: string, args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    if (name === 'web_search') {
      return FinderTools.webSearch(args, ctx, st);
    }
    if (name === 'fetch_page') {
      return FinderTools.fetchPage(args, ctx, st);
    }
    if (name === 'fichub_get') {
      return FinderTools.fichubGet(args, ctx, st);
    }
    if (name === 'html_to_book') {
      return FinderTools.htmlToBook(args, ctx, st);
    }
    if (name === 'download_file') {
      return FinderTools.downloadFile(args, ctx, st);
    }
    return FinderTools.reply('bad_tool', `没有名为 ${name} 的工具`, null, '', st);
  }

  private static async webSearch(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const q = FinderTools.str(args, 'query');
    if (q.length === 0) {
      return FinderTools.reply('bad_args', '缺少 query 参数', null, '', st);
    }
    const limit = FinderTools.int(args, 'max_results', 8);
    ctx.hooks.onAction(`🔍 搜索：${q}`);
    ctx.hooks.onStatus(`正在搜索：${q}`);
    try {
      const found = await Tavily.search(ctx.cfg.searchKey, q, limit);
      ctx.hooks.onAction(`　　${found.length} 条结果`);
      const b = FinderTools.budget(st);
      const reply: SearchReply = {
        status: 'ok',
        count: found.length,
        note: found.length === 0 ? '没有搜到结果，换个关键词或角度试试' : '',
        results: found,
        steps_left: b.steps_left,
        hint: b.hint
      };
      return JSON.stringify(reply);
    } catch (e) {
      const why = (e as Error).message;
      ctx.hooks.onAction(`　　搜索失败：${why}`);
      const bf = FinderTools.budget(st);
      const reply: SearchReply = {
        status: 'fail', count: 0, note: why, results: [],
        steps_left: bf.steps_left,
        hint: bf.hint
      };
      return JSON.stringify(reply);
    }
  }

  private static async fetchPage(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    if (url.length === 0) {
      return FinderTools.reply('bad_args', '缺少 url 参数', null, '', st);
    }
    const maxChars = FinderTools.int(args, 'max_chars', 4000);
    ctx.hooks.onAction(`🌐 读取：${url}`);
    const page: PageResult = await WebPage.read(url, maxChars);
    const pb = FinderTools.budget(st);
    const reply: PageReply = {
      status: page.ok ? 'ok' : 'fail',
      http_status: page.status,
      title: page.title,
      text: page.text,
      truncated: page.truncated,
      note: page.ok ? (page.truncated ? `正文超过 ${maxChars} 字符，已截断` : '') : page.note,
      steps_left: pb.steps_left,
      hint: pb.hint
    };
    ctx.hooks.onAction(page.ok ? `　　已读取「${page.title.length > 0 ? page.title : url}」` : `　　读取失败：${page.note}`);
    return JSON.stringify(reply);
  }

  /**
   * 取书：一次调用走完全程。
   *
   * 以前是 probe + convert 两个工具，但它们打的是同一个接口
   * （GET /api/v0/epub 本身就是「转换并给出下载地址」），对模型是两步、
   * 对 FicHub 是一件事，还经常白跑一遍：
   * probe 超时（=没缓存、服务端还在抓）之后 convert 会把完全相同的请求重发一次。
   *
   * 现在合并成一步：
   *   1) 15 秒短探测 —— 命中缓存就立刻拿到元信息，省掉长等待
   *   2) 没命中就换长超时再等同一个 URL —— 这一等是必须的，
   *      因为服务端确实在抓，不是我们的请求有问题
   *   3) 拿到 epub_url 就下载、落进待入库区
   */
  private static async fichubGet(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    if (url.length === 0) {
      return FinderTools.reply('bad_args', '缺少 url 参数', null, '', st);
    }
    // 已经下过的不要再来一次：重复请求既占磁盘，又直接加剧 FicHub 限流
    const already = await PendingStore.list(ctx.ui);
    for (let i = 0; i < already.length; i++) {
      if (already[i].sourceUrl === url) {
        const hit: FicMeta = {
          title: already[i].title, author: already[i].author, chapters: already[i].chapters,
          words: already[i].words, info: already[i].info, epubUrl: '', sourceUrl: url
        };
        ctx.hooks.onAction(`　　《${hit.title}》已经下过了，跳过重复下载`);
        return FinderTools.reply('ok', '这本之前已经下过了，就在待入库区，等用户点一下就进书架', hit,
          already[i].epubPath, st);
      }
    }
    let meta = st.probed[url];
    if (meta === undefined) {
      ctx.hooks.onAction(`🔎 探测：${url}`);
      ctx.hooks.onStatus('正在问 FicHub 能不能转换…');
      const r: ProbeResult = await FicHub.probeCache(url, 15000, ctx.ui);
      if (r.status === 'hit' && r.meta !== null) {
        meta = r.meta;
        const m = meta;
        ctx.hooks.onAction(`✅ 可转换：《${m.title}》${m.author} · ${m.chapters} 章 · ${m.words} 词`);
        ctx.hooks.onHit(m);
        st.probed[url] = m;
        st.hits.push(m);
      } else if (r.status === 'limited' || r.status === 'rejected') {
        // 限流和「站点不支持」都不值得再等，直接把原因交给模型换路子
        ctx.hooks.onAction(`　　${r.note}`);
        return FinderTools.reply(r.status, r.note, null, '', st);
      } else {
        // miss / error：多半是没缓存，FicHub 正在现场抓源站。同一个 URL 用长超时续等
        ctx.hooks.onAction(`　　未命中缓存（${r.note}），继续等 FicHub 现场转换…`);
        ctx.hooks.onStatus('FicHub 正在现场转换…（首次导出可能要一两分钟）');
        try {
          meta = await FicHub.fetchMeta(url, (m: string) => ctx.hooks.onStatus(m), ctx.ui);
        } catch (e) {
          const why = (e as Error).message;
          ctx.hooks.onAction(`　　FicHub 无法转换：${why}`);
          return FinderTools.reply('fail', why, null, '', st);
        }
        const m2 = meta;
        ctx.hooks.onAction(`✅ 转换成功：《${m2.title}》${m2.author} · ${m2.chapters} 章`);
        ctx.hooks.onHit(m2);
        st.probed[url] = m2;
        st.hits.push(m2);
      }
    }
    const m3 = meta;
    ctx.hooks.onStatus(`正在下载《${m3.title}》…`);
    try {
      const path = await FicHub.downloadEpub(ctx.ui, m3, (m: string) => ctx.hooks.onStatus(m));
      const item: PendingItem = await PendingStore.save(ctx.ui, m3, path);
      st.downloaded.push(item);
      ctx.hooks.onAction(`📥 已下载：《${m3.title}》（待入库）`);
      ctx.hooks.onDownloaded(item);
      return FinderTools.reply('ok', '已放进待入库区，用户确认后才会进书架', m3, item.epubPath, st);
    } catch (e) {
      const why = (e as Error).message;
      Log.e(`FicHub 转换下载失败：${why}`);
      ctx.hooks.onAction(`　　下载失败：${why}`);
      return FinderTools.reply('fail', `下载失败：${why}`, m3, '', st);
    }
  }

  private static async downloadFile(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    if (url.length === 0) {
      return FinderTools.reply('bad_args', '缺少 url 参数', null, '', st);
    }
    const titleArg = FinderTools.str(args, 'title');
    const authorArg = FinderTools.str(args, 'author');
    ctx.hooks.onAction(`⬇️ 下载：${url}`);
    ctx.hooks.onStatus('正在下载文件…');
    const res = await HttpFetch.toFile(url, `${ctx.ui.cacheDir}/finder_dl`);
    if (!res.ok) {
      ctx.hooks.onAction(`　　下载失败：${res.note}`);
      return FinderTools.reply('fail', res.note, null, '', st);
    }
    const kind = HttpFetch.extOf(url, res.contentType);
    if (kind.length === 0) {
      ctx.hooks.onAction(`　　已下载 ${res.bytes} 字节，但不是电子书格式`);
      return FinderTools.reply('saved',
        `文件已下载到本地，但格式不是 EPUB/TXT，没有放进待入库区（这是网页或其它文件）。如果这是网页，用 fetch_page 读它`,
        null, res.path, st);
    }
    const title = titleArg.length > 0 ? titleArg : FinderTools.baseName(res.path);
    const meta: FicMeta = {
      title: title,
      author: authorArg,
      chapters: 0,
      words: 0,
      info: '直接下载',
      epubUrl: url,
      sourceUrl: url
    };
    try {
      const item: PendingItem = await PendingStore.save(ctx.ui, meta, res.path);
      st.hits.push(meta);
      st.downloaded.push(item);
      ctx.hooks.onHit(meta);
      ctx.hooks.onAction(`📥 已下载：《${title}》（待入库）`);
      ctx.hooks.onDownloaded(item);
      return FinderTools.reply('ok', '已放进待入库区，用户确认后才会进书架', meta, item.epubPath, st);
    } catch (e) {
      const why = (e as Error).message;
      return FinderTools.reply('fail', `文件已下载但入库失败：${why}`, null, res.path, st);
    }
  }

  /**
   * 网页抓书：把一个或多个静态网页抓成本地书放进待入库区。
   *
   * 这是 FicHub 不支持站点（LOFTER、晋江免费章、博客、论坛等）的兜底路：
   * 走与本地 HTML 导入同一条解析管线抽正文，多页按顺序拼成多章。
   * 抓不到正文时把原因和替代方案（分享链接/复制正文）一起交给模型。
   */
  private static async htmlToBook(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const urls = FinderTools.urlList(args);
    if (urls.length === 0) {
      return FinderTools.reply('bad_args', '缺少 urls 参数（要抓的网页地址数组）', null, '', st);
    }
    if (urls.length > 30) {
      return FinderTools.reply('bad_args', `一次最多抓 30 个网页（收到 ${urls.length} 个），拆成几本书分次抓`, null, '', st);
    }
    // 与 fichub_get 相同的去重约定：sourceUrl 记第一个网页，重复请求直接命中
    const already = await PendingStore.list(ctx.ui);
    for (let i = 0; i < already.length; i++) {
      if (already[i].sourceUrl === urls[0]) {
        const hit: FicMeta = {
          title: already[i].title, author: already[i].author, chapters: already[i].chapters,
          words: already[i].words, info: already[i].info, epubUrl: '', sourceUrl: urls[0]
        };
        ctx.hooks.onAction(`　　《${hit.title}》已经下过了，跳过重复抓取`);
        return FinderTools.reply('ok', '这本之前已经抓过了，就在待入库区，等用户点一下就进书架', hit,
          already[i].epubPath, st);
      }
    }
    ctx.hooks.onAction(`📄 抓网页成书：${urls.length} 个页面`);
    const dir = `${ctx.ui.cacheDir}/finder_dl`;
    const pages: WebPageFetched[] = [];
    const failedNotes: string[] = [];
    let totalChars = 0;
    for (let i = 0; i < urls.length; i++) {
      ctx.hooks.onStatus(urls.length > 1 ? `正在抓取第 ${i + 1}/${urls.length} 页…` : '正在抓取网页…');
      const p = await WebToBook.fetchPage(urls[i], dir);
      if (p.ok) {
        pages.push(p);
        totalChars += p.chars;
        ctx.hooks.onAction(`　　第 ${i + 1} 页「${p.title.length > 0 ? p.title : urls[i]}」：约 ${p.chars} 字${p.note.length > 0 ? `（${p.note}）` : ''}`);
      } else {
        failedNotes.push(`第 ${i + 1} 个（${urls[i]}）：${p.note}`);
        ctx.hooks.onAction(`　　第 ${i + 1} 页抓取失败：${p.note}`);
      }
    }
    if (pages.length === 0) {
      const why = failedNotes.join('；');
      return FinderTools.reply('fail',
        `所有页面都没抓到正文。${why}。这类页面通常需要登录或是 JS 动态渲染（微博、小红书等），` +
        '可以建议用户：在浏览器里打开文章、等正文显示后把链接分享给本应用，或复制正文存成 TXT 从「导入本地文件」进来',
        null, '', st);
    }
    const titleArg = FinderTools.str(args, 'title');
    const workTitle = titleArg.length > 0 ? titleArg
      : (pages[0].title.length > 0 ? pages[0].title : '未命名作品');
    const authorArg = FinderTools.str(args, 'author');
    const chapters: WebChapter[] = [];
    for (let i = 0; i < pages.length; i++) {
      const p = pages[i];
      // 多页时每页一章，章名用页面标题；单页时章名就是书名
      const name = pages.length > 1
        ? (p.title.length > 0 ? p.title : `第 ${chapters.length + 1} 章`)
        : workTitle;
      chapters.push({ title: name, paragraphs: p.paragraphs });
    }
    const html = WebToBook.buildHtml(workTitle, chapters);
    const path = `${dir}/web_${Date.now()}.html`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, html);
    } finally {
      fs.closeSync(file);
    }
    const meta: FicMeta = {
      title: workTitle,
      author: authorArg,
      chapters: pages.length,
      words: totalChars,
      info: urls.length > 1 ? `网页抓取 · ${pages.length}/${urls.length} 页` : '网页抓取',
      epubUrl: '',
      sourceUrl: urls[0]
    };
    try {
      const item: PendingItem = await PendingStore.save(ctx.ui, meta, path);
      st.hits.push(meta);
      st.downloaded.push(item);
      ctx.hooks.onHit(meta);
      ctx.hooks.onAction(`📥 已抓成书：《${workTitle}》（待入库，${pages.length} 章）`);
      ctx.hooks.onDownloaded(item);
      const note = pages.length < urls.length
        ? `已放进待入库区（${urls.length - pages.length} 个页面抓取失败：${failedNotes.join('；')}）`
        : '已放进待入库区，用户确认后才会进书架';
      return FinderTools.reply('ok', note, meta, item.epubPath, st);
    } catch (e) {
      const why = (e as Error).message;
      return FinderTools.reply('fail', `网页已抓取但入库失败：${why}`, null, path, st);
    }
  }

  private static reply(status: string, note: string, meta: FicMeta | null, path: string, st: FinderState): string {
    const b = FinderTools.budget(st);
    const r: ToolReply = {
      status: status,
      note: note,
      title: meta === null ? '' : meta.title,
      author: meta === null ? '' : meta.author,
      chapters: meta === null ? 0 : meta.chapters,
      words: meta === null ? 0 : meta.words,
      path: path,
      steps_left: b.steps_left,
      hint: b.hint
    };
    return JSON.stringify(r);
  }

  private static str(args: Record<string, Object>, key: string): string {
    const v = args[key];
    return typeof v === 'string' ? v.trim() : '';
  }

  private static int(args: Record<string, Object>, key: string, def: number): number {
    const v = args[key];
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      const n = parseInt(v, 10);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
    return def;
  }

  /** 从参数里取 URL 列表：urls 数组优先，兼容模型把单个地址塞进 url 字段 */
  private static urlList(args: Record<string, Object>): string[] {
    const out: string[] = [];
    const v = args['urls'];
    if (Array.isArray(v)) {
      const arr = v as string[];
      for (let i = 0; i < arr.length; i++) {
        const e = arr[i];
        if (typeof e === 'string' && e.trim().length > 0) {
          out.push(e.trim());
        }
      }
    }
    if (out.length === 0) {
      const one = FinderTools.str(args, 'url');
      if (one.length > 0) {
        out.push(one);
      }
    }
    return out;
  }

  private static baseName(path: string): string {
    const slash = path.lastIndexOf('/');
    let name = slash >= 0 ? path.substring(slash + 1) : path;
    const dot = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    return name.length > 0 ? name : '未命名作品';
  }
}
