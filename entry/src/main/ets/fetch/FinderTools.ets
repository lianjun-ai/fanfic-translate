import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ToolDef } from '../provider/LlmProvider';
import { FicHub, FicMeta, ProbeResult } from './FicHub';
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
 * - fichub_get    把作品页变成 EPUB 放进待入库区（一步到位，内部先短超时探缓存、没命中就续等现场转换）
 * - download_file 直接下载任意文件（便宜，适合已经拿到直链）
 *
 * FicHub 只是其中一个可选工具 —— 模型完全可以只用 download_file 拿直链，
 * 或者在 FicHub 限流时改用别的路径。
 *
 * 不设下载数量上限：下多少本由用户和模型的对话决定，需要清理时用户
 * 自己在待入库区移除。唯一的预算是单回合步数（见 FinderTypes.MAX_ROUNDS）。
 */

/** 一次回合里工具执行的可变状态 */
export interface FinderState {
  hits: FicMeta[];
  downloaded: PendingItem[];
  /** 已确认可转换的 url → 元信息，convert 复用，避免重复请求 FicHub */
  probed: Record<string, FicMeta>;
  /** 当前是第几轮（由主循环每轮开头写入），工具据此算出还剩几步 */
  round: number;
}

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

interface DlResult {
  ok: boolean;
  path: string;
  contentType: string;
  bytes: number;
  note: string;
}

const UA: string = 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';
/** 单文件下载上限，超过直接拒绝（同人文 EPUB 通常几 MB） */
const MAX_DOWNLOAD_BYTES: number = 60 * 1024 * 1024;

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
    return [webSearch, fetchPage, probe, download];
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
    const res = await FinderTools.fetchFile(url, ctx);
    if (!res.ok) {
      ctx.hooks.onAction(`　　下载失败：${res.note}`);
      return FinderTools.reply('fail', res.note, null, '', st);
    }
    const kind = FinderTools.extOf(url, res.contentType);
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

  /** 通用文件下载：落到临时目录，由调用方决定是否入库 */
  private static async fetchFile(url: string, ctx: FinderCtx): Promise<DlResult> {
    const dir = `${ctx.ui.cacheDir}/finder_dl`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': '*/*', 'User-Agent': UA };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 120000
      };
      const resp = await req.request(url, options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return { ok: false, path: '', contentType: '', bytes: 0, note: `HTTP ${resp.responseCode}` };
      }
      const buf = resp.result as ArrayBuffer;
      if (buf.byteLength === 0) {
        return { ok: false, path: '', contentType: '', bytes: 0, note: '下载到的文件是空的' };
      }
      if (buf.byteLength > MAX_DOWNLOAD_BYTES) {
        return { ok: false, path: '', contentType: '', bytes: buf.byteLength, note: '文件超过 60MB，已放弃' };
      }
      const ct = FinderTools.headerOf(resp, 'content-type');
      const ext = FinderTools.extOf(url, ct);
      const path = `${dir}/dl_${Date.now()}_${buf.byteLength}.${ext.length > 0 ? ext : 'bin'}`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      Log.i(`直接下载完成：${path}（${buf.byteLength} 字节，${ct}）`);
      return { ok: true, path: path, contentType: ct, bytes: buf.byteLength, note: '' };
    } catch (e) {
      const raw = (e as Error).message;
      const timeout = raw.includes('timeout') || raw.includes('Timeout');
      return { ok: false, path: '', contentType: '', bytes: 0, note: timeout ? '下载超时' : `网络错误：${raw}` };
    } finally {
      req.destroy();
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

  private static headerOf(resp: http.HttpResponse, key: string): string {
    try {
      const h = JSON.parse(JSON.stringify(resp.header)) as Record<string, string>;
      const keys = Object.keys(h);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === key) {
          return h[keys[i]];
        }
      }
    } catch (e) {
      Log.d('响应头解析失败');
    }
    return '';
  }

  /** 从 URL 或 Content-Type 推断电子书格式，认不出返回空串 */
  private static extOf(url: string, contentType: string): string {
    const lower = url.toLowerCase();
    const q = lower.indexOf('?');
    const clean = q >= 0 ? lower.substring(0, q) : lower;
    if (clean.endsWith('.epub')) {
      return 'epub';
    }
    if (clean.endsWith('.txt')) {
      return 'txt';
    }
    const ct = contentType.toLowerCase();
    if (ct.indexOf('epub') >= 0) {
      return 'epub';
    }
    if (ct.indexOf('text/plain') >= 0) {
      return 'txt';
    }
    return '';
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
