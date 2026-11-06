import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpFetch } from './HttpFetch';
import { HeadlessRenderer } from './HeadlessRenderer';
import { FileTextReader } from '../parser/FileTextReader';
import { HtmlNode, HtmlParser } from '../parser/HtmlParser';
import { XhtmlConverter } from '../parser/XhtmlConverter';
import { ParsedChapter, ParsedParagraph } from '../parser/ParserTypes';
import { ParaType, Run } from '../model/Models';
import { SiteRules } from './SiteRules';
import { SiteMirror } from './SiteMirror';
import { AntiBot } from './AntiBot';
import { Log } from '../common/Logger';

/** 单页正文字符上限：超过截断并提示，防止一个无限长页面撑爆一本书 */
const MAX_PAGE_CHARS: number = 200000;

/**
 * 空壳门限：直抓抽出的正文字数低于这个值，就当「这一页不是正文」处理。
 *
 * 真机踩过：B 站 /read/cv{id} 会 302 到 /read/mobile 的 JS 壳，正文由接口塞进
 * DOM，直抓只拿到「·　NaN-NaN-NaN NaN:NaN ·　--浏览　本文禁止转载或摘编」43 字。
 * 旧逻辑只看「段落数 > 0」，于是这 43 字被判成功，待入库区留下一个空壳书。
 * 与 fetch_page 的 SHELL_TEXT_CHARS 取同一个值，两个工具对「空壳」才是一个判据。
 */
const SHELL_TEXT_CHARS: number = 300;

/* （原 LOFTER 专用接口已迁移到 SiteRules 引擎：内置规则 + 用户可增删的规则表） */

/** capParagraphs 的返回 */
interface CappedParagraphs {
  list: ParsedParagraph[];
  chars: number;
  truncated: boolean;
}

/** 抓取结果（成功时 paragraphs 非空） */
export interface WebPageFetched {
  ok: boolean;
  note: string;
  title: string;
  paragraphs: ParsedParagraph[];
  chars: number;
  /** 实际抓取的地址（镜像/接口替换后的），章节来源链接的上游 */
  url: string;
}

/** 拼接用的一章 */
export interface WebChapter {
  title: string;
  paragraphs: ParsedParagraph[];
  /** 这一章的来源网页（切不出就空串）；补章/追更时靠它定位 */
  url: string;
}

/**
 * 网页 → 本地书。
 *
 * 与 fetch_page 的本质区别：fetch_page 是「读给你看」，这里是「收成一本」——
 * 走完整条正文抽取管线（和本地导入 HTML 同一套解析器），再序列化回带
 * <h1> 分章标记的合并文档，由 HtmlFileParser 在导入时拆成多章。
 *
 * 两级取正文：先直抓源码（便宜，覆盖静态页）；抽不到正文说明页面是
 * JS 动态渲染，自动降级到隐藏 ArkWeb 真渲染一次再抽（见 HeadlessRenderer）。
 * 仍拿不到（需要登录 / 强反爬）才报失败，由调用方建议用户走分享入口。
 */
export class WebToBook {
  /** 抓单个网页并抽取正文段落（直抓失败于空壳时自动用内置渲染重试） */
  static async fetchPage(url: string, tmpDir: string): Promise<WebPageFetched> {
    // 有些链接匿名访问只剩空壳，但同一内容有更好抓的等价地址（贴吧 /p/ →
    // wap 版只看楼主页）。这一步是确定性的，不交给模型去试。
    const target = SiteMirror.url(url);
    // 少数站的详情页只是个 JS 壳，正文只从自己的接口出（B 站专栏）。
    // 这种「页面地址 → 接口地址」的映射写死在这里，比让模型每次现探省好几步。
    const apiUrl = WebToBook.apiUrlFor(target);
    if (apiUrl.length > 0) {
      const viaApi = await WebToBook.fetchByApi(apiUrl, 'https://www.bilibili.com/');
      if (viaApi !== null) {
        Log.i(`站点接口直取成功：${target}`);
        return viaApi;
      }
      Log.w(`站点接口没取到正文，退回常规抓取：${target}`);
    }
    const res = await HttpFetch.toFile(target, tmpDir);
    if (!res.ok) {
      // 403 不一定等于「抓不到」：反爬挑战页（知乎 __zse_ck、Cloudflare 校验）
      // 要看浏览器执行完脚本、写完 Cookie 才会给出正文。直抓被拦时先让
      // 内置渲染器跑一次，它过不去再认输 —— 否则会把能抓的站判成死站。
      if (WebToBook.mayBeAntiBot(res.note)) {
        return await WebToBook.fetchAfterBlock(target, res.note);
      }
      return { ok: false, note: res.note, title: '', paragraphs: [], chars: 0, url: target };
    }
    let text = '';
    try {
      text = FileTextReader.read(res.path);
    } catch (e) {
      return { ok: false, note: `读取网页失败：${(e as Error).message}`, title: '', paragraphs: [], chars: 0, url: target };
    } finally {
      try {
        fs.unlinkSync(res.path);
      } catch (e) {
        // 临时文件删不掉不影响结果
      }
    }
    // 接口返回的 JSON：站点规则可以直接从 JSON 里取值（模型探通接口后写的
    // 「marker + json_content」规则就是为这种情况准备的）。先按规则试，再判死。
    const trimmed = text.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      const fromJson = WebToBook.processJson(text, target);
      if (fromJson !== null) {
        return fromJson;
      }
      return {
        ok: false, title: '', paragraphs: [], chars: 0, url: target,
        note: '这个地址返回的是接口数据（JSON），不是网页。正文就在这份 JSON 里：' +
          '用 manage_site_rules 写一条规则（marker 填 JSON 里的定位串，如 "data":；' +
          'json_content 填正文路径，如 data.content）再把这个接口地址交给 html_to_book；' +
          '或者直接改用文章网页地址'
      };
    }
    if (text.indexOf('<') < 0) {
      return { ok: false, note: '返回内容不是网页（可能被反爬拦截）', title: '', paragraphs: [], chars: 0, url: target };
    }
    const direct = WebToBook.processHtml(text, '', target);
    if (direct.ok) {
      return WebToBook.withPageHint(direct, text, target);
    }
    // 直抓空壳：多半是 JS 动态渲染，用隐藏 ArkWeb 真渲染一次
    const rendered = await WebToBook.renderFallback(target);
    if (rendered !== null) {
      return rendered;
    }
    return direct;
  }

  /**
   * 给抓取结果补一句分页线索（贴吧这类多页帖子）。
   * 模型拿到「共几页、下一批 pn 怎么给」就不用自己试探翻页参数了。
   */
  private static withPageHint(out: WebPageFetched, html: string, url: string): WebPageFetched {
    const hint = SiteMirror.paginationHint(html, url);
    if (hint.length === 0) {
      return out;
    }
    return {
      ok: out.ok,
      note: out.note.length > 0 ? `${out.note}；${hint}` : hint,
      title: out.title, paragraphs: out.paragraphs, chars: out.chars, url: out.url
    };
  }

  /** toFile 的失败说明形如 "HTTP 403"：只对可能被风控拦的码放行一次渲染 */
  private static mayBeAntiBot(note: string): boolean {    const m = /HTTP (\d{3})/.exec(note);
    if (m === null || m.length < 2) {
      return false;
    }
    const code = parseInt(m[1], 10);
    return code === 401 || code === 403 || code === 405 || code === 406 ||
      code === 429 || code === 451 || code === 500 || code === 502 || code === 503;
  }

  /**
   * 页面地址 → 接口地址。目前只有 B 站需要：
   * /read/cv{id} 现在会 302 到 /read/mobile 的 JS 壳，直抓只剩几十字占位；
   * 免登录能拿到全文的是 api.bilibili.com/x/article/view?id={id}（真机已验证）。
   */
  private static apiUrlFor(url: string): string {
    const m = /bilibili\.com\/read\/cv(\d+)/.exec(url);
    if (m === null || m.length < 2) {
      return '';
    }
    return `https://api.bilibili.com/x/article/view?id=${m[1]}`;
  }

  /** 抓接口地址并按站点规则（JSON 路径）取正文；取不到返回 null，交给常规流程 */
  private static async fetchByApi(apiUrl: string, referer: string): Promise<WebPageFetched | null> {
    try {
      const res = await HttpFetch.getText(apiUrl, referer);
      if (!res.ok || res.text.length === 0) {
        return null;
      }
      return WebToBook.processJson(res.text, apiUrl);
    } catch (e) {
      Log.w(`接口直取异常：${(e as Error).message}`);
      return null;
    }
  }

  /** 直抓被拦后的第二跳：先小抓一次摸清是哪堵墙，再交给内置渲染 */
  private static async fetchAfterBlock(url: string, note: string): Promise<WebPageFetched> {
    const diag = await HttpFetch.getText(url, '');
    const block = AntiBot.detect(diag.text);
    Log.i(`网页直抓被拦（${note}，${block.length > 0 ? block : '未识别拦截页'}），改用内置渲染：${url}`);
    const rendered = await WebToBook.renderFallback(url);
    if (rendered !== null) {
      Log.i(`直抓被拦但渲染拿到正文：${url}（${rendered.chars} 字）`);
      return {
        ok: true, note: `直抓被拦（${note}），${rendered.note}`,
        title: rendered.title, paragraphs: rendered.paragraphs, chars: rendered.chars, url: url
      };
    }
    Log.w(`直抓与渲染都没拿到正文：${url}`);
    return {
      ok: false, note: `${note}${block.length > 0 ? `（${AntiBot.hint(block)}）` : ''}；内置浏览器渲染也没拿到正文`,
      title: '', paragraphs: [], chars: 0, url: url
    };
  }

  /** 用隐藏 ArkWeb 渲染后重新抽取；仍抽不到正文返回 null（沿用直抓的失败说明） */
  private static async renderFallback(url: string): Promise<WebPageFetched | null> {
    const res = await HeadlessRenderer.render(url);
    if (!res.ok) {
      Log.w(`内置渲染降级失败：${res.note}`);
      return null;
    }
    const out = WebToBook.processHtml(res.html, res.note.length > 0 ? res.note : '已用内置浏览器渲染；', url);
    if (!out.ok) {
      Log.w('内置渲染完成但未抽出正文');
      return null;
    }
    return out;
  }

  /**
   * 接口响应（JSON）→ 正文：靠站点规则取值。
   * 走的是和页面内嵌 JSON 同一套「marker + 点分路径」，只是这里 marker 可以很短
   * （接口返回里 "data": 往往只出现一次），模型探通接口后写一条规则即可复用。
   */
  private static processJson(text: string, url: string): WebPageFetched | null {
    const hit = SiteRules.extract(text, url);
    if (hit === null) {
      return null;
    }
    const title = hit.title.length > 0 ? WebToBook.cleanTitle(hit.title) : '';
    const polished = WebToBook.polish(hit.paragraphs, title);
    const list = polished.length > 0 ? polished : hit.paragraphs;
    const capped = WebToBook.capParagraphs(list);
    if (capped.chars < SHELL_TEXT_CHARS) {
      Log.w(`站点规则从 JSON 里只取到 ${capped.chars} 字，判为空结果：${url}`);
      return null;
    }
    Log.i(`站点规则从 JSON 接口取到正文：${url}（${capped.chars} 字）`);
    return {
      ok: true,
      note: `已按站点规则「${hit.rule.note}」从接口数据里提取正文`,
      title: title, paragraphs: capped.list, chars: capped.chars, url: url
    };
  }

  /** 解析 HTML 文本 → 标题 + 截断后的正文段落。prefix 拼在成功时的 note 前面。 */
  private static processHtml(text: string, notePrefix: string, url: string): WebPageFetched {
    // 站点规则优先：命中（内嵌 JSON 或 selector）就直接抽，不进通用解析
    const hit = SiteRules.extract(text, url);
    if (hit !== null) {
      // selector 规则只交代「正文在哪」，不负责书名 —— 标题仍按页面元信息取，
      // 免得给晋江、B站这类站硬编一个标题格式。
      const title = hit.title.length > 0 ? WebToBook.cleanTitle(hit.title)
        : WebToBook.pageTitle(HtmlParser.parse(text));
      const polished = WebToBook.polish(hit.paragraphs, title);
      const list = polished.length > 0 ? polished : hit.paragraphs;
      const capped = WebToBook.capParagraphs(list);
      const note = capped.truncated ? `${notePrefix}正文超过 ${MAX_PAGE_CHARS} 字，已截断` : notePrefix;
      return {
        ok: true, note: `${note}已按站点规则「${hit.rule.note}」提取正文`.trim(),
        title: title, paragraphs: capped.list, chars: capped.chars, url: url
      };
    }
    const root = HtmlParser.parse(text);
    const title = WebToBook.pageTitle(root);
    let paragraphs: ParsedParagraph[] = [];
    try {
      paragraphs = XhtmlConverter.toParagraphs(root);
    } catch (e) {
      // 解析器对某些页面结构抛异常时兜住，给出可读的失败原因而不是让整个工具调用崩掉
      Log.w(`正文抽取异常：${(e as Error).message}`);
      return {
        ok: false, title: title, paragraphs: [], chars: 0, url: url,
        note: `解析页面时出错：${(e as Error).message}`
      };
    }
    if (paragraphs.length > 0) {
      const polished = WebToBook.polish(paragraphs, title);
      if (polished.length > 0) {
        paragraphs = polished;
      }
    }
    if (paragraphs.length === 0) {
      return {
        ok: false, title: title, paragraphs: [], chars: 0, url: url,
        note: '页面里没有正文（需要登录才能看、内容主要是图片、或反爬拦截；JS 动态渲染的页面已自动用内置浏览器渲染过）'
          + WebToBook.embeddedStateHint(text) + WebToBook.weiboHint(text)
      };
    }
    const capped = WebToBook.capParagraphs(paragraphs);
    // 只抽到一点零碎（按钮、NaN 占位、版权行）= 壳页，不是正文。判失败，让
    // fetchPage 去降级渲染；渲染也拿不到时这一页才算真失败。
    if (capped.chars < SHELL_TEXT_CHARS) {
      Log.w(`直抓只抽到 ${capped.chars} 字，判为壳页：${url}`);
      return {
        ok: false, title: title, paragraphs: [], chars: 0, url: url,
        note: `${notePrefix}页面只抽到 ${capped.chars} 字，是壳页（正文由 JS 从接口取，源码里没有）`
          + WebToBook.embeddedStateHint(text) + WebToBook.weiboHint(text)
      };
    }
    const note = capped.truncated ? `${notePrefix}正文超过 ${MAX_PAGE_CHARS} 字，已截断` : notePrefix;
    return { ok: true, note: note, title: title, paragraphs: capped.list, chars: capped.chars, url: url };
  }

  /** 截断保护：单页正文字符超过 MAX_PAGE_CHARS 时停手 */
  private static capParagraphs(paragraphs: ParsedParagraph[]): CappedParagraphs {
    let chars = 0;
    const list: ParsedParagraph[] = [];
    let truncated = false;
    for (let i = 0; i < paragraphs.length; i++) {
      const p = paragraphs[i];
      let len = 0;
      for (let j = 0; j < p.runs.length; j++) {
        len += p.runs[j].text.length;
      }
      if (chars + len > MAX_PAGE_CHARS) {
        truncated = true;
        break;
      }
      list.push(p);
      chars += len;
    }
    return { list: list, chars: chars, truncated: truncated };
  }

  /**
   * 门户壳标题：SPA 详情页的 <title> 常常是站点品牌口号而非内容标题
   * （如 LOFTER 详情页固定为「LOFTER（乐乎） - 让兴趣，更有趣」），
   * 识别到就跳过，改用 og:title / 正文首个标题。
   */
  private static isShellTitle(t: string): boolean {
    return t.indexOf('让兴趣，更有趣') >= 0;
  }

  /** 站点名白名单：只有尾部片段正好是这些名字才当作站点后缀剥掉 */
  private static readonly SITE_NAMES: string[] = [
    '哔哩哔哩', 'bilibili', '知乎', '知乎专栏', '微博', 'lofter', '乐乎',
    '晋江文学城', '晋江', '豆瓣', '豆瓣读书', '小红书', '简书', '百度贴吧',
    '搜狐', '网易', '新浪', '腾讯', '今日头条', 'csdn', '博客园',
    'sf轻小说', '刺猬猫', '长佩文学', '番茄小说', '起点中文网'
  ];

  /** 页面标题：<title> → og:title → 首个标题，再过一遍 cleanTitle。debug_fetch 也用它，两处判词才一致 */
  static pageTitle(root: HtmlNode): string {
    let title = '';
    const titleNode = HtmlParser.findFirst(root, 'title');
    if (titleNode !== null) {
      title = XhtmlConverter.normalizeSpace(HtmlParser.textOf(titleNode));
    }
    if (title.length === 0 || WebToBook.isShellTitle(title)) {
      const og = WebToBook.metaContent(root, 'og:title');
      if (og.length > 0) {
        title = og;
      }
    }
    if (title.length === 0 || WebToBook.isShellTitle(title)) {
      title = XhtmlConverter.firstHeadingText(root);
    }
    return WebToBook.cleanTitle(title);
  }

  /** 标题定稿：先去站点自带的噪音，再去站点名后缀 */
  private static cleanTitle(raw: string): string {
    let t = XhtmlConverter.normalizeSpace(raw);
    // 站点常把时间戳塞进 <title>：
    // 「《嫁金钗》笑佳人　^第1章^ 最新更新:2025-12-27 21:22:21 晋江文学城」
    t = t.replace(/\s*最新更新\s*[:：].*$/, '');
    // 晋江用 ^第N章^ 把章名括起来，脱掉这层帽子更像书名/章名
    t = t.replace(/\^/g, '');
    return WebToBook.stripSiteSuffix(t);
  }

  /**
   * 去掉标题尾巴上的站点名：「鹤羽拂月 三日鹤 刀剑乱舞 - 哔哩哔哩」→「鹤羽拂月 三日鹤 刀剑乱舞」。
   * 只对白名单里的名字动手，避免把正文标题里的破折号（「他 - 最后一夜」）当分隔符。
   * 分隔符也接受纯空白：晋江的「… ^第1章^ 晋江文学城」中间只有空格。
   */
  static stripSiteSuffix(raw: string): string {
    let t = XhtmlConverter.normalizeSpace(raw);
    for (let round = 0; round < 2; round++) {
      const m = /^(.*\S)(?:\s*[-_|—–·]\s*|\s+)([^-_|—–·]{1,16})$/.exec(t);
      if (m === null) {
        break;
      }
      if (!WebToBook.isSiteName(WebToBook.flat(m[2]))) {
        break;
      }
      const head = m[1].trim();
      if (head.length < 2) {
        break;
      }
      t = head;
    }
    return t;
  }

  private static isSiteName(tail: string): boolean {
    for (let i = 0; i < WebToBook.SITE_NAMES.length; i++) {
      if (tail === WebToBook.SITE_NAMES[i]) {
        return true;
      }
    }
    return false;
  }

  /** 页面按钮/导航文字：短且精确等于这些词才算（严格相等，避免误删正文） */
  private static readonly UI_TOKENS: string[] = [
    '下载app', '打开app', 'app内打开', '用app打开', '前往app', '继续阅读', '阅读原文',
    '关注', '已关注', '取消关注', '点赞', '投币', '收藏', '已收藏', '分享', '转发',
    '评论', '举报', '返回', '更多', '展开', '收起', '展开全文', '查看全部', '查看更多',
    '上一篇', '下一篇', '目录', '设置', '网页链接', '复制链接', '扫一扫', '登录', '注册',
    '立即登录', '首页', '顶部', '到底了', '没有更多了', '长按识别',
    '关闭', '作品库', '繁体版', '全文阅读', '返回顶部', '加入书架',
    '回帖', '搜索', '跳页', '取消', '操作', '只看楼主', '收藏回复举报',
    '新浪微博', '腾讯微博', 'qq空间', '微信', '朋友圈'
  ];

  /** 论坛楼层壳：贴吧每层楼都重复「作者名 + 楼层 / 日期 / 操作 / 收藏 回复 举报」四件套。
   *  归一化后空白已去掉，所以「踮点灯 10 楼主」是「踮点灯10楼主」、「2019-3-4 10:30」
   *  是「2019-3-410:30」（正则回溯能拆开）。 */
  private static readonly FLOOR_OWNER: RegExp = /^.{0,20}\d{1,4}楼主$/;
  private static readonly FLOOR_PLAIN: RegExp = /^.{0,20}\d{1,4}楼$/;
  private static readonly FLOOR_DATE: RegExp =
    /^\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?(?:\d{1,2}:\d{2})?$/;

  /** 元信息行首：「作者：无曦玥」「出处： bilibili」——不是正文 */
  private static readonly META_PREFIX: RegExp =
    /^(作者|出处|来源|原文|原文链接|责编|编辑|审核|发布于|发表于|声明|版权|本文作者|文章作者|题图|封面)\s*[：:]/;

  /** 尾部区标记（比较时已去掉空白并转小写）：命中即截断，后面都是评论区/页脚 */
  private static readonly TAIL_MARKERS: string[] = [
    '热门评论', '热门话题', '本章评论', '章节评论', '发表评论', '网友评论',
    '以上显示的是最新的二十条评论', '相关推荐', '猜你喜欢', '展开阅读全文',
    '版权声明', '免责声明', '转载请注明', '本文链接', '本文来自'
  ];

  /**
   * 正文清洗：真实页面（尤其带 App 的移动端页面）会把按钮、导航、作者署名
   * 一起塞进正文容器。真机数据里 B 站专栏那本书第一屏是：
   * 「下载 App / <标题重复> / 无曦玥 / 关注 / 作者：无曦玥 / 网页链接 / 出处： bilibili」，
   * 1345 字里有几百字是这些东西。
   *
   * 三条严格判据（都要求「短」或「精确相等」），宁可漏删也不要误删正文：
   * ① 开头 6 段内与标题（含带站点后缀的写法）等价的 —— 标题重复；
   * ② 精确等于已知 UI 词；③ 「作者：」这类元信息行首；
   * ④ 相邻完全重复的短段；⑤ 论坛楼层壳（见 isForumFloor）。
   */
  static polish(paragraphs: ParsedParagraph[], title: string): ParsedParagraph[] {
    const out: ParsedParagraph[] = [];
    const tFull = WebToBook.flat(title);
    const tShort = WebToBook.flat(WebToBook.stripSiteSuffix(title));
    const limit = WebToBook.tailCutIndex(paragraphs);
    // 先算好每段的归一化文本：楼层壳要看「下一段是不是日期」这种跨段线索
    const norms: string[] = new Array<string>(limit);
    for (let i = 0; i < limit; i++) {
      norms[i] = paragraphs[i].type === ParaType.DIVIDER
        ? '' : WebToBook.flat(WebToBook.paragraphText(paragraphs[i]));
    }
    let prev = '';
    for (let i = 0; i < limit; i++) {
      const p = paragraphs[i];
      // &nbsp; 会留成 \u00a0：看着是空格，实际是一串非断空格，会把段落撑得很怪
      for (let j = 0; j < p.runs.length; j++) {
        const r = p.runs[j];
        r.text = r.text.replace(/[\u00a0\u3000]/g, ' ').replace(/ {2,}/g, ' ');
        // 贴在正文尾巴上的 App 推广（贴吧每页首楼都带「看高清大图，打开贴吧App」）
        r.text = r.text.replace(/看高清大图[，,]?\s*/g, '').replace(/打开贴吧\s*[Aa][Pp][Pp]/g, '');
      }
      if (p.runs.length > 0) {
        // 只在段落首尾去空白：逐个 run 去会吃掉行内样式之间的正常空格
        p.runs[0].text = p.runs[0].text.replace(/^\s+/, '');
        const lastIdx = p.runs.length - 1;
        p.runs[lastIdx].text = p.runs[lastIdx].text.replace(/\s+$/, '');
      }
      if (p.type === ParaType.DIVIDER) {
        out.push(p);
        prev = '';
        continue;
      }
      const raw = WebToBook.paragraphText(p);
      const norm = norms[i];
      if (norm.length === 0) {
        continue;
      }
      // 开头的标题重复。窗口给到 20 段：移动端页面在正文之前常有一串按钮/
      // 导航行，标题可能被挤到第 8 段之后（真机 B站 那本就是被 6 段窗口漏了）。
      // 三种等价形式都算：与标题完全相同、与「剥掉站名后的标题」相同、
      // 或者是标题的一大段子串（页面标题带副标题时，正文里的标题只有前半截）。
      if (i < 20 && WebToBook.isTitleEcho(norm, tFull, tShort)) {
        continue;
      }
      if (norm.length <= 14 && WebToBook.isUiToken(norm)) {
        continue;
      }
      if (WebToBook.META_PREFIX.test(raw.trim())) {
        continue;
      }
      if (WebToBook.isForumFloor(norm, i + 1 < limit ? norms[i + 1] : '')) {
        continue;
      }
      // 楼主更新时常常一次 @ 一串人，那是通知不是正文
      if (WebToBook.isMentionList(raw)) {
        continue;
      }
      if (norm === prev && norm.length <= 40) {
        continue;
      }
      prev = norm;
      out.push(p);
    }
    return out;
  }

  /**
   * 章节标题行：整段就是「第N章 藤鞭」「序章」「番外二」这类。
   * 只做整段匹配（不是 contains），正文里的「第一章里他……」不会被误判。
   */
  private static readonly CHAPTER_HEAD: RegExp =
    /^(?:序章|楔子|引子|尾声|后记|番外[一二三四五六七八九十百\d]{0,3}|第\s*[0-9一二三四五六七八九十百千零两]{1,6}\s*[章节回卷幕])(?:[\s:：·、\-—]+.{0,24})?$/;

  /**
   * 按文内标题切章。
   *
   * 网页分页是站方切的，和「章」不是一回事：贴吧一个帖子里塞好几章，一章
   * 的正文也会被页边界劈开（真机那本《时迹》就是这样：7 页里有「第二章
   * 藤鞭」这样的标题行，却按页切成了 7 章，标题还混在正文里）。
   * 所以先把所有页的段落拼成一条，再以标题行为边界切，标题行本身当章名。
   *
   * 标题少于两个就返回 null，交给调用方退回「一页一章」——散文、单章文本来
   * 就没有标题，硬切只会把文切碎。
   */
  /** 章节标题里的序号（「第十一章」→11）；取不到返回 0（序章、番外） */
  static chapterNumber(title: string): number {
    const m = /第\s*([0-9]{1,4}|[一二三四五六七八九十百千零两]{1,6})\s*[章节回卷幕]/.exec(title);
    if (m === null || m.length < 2) {
      return 0;
    }
    if (/^[0-9]+$/.test(m[1])) {
      return Number(m[1]);
    }
    return WebToBook.cnNumber(m[1]);
  }

  /** 中文数字转阿拉伯数字（只覆盖章节号这种小数字：一 ~ 九百九十九） */
  private static cnNumber(s: string): number {
    const digits: string = '零一二三四五六七八九';
    const units: string = '十百千';
    let section = 0;
    let num = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charAt(i);
      const d = c === '两' ? 2 : digits.indexOf(c);
      if (d >= 0) {
        num = d;
        continue;
      }
      const u = units.indexOf(c);
      if (u >= 0) {
        const mul = u === 0 ? 10 : (u === 1 ? 100 : 1000);
        section += (num === 0 ? 1 : num) * mul;
        num = 0;
      }
    }
    return section + num;
  }

  /**
   * 按文内标题切章。
   *
   * pageUrls / paraPage 是可选的来源追踪：paraPage[i] 是第 i 段来自第几页，
   * pageUrls 是每页实际抓取的地址。两样都给了，切出的每章就带上「来自哪个
   * 网页」—— 补章、追更、去重定位全靠这个链接，没有它章节和来源就断了。
   */
  static splitChapters(paragraphs: ParsedParagraph[], pageUrls: string[] = [],
    paraPage: number[] = []): WebChapter[] | null {
    const marks: number[] = [];
    const titles: string[] = [];
    for (let i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].type === ParaType.DIVIDER) {
        continue;
      }
      const t = WebToBook.paragraphText(paragraphs[i]).trim();
      if (t.length === 0 || t.length > 34) {
        continue;
      }
      if (!WebToBook.CHAPTER_HEAD.test(t)) {
        continue;
      }
      // 同一章被重复贴两遍（真机那帖的「第十一章」就是）：第二个标题不算新章，
      // 它的内容并进前一章，免得书架里出现两个同名章节
      if (titles.length > 0 && titles[titles.length - 1] === t) {
        continue;
      }
      marks.push(i);
      titles.push(t);
    }
    if (marks.length < 2) {
      return null;
    }
    // 序号校验。这个函数对**所有站点**生效（LOFTER 系列、晋江整本、博客长文
    // 都可能把几章塞在一页里），所以要防住「正文里提了一句第一章、第二章」
    // 这种假标题：真章节的序号一定递增，倒序/乱序就说明这不是章节结构。
    const nums: number[] = [];
    for (let k = 0; k < titles.length; k++) {
      const n = WebToBook.chapterNumber(titles[k]);
      if (n > 0) {
        nums.push(n);
      }
    }
    if (nums.length >= 2) {
      for (let k = 1; k < nums.length; k++) {
        if (nums[k] < nums[k - 1]) {
          return null;
        }
      }
    } else if (marks.length < 3) {
      // 一个可比较的序号都没有、标题又只有两三个：证据太弱，不切
      return null;
    }
    const out: WebChapter[] = [];
    // 第一个标题之前那段（作者的话、前言）如果不止一句，单独成章。
    // 否则它会被挂到「第二章」名下——真机那帖就是缺第一章标题，开头整段
    // 序章内容会被错标成第二章。
    const leadEnd = marks[0];
    let leadCount = 0;
    for (let j = 0; j < leadEnd; j++) {
      if (WebToBook.paragraphText(paragraphs[j]).trim().length > 0) {
        leadCount++;
      }
    }
    const leadOwnChapter = leadCount >= 2;
    if (leadOwnChapter) {
      const lead: ParsedParagraph[] = [];
      for (let j = 0; j < leadEnd; j++) {
        lead.push(paragraphs[j]);
      }
      out.push({ title: '序', paragraphs: lead, url: WebToBook.urlAt(pageUrls, paraPage, 0) });
    }
    for (let k = 0; k < marks.length; k++) {
      const start = marks[k];
      const end = k + 1 < marks.length ? marks[k + 1] : paragraphs.length;
      const title = WebToBook.paragraphText(paragraphs[start]).trim();
      const body: ParsedParagraph[] = [];
      if (k === 0 && !leadOwnChapter) {
        for (let j = 0; j < start; j++) {
          body.push(paragraphs[j]);
        }
      }
      for (let j = start + 1; j < end; j++) {
        body.push(paragraphs[j]);
      }
      let hasText = false;
      for (let j = 0; j < body.length; j++) {
        if (body[j].type === ParaType.DIVIDER || WebToBook.paragraphText(body[j]).trim().length > 0) {
          hasText = true;
          break;
        }
      }
      if (!hasText && out.length > 0) {
        // 只有标题、没内容的空章（标题贴在末尾）：并进上一章，别留空壳
        continue;
      }
      out.push({ title: title, paragraphs: body, url: WebToBook.urlAt(pageUrls, paraPage, start) });
    }
    return out;
  }

  /** 段落所在页的来源链接；来源信息没给就退回空串 */
  private static urlAt(pageUrls: string[], paraPage: number[], paraIdx: number): string {
    if (paraPage.length === 0 || pageUrls.length === 0) {
      return '';
    }
    if (paraIdx < 0 || paraIdx >= paraPage.length) {
      return '';
    }
    const p = paraPage[paraIdx];
    if (p < 0 || p >= pageUrls.length) {
      return '';
    }
    return pageUrls[p];
  }

  /**
   * 正文结束的位置：命中「尾部区」标记就从此截断。
   *
   * 页面尾部的评论区、标签云、版权声明不会被正文容器挡住（真机 B站那本书
   * 结尾是「展开阅读全文 / 2 / 7 / 18 / HE / 刀剑乱舞 / 热门评论」，
   * 晋江那本是「热门话题 / 本章评论 / 版权声明 / 京ICP备…」）。
   * 这些标记只在段首命中即截断，且要求出现在第 4 段之后，避免误伤正文。
   */
  private static tailCutIndex(paragraphs: ParsedParagraph[]): number {
    for (let i = 3; i < paragraphs.length; i++) {
      const p = paragraphs[i];
      if (p.type === ParaType.DIVIDER) {
        continue;
      }
      const norm = WebToBook.flat(WebToBook.paragraphText(p));
      if (norm.length === 0) {
        continue;
      }
      if (WebToBook.isTailMarker(norm)) {
        return i;
      }
    }
    return paragraphs.length;
  }

  private static isTailMarker(norm: string): boolean {
    for (let i = 0; i < WebToBook.TAIL_MARKERS.length; i++) {
      const m = WebToBook.TAIL_MARKERS[i];
      if (norm === m || norm.startsWith(m)) {
        return true;
      }
    }
    return false;
  }

  /** 这段文字是不是「标题回声」：等于标题、等于剥掉站名后的标题、或是标题的一大段子串 */  private static isTitleEcho(norm: string, tFull: string, tShort: string): boolean {
    if (norm.length === 0) {
      return false;
    }
    if (norm === tFull || (tShort.length > 0 && norm === tShort)) {
      return true;
    }
    // 子串判断要求够长，否则「第一章」这种短词会把正文首句误删
    if (norm.length < 8) {
      return false;
    }
    return (tFull.length > 0 && tFull.indexOf(norm) >= 0) ||
      (tShort.length > 0 && tShort.indexOf(norm) >= 0);
  }

  private static isUiToken(norm: string): boolean {
    for (let i = 0; i < WebToBook.UI_TOKENS.length; i++) {
      if (norm === WebToBook.UI_TOKENS[i]) {
        return true;
      }
    }
    return false;
  }

  /**
   * 论坛楼层壳（贴吧触屏版每层楼一套，任何位置都可能出现）：
   * 「踮点灯10楼主」必删（正文段落几乎不会以「楼主」收尾）；
   * 「踮点灯12楼」只在下一段是日期时删——防误删「他住在18楼」这类正文；
   * 「2019-3-4」「2019年3月4日10:30」整段就是日期的删。
   * 「操作」「收藏 回复 举报」这类短按钮行走 UI 词表。
   */
  private static isForumFloor(norm: string, nextNorm: string): boolean {
    if (norm.length === 0) {
      return false;
    }
    if (WebToBook.FLOOR_OWNER.test(norm) || WebToBook.FLOOR_DATE.test(norm)) {
      return true;
    }
    return WebToBook.FLOOR_PLAIN.test(norm) && WebToBook.FLOOR_DATE.test(nextNorm);
  }

  /**
   * 整段就是一串 @ 提及（「@流星守护 @樱逝夜殇」）—— 楼主更文时的通知行。
   * 要求至少两个 @ 且整段除此以外没有别的内容：正文里偶尔出现「@他 你来了」
   * 这种单个提及不会被误删。
   */
  private static isMentionList(raw: string): boolean {
    const t = raw.trim();
    if (t.length === 0 || t.length > 40) {
      return false;
    }
    return /^(?:@[^\s@]{1,16}[\s、,，]*){2,}$/.test(t);
  }

  /** 比较用的归一化：去掉所有空白（含 &nbsp;）并转小写 */
  private static flat(s: string): string {
    return s.replace(/[\s\u00a0\u3000]+/g, '').toLowerCase();
  }

  private static paragraphText(p: ParsedParagraph): string {
    let s = '';
    for (let i = 0; i < p.runs.length; i++) {
      s += p.runs[i].text;
    }
    return s;
  }

  /**
   * 失败诊断提示：页面抽不到正文时，扫一眼源码里有没有「壳 + 内嵌 JSON 数据」
   * 的常见标记。这类页面数据其实在源码里，只是本应用的解析器还没适配该站
   * 的 JSON 结构 —— 把线索写进失败回包，调用方（找文模型）才能转告用户
   * 「不是真抓不到，是差一个适配」，而不是误报成登录墙/反爬。
   */
  static embeddedStateHint(text: string): string {
    const found = SiteRules.markersIn(text);
    if (found.length === 0) {
      return '';
    }
    return `；检测到页面源码内嵌了数据（${found.join('、')}），正文可能在里面但本应用尚未适配该站的数据结构`;
  }

  /**
   * 微博的失败原因要分清楚，别一概说成「要 Cookie」（实测 2026-11）：
   * - 单条微博（m.weibo.cn/status/…、weibo.com/…/status/…）：无 Cookie 落到
   *   Sina Visitor System 验证页；拿到访客令牌也只是 SPA 空壳，内容接口回
   *   {"ok":-100, url:"…/sso/signin"} —— 要的是登录态，应用给不了；
   * - 头条文章（weibo.com/ttarticle/p/show?id=…）：免登录，直抓就有全文。
   * 把这条写进失败回包，调用方模型才不会对文章页也判死刑。
   */
  private static weiboHint(text: string): string {
    if (text.indexOf('Sina Visitor System') >= 0 || text.indexOf('visitor.passport.weibo') >= 0) {
      return '；这是微博的访客验证页：单条微博需要登录态 Cookie，应用拿不到——但微博「头条文章」（weibo.com/ttarticle/p/show?id=…）免登录可抓，若这篇是长文形式可换文章链接再试；否则只能请用户在浏览器打开后分享链接，或复制正文存成 TXT 导入';
    }
    return '';
  }

  /** 取 <meta property|name="..."> 的 content */
  private static metaContent(root: HtmlNode, key: string): string {
    const metas: HtmlNode[] = [];
    HtmlParser.findAll(root, 'meta', metas);
    for (let i = 0; i < metas.length; i++) {
      const m = metas[i];
      if (m.attr('property') === key || m.attr('name') === key) {
        return XhtmlConverter.normalizeSpace(m.attr('content'));
      }
    }
    return '';
  }

  /**
   * 多章拼成一个 HTML 文档。
   *
   * 每章用 <h1> 开头 —— HtmlFileParser 看到 body 顶层有 ≥2 个 <h1>
   * 就会按它们分章；单页只有一个 h1，维持整篇一章的旧行为。
   * 段落序列化回 <p>/<h2>/<hr>，行内样式还原成 <b>/<i>/<u>/<s>，
   * 与本地 HTML 导入的解析方向正好互逆，样式不丢。
   */
  static buildHtml(workTitle: string, chapters: WebChapter[]): string {
    let out = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>';
    out += WebToBook.esc(workTitle);
    out += '</title></head><body>';
    for (let i = 0; i < chapters.length; i++) {
      const ch = chapters[i];
      out += '<h1>';
      out += WebToBook.esc(ch.title);
      out += '</h1>';
      for (let j = 0; j < ch.paragraphs.length; j++) {
        const p = ch.paragraphs[j];
        if (p.type === ParaType.DIVIDER) {
          out += '<hr/>';
          continue;
        }
        const tag = p.type === ParaType.HEADING ? 'h2' : 'p';
        out += `<${tag}>`;
        for (let k = 0; k < p.runs.length; k++) {
          out += WebToBook.serializeRun(p.runs[k]);
        }
        out += `</${tag}>`;
      }
    }
    out += '</body></html>';
    return out;
  }

  private static serializeRun(r: Run): string {
    let s = WebToBook.esc(r.text);
    if (r.bold) {
      s = `<b>${s}</b>`;
    }
    if (r.italic) {
      s = `<i>${s}</i>`;
    }
    if (r.underline) {
      s = `<u>${s}</u>`;
    }
    if (r.strike) {
      s = `<s>${s}</s>`;
    }
    return s;
  }

  private static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}
