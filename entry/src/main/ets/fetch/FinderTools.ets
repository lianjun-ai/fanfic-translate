import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ToolDef } from '../provider/LlmProvider';
import { FicHub, FicMeta, ProbeResult } from './FicHub';
import { HttpFetch } from './HttpFetch';
import { LinkItem, WebList } from './WebList';
import { WebChapter, WebPageFetched, WebToBook } from './WebToBook';
import { SiteMirror } from './SiteMirror';
import { SiteRules, SiteRule } from './SiteRules';
import { ParsedParagraph } from '../parser/ParserTypes';
import { AntiBot } from './AntiBot';
import { FileTextReader } from '../parser/FileTextReader';
import { HtmlParser } from '../parser/HtmlParser';
import { XhtmlConverter } from '../parser/XhtmlConverter';
import { ChapterRef, PendingItem, PendingStore } from './PendingStore';
import { AppendOutcome, BookMerge, TargetRef } from './BookMerge';
import { Dedupe } from '../data/Dedupe';
import { WorkDao } from '../data/WorkDao';
import { Tavily, TavilyHit } from './Tavily';
import { WebPage, PageResult } from './WebPage';
import { FinderCtx, MAX_ROUNDS, ROUNDS_WARN_AT } from './FinderTypes';
import { Log } from '../common/Logger';

/** http_probe 每回合的次数上限（防模型靠试探烧光步数） */
const MAX_PROBES: number = 6;
/** http_probe 回包保留的最大字符数 */
const MAX_PROBE_CHARS: number = 20000;
/** html_to_book 单次最多抓取的页数（防目录展开失控、防模型发疯，安全阀不是分批边界） */
const MAX_BOOK_PAGES: number = 300;
/** list_links 回包最多返回的链接条数（与 html_to_book 的页数上限对齐） */
const MAX_LINKS_REPLY: number = 300;

/**
 * 找文 Agent 的工具箱。
 *
 * 设计原则：每个工具是一个**能力**，不是一个**步骤**。
 * 工具描述里写清「能做什么」和「代价多大」，让模型自己决定怎么组合，
 * 而不是由我们规定"必须先探测再下载"这类流程。
 *
 * 能力边界：
 * - web_search    发现线索（便宜）
 * - fetch_page    自己看网页内容（便宜，能判断链接是不是目标作品；JS 页自动走内置渲染）
 * - fichub_get    把作品页变成 EPUB 放进待入库区（英文同文库一步到位）
 * - html_to_book  把网页（单页或多页连载）抓成本地书，JS 页自动走内置渲染（FicHub 不支持的站点的兜底路）
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

/** 工具层查重的命中结果 */
interface DupHit {
  /** 'pending'（待入库区）或 'shelf'（书架） */
  where: string;
  title: string;
  chapters: number;
  /** pending 命中时给出旧条目，放行新版时好顺手清掉 */
  item: PendingItem | null;
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

/** debug_fetch 的体检报告 */
interface DebugReply {
  status: string;
  http_status: number;
  content_type: string;
  bytes: number;
  title: string;
  visible_text_chars: number;
  direct_extract: string;
  markers: string[];
  data_outline: string[];
  rule_hit: string;
  preview: string;
  /** 内嵌 JSON 里最长的字符串有多少字：几十字=只有元信息（真 CSR），上千字=正文在里面 */
  json_max_text: number;
  /** 实际抓的等效地址（发生了站点镜像时才有值，否则空串） */
  mirrored_from: string;
  note: string;
  steps_left: number;
  hint: string;
}

/** manage_site_rules 的回包 */
interface RulesReply {
  status: string;
  note: string;
  rules: SiteRule[];
  steps_left: number;
  hint: string;
}

/** read_recent_logs 的回包 */
interface LogsReply {
  status: string;
  logs: string;
  steps_left: number;
  hint: string;
}

/** list_links 的回包 */
interface LinksReply {
  status: string;
  note: string;
  count: number;
  links: LinkItem[];
  steps_left: number;
  hint: string;
}

/** check_pending 的回包 */
interface PendingBrief {
  title: string;
  author: string;
  chapters: number;
  source_url: string;
  /** 抓取失败未入库的章节链接（前 5 条）；没有失败页时缺省 */
  failed_urls?: string[];
  /** 失败页总数（可能多于 failed_urls 列出的条数） */
  failed_count?: number;
}

interface ShelfBrief {
  title: string;
  author: string;
  chapters: number;
}

interface PendingReply {
  status: string;
  pending_count: number;
  shelf_count: number;
  pending: PendingBrief[];
  shelf: ShelfBrief[];
  note: string;
  steps_left: number;
  hint: string;
}

/** http_probe 的回包 */
interface ProbeReply {
  status: string;
  code: number;
  content_type: string;
  chars: number;
  truncated: boolean;
  text: string;
  markers: string[];
  probes_left: number;
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
  /** 本回合已用掉的 http_probe 次数（防模型乱探接口烧步数） */
  probes: number;
}

export class FinderTools {
  static newState(): FinderState {
    return { hits: [], downloaded: [], probed: {}, round: 0, probes: 0 };
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
      hint = `只剩 ${left} 步，不要再开新线索了：优先把已确认的作品拿到手，然后收尾。抓书没抓完的别硬撑，失败链接已记在待入库条目里，下回合 check_pending 查到就能接着抓。`;
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
        description: '打开一个网页并读它的可见正文（脚本样式会被去掉，长页面截断）。用来确认某个链接是不是那篇文、看章节数量、读推荐榜单。JS 动态渲染的页面会自动用内置浏览器渲染后读取（每页要多等十几秒），裸请求被风控 403 时也会自动改用内置浏览器重试一次（真浏览器能过 JS 挑战页，如知乎），但只读网页，不会把网页变成书',
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
        description: '把网页抓成本地书放进待入库区（FicHub 不支持的站点的兜底路，如 LOFTER、晋江免费章节、博客、论坛帖子串）。urls 按阅读顺序传数组，每个网页合成一章；只抓一个网页时也可以只传一个元素的数组。目录页/作品页链接直接传进来即可：工具认出目录页会自动展开全部章节链接逐页抓取（对话体小说站、连载目录页都适用），不用你自己枚举几百个章节链接。数量上限 300 页：连载长篇一次传全目录或只传目录页都行，工具会聚合成同一本书，每页完成都会上报进度，个别页失败不影响其余页面（回包里会列出失败页）。命中站点规则的站会按规则直接抽取（快）；否则静态页直抓、JS 动态渲染的页面自动用内置浏览器渲染后抽取（每页要多等十几秒）；裸请求被风控 403 时也会自动改用内置浏览器重试一次（能过知乎这类 JS 挑战页）；需要登录才能看、内容主要是图片或人机验证的页面才会抓不到正文而失败',
        parameters: JSON.parse(
          '{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"},"description":"按阅读顺序排列的网页地址，最多 300 个；连载长篇可一次给全目录，会聚合成同一本书"},"title":{"type":"string","description":"书名，不填就用第一个网页的标题"},"author":{"type":"string","description":"作者"}},"required":["urls"]}')
      }
    };
    const addChapters: ToolDef = {
      type: 'function',
      function: {
        name: 'add_chapters',
        description: '把章节补进一本书（合并/补章/追更统一走这个工具）。target 是补进的目标书：待入库条目或书架作品的 书名/来源链接/路径；sources 是要补的内容，按阅读顺序传待入库条目（书名或来源链接）和/或网页链接。行为：待入库目标 → 和来源内容合成一本新的待入库条目（旧的清掉）；书架目标 → 新章直接插进书架那本书并按章号排序，已有章和它的译文/阅读进度绝不动。撞了已有章会跳过并在回包说明。来源网页的标题里读不出「第N章」时（LOFTER 帖子页很常见），务必把章号按顺序放进 numbers，否则新章只能追加在末尾。回包带「按章号看缺：20、30」这类提示时说明还差这些章，继续抓了再 add_chapters 一次',
        parameters: JSON.parse(
          '{"type":"object","properties":{"target":{"type":"string","description":"补进的目标书：待入库条目或书架作品（书名、来源链接或路径）"},"sources":{"type":"array","items":{"type":"string"},"description":"要补的内容，按阅读顺序：待入库条目（书名/来源链接）或网页链接"},"numbers":{"type":"array","items":{"type":"integer"},"description":"与 sources 解析出的章按顺序对应的章号（可选）。来源标题里读不出章号时必传，例：补第 20、30 章 → [20,30]"},"title":{"type":"string","description":"目标在待入库时可改书名，不填沿用目标原书名"},"author":{"type":"string","description":"作者（仅待入库目标生效）"},"keep_originals":{"type":"boolean","description":"是否保留原来的待入库条目，默认 false（合并成功后删除）"}},"required":["target","sources"]}')
      }
    };
    const debugFetch: ToolDef = {
      type: 'function',
      function: {
        name: 'debug_fetch',
        description: '抓网页的「体检报告」：HTTP 状态、字节数、页面标题、可见文本量、直抓能抽出多少段正文、源码里检测到的内嵌数据标记（__NEXT_DATA__/__initialize_data__ 等，这类页面正文其实藏在源码 JSON 里）、内嵌 JSON 的结构速览（用来推断站点规则的取值路径）、站点规则命中情况和正文前 300 字预览。只直抓不渲染。html_to_book 抓不到、或你判断不了某个站是什么形态时，先调它再做决定，别瞎猜',
        parameters: JSON.parse(
          '{"type":"object","properties":{"url":{"type":"string","description":"要体检的网页地址"}},"required":["url"]}')
      }
    };
    const manageRules: ToolDef = {
      type: 'function',
      function: {
        name: 'manage_site_rules',
        description: '查看或维护「站点抓取规则」。规则告诉 html_to_book 怎么从某个站抽正文，两种写法：①内嵌数据规则：marker（源码里的 JSON 定位标记，如 __initialize_data__）+ json_content（正文在 JSON 里的点分路径，如 postData.data.postView.content），可选 json_title；②元素规则：selector 定位正文容器（如 div.post-content、article）。action=list 列出现有规则（含哪些被临时停用）；action=add 添加或按 url_pattern 覆盖（先用 debug_fetch 的 data_outline 推断路径，写完直接重试 html_to_book 验证）；action=remove 删除自定义规则（内置规则不可删）；action=disable 临时停用某条规则（内置规则也能停：用来验证这条规则是不是唯一依赖，或让这个站从头走通用解析）；action=enable 恢复。规则存本地，立即生效，不用重新装应用。注意：少数站有内置的代码级处理器（如话本小说的对话体），它们优先级高于用户规则——这些站不用写规则，写了也不会生效',
        parameters: JSON.parse(
          '{"type":"object","properties":{"action":{"type":"string","enum":["list","add","remove","disable","enable"],"description":"list=列出全部规则（标注停用项），add=添加/覆盖，remove=删除，disable=临时停用，enable=恢复"},"url_pattern":{"type":"string","description":"URL 匹配子串，如 lofter.com/post；命中即用这条规则"},"marker":{"type":"string","description":"内嵌 JSON 定位标记"},"json_title":{"type":"string","description":"标题的点分路径，可空（配合 title_from_first_paragraph）"},"json_content":{"type":"string","description":"正文 HTML 的点分路径"},"selector":{"type":"string","description":"正文容器选择器（tag.class / .class / #id / tag）。加 all: 前缀（如 all:div.content）会收集全部匹配的容器并按文档顺序拼接，用于贴吧这类每层楼正文各占一个容器的页面"},"title_from_first_paragraph":{"type":"boolean","description":"无标题时用首段前 40 字当书名，默认 true"},"note":{"type":"string","description":"规则备注，如站点名"}},"required":["action"]}')
      }
    };
    const readLogs: ToolDef = {
      type: 'function',
      function: {
        name: 'read_recent_logs',
        description: '读取应用最近的运行日志（最近几分钟，含抓取、渲染、模型请求的详细过程）。某个工具刚才失败了但回包没说清原因时调它：日志里能看到内置渲染抽到的 HTML 大小和正文字符数、HTTP 错误码等现场信息',
        parameters: JSON.parse(
          '{"type":"object","properties":{"lines":{"type":"integer","description":"要看最近多少条，默认 80"}}}')
      }
    };
    const listLinks: ToolDef = {
      type: 'function',
      function: {
        name: 'list_links',
        description: '列出网页上的链接清单。对 LOFTER 博客（传博客主页或任意一篇帖子的链接）会自动走 LOFTER 归档接口拿到整个博客的文章清单（标题+链接+发布日期，按时间正序），免登录——抓 LOFTER 系列文/合集先用它拿章节目录，再挑出目标章节的 url 传给 html_to_book。keyword 可按标题过滤。其它站点则解析页面里的站内 <a> 链接，最多返回 300 条；超出会截断并在 note 里说明剩余条数与分批办法',
        parameters: JSON.parse(
          '{"type":"object","properties":{"url":{"type":"string","description":"LOFTER 博客主页或该博客任意一篇帖子的链接；其它站点传列表页/目录页地址"},"keyword":{"type":"string","description":"可选，只返回标题含此关键字的条目"}},"required":["url"]}')
      }
    };
    const checkPending: ToolDef = {
      type: 'function',
      function: {
        name: 'check_pending',
        description: '查看待入库区和书架的真实状态：待入库条目（书名/作者/章数/来源链接）和书架作品概要（书名/作者/章数）。判断「这本是不是已经抓过、抓到了哪一章、书架上还有什么」时调它，不要凭对话记忆猜——查重工具只拦单次抓取，跨回合的判断靠这个。待入库条目若带 failed_urls（抓取失败的章节链接），用它作 sources 调 add_chapters 就能接着抓',
        parameters: JSON.parse('{"type":"object","properties":{}}')
      }
    };
    const httpProbeDef: ToolDef = {
      type: 'function',
      function: {
        name: 'http_probe',
        description: '直接发一个 HTTP 请求看原始响应（受限：只支持 GET/POST、不能带 Cookie 或自定义头部，只能加 Referer）。用来探某个站的内部接口——页面直抓只有空壳、又没有内嵌数据标记时，可以试它的 JSON/DWR 接口：从脚本里找到可疑地址后先 GET，再试 POST 表单参数，报错原文本身就是线索。每回合最多 6 次；探到规律就用 manage_site_rules 落地规则或直接 html_to_book 验证，不要一直试探',
        parameters: JSON.parse(
          '{"type":"object","properties":{"url":{"type":"string","description":"接口地址，http/https"},"method":{"type":"string","enum":["GET","POST"],"description":"默认 GET"},"body":{"type":"string","description":"POST 请求体；body_type=form 时形如 a=1&b=2，json 时是 JSON 文本"},"body_type":{"type":"string","enum":["form","json"],"description":"请求体类型，默认 form"},"referer":{"type":"string","description":"可选，Referer 头（很多站会校验）"},"max_chars":{"type":"integer","description":"返回文本保留多少字符，默认 6000，上限 20000"}},"required":["url"]}')
      }
    };
    return [webSearch, fetchPage, probe, webBook, download, addChapters, debugFetch, manageRules, readLogs, listLinks, checkPending, httpProbeDef];
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
    if (name === 'add_chapters') {
      return FinderTools.addChapters(args, ctx, st);
    }
    if (name === 'debug_fetch') {
      return FinderTools.debugFetch(args, ctx, st);
    }
    if (name === 'manage_site_rules') {
      return FinderTools.manageSiteRules(args, ctx, st);
    }
    if (name === 'read_recent_logs') {
      return FinderTools.readRecentLogs(args, ctx, st);
    }
    if (name === 'list_links') {
      return FinderTools.listLinks(args, ctx, st);
    }
    if (name === 'check_pending') {
      return FinderTools.checkPendingList(ctx, st);
    }
    if (name === 'http_probe') {
      return FinderTools.httpProbe(args, ctx, st);
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
    const early = await FinderTools.checkDup(ctx, '', '', url, 0);
    if (early !== null && early.item !== null) {
      const hit: FicMeta = {
        title: early.title, author: '', chapters: early.chapters,
        words: 0, info: '已下载过', epubUrl: '', sourceUrl: url
      };
      ctx.hooks.onAction(`　　《${hit.title}》已经下过了，跳过重复下载`);
      return FinderTools.reply('ok', '这本之前已经下过了，就在待入库区，等用户点一下就进书架', hit,
        early.item.epubPath, st);
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
    // 探测出了标题/作者，这时还能查书架：书架里已有的别再花一两分钟下载
    const dup = await FinderTools.checkDup(ctx, m3.title, m3.author, m3.sourceUrl, m3.chapters);
    if (dup !== null) {
      ctx.hooks.onAction(`　　《${dup.title}》已存在（${dup.where === 'shelf' ? '书架' : '待入库区'}，${dup.chapters} 章），跳过重复下载`);
      return FinderTools.reply('exists', FinderTools.dupNote(dup), m3, '', st);
    }
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
    // 标题来自文件名时不可靠，作者没传时键为空——两种情况 checkDup 都只会按
    // sourceUrl 拦，不会误伤；模型把标题作者都给全了才做键匹配
    const dup = await FinderTools.checkDup(ctx, title, authorArg, url, 0);
    if (dup !== null) {
      ctx.hooks.onAction(`　　《${dup.title}》已存在（${dup.where === 'shelf' ? '书架' : '待入库区'}，${dup.chapters} 章），跳过重复下载`);
      return FinderTools.reply('exists', FinderTools.dupNote(dup), meta, '', st);
    }
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
    // 300 只是防模型发疯（一次传几千个链接）的安全阀，不是分批边界：
    // 内部本来就是一个循环逐页抓，几百页也一样聚合进同一本书。
    if (urls.length > 300) {
      return FinderTools.reply('bad_args', `单次最多 300 个网页（收到 ${urls.length} 个），超出部分分次调用并在回复里说明已抓到哪一段`, null, '', st);
    }
    // 与 fichub_get 相同的去重约定：sourceUrl 记第一个网页。章数还没抓出来，
    // 先拿「要抓的页数」当规模下限：旧版章节不会比页数少（一页至少一章），
    // 要抓的页数比旧版章节数还多 → 这次必然更全，checkDup 会放行并清掉旧条目。
    // 单 URL 不做早期拦截：它多半是目录页，真实章数要等目录展开才知道，
    // 拿 1 当规模会误拦「同源重抓」（重抓覆盖旧条目）；抓完后的最终 checkDup
    // 用真实章数判断，那里才能放行。
    if (urls.length > 1) {
      const early = await FinderTools.checkDup(ctx, '', '', urls[0], urls.length);
      if (early !== null && early.item !== null) {
        const hit: FicMeta = {
          title: early.title, author: '', chapters: early.chapters,
          words: 0, info: '已抓取过', epubUrl: '', sourceUrl: urls[0]
        };
        ctx.hooks.onAction(`　　《${hit.title}》已经抓过了，跳过重复抓取`);
        return FinderTools.reply('ok', '这本之前已经抓过了，就在待入库区，等用户点一下就进书架', hit,
          early.item.epubPath, st);
      }
    }
    ctx.hooks.onAction(`📄 抓网页成书：${urls.length} 个页面`);
    const dir = `${ctx.ui.cacheDir}/finder_dl`;
    const pages: WebPageFetched[] = [];
    const failedNotes: string[] = [];
    /** 抓取失败的请求地址，原样进边车 failedUrls —— 跨回合补抓的依据 */
    const failedUrls: string[] = [];
    const expandedNotes: string[] = [];
    let totalChars = 0;
    // 队列式抓取：目录页在原地展开成内页链接插回队列，阅读顺序不乱。
    // queued 记录所有入过队的地址 —— 目录页不会被重复展开，模型显式传过的
    // 页面也不会因为又出现在目录里而被抓两次。上限仍由 MAX_BOOK_PAGES 兜底。
    const queue = urls.slice();
    const queued = new Set<string>(queue);
    /** 与 pages 对齐的原始请求地址（fetchPage 可能改写 p.url，回退时用它） */
    const requestedUrls: string[] = [];
    for (let qi = 0; qi < queue.length && pages.length < MAX_BOOK_PAGES; qi++) {
      const pageUrl = queue[qi];
      ctx.hooks.onStatus(`正在抓取第 ${qi + 1}/${queue.length} 页…`);
      const p = await WebToBook.fetchPage(pageUrl, dir);
      if (p.ok) {
        // 目录页自动展开：源码里与本页同路径前缀的内页链接够多，就把它们插回
        // 队列逐页抓，目录页本身不进正文 —— 模型不用再枚举几百个章节链接
        const html = p.html !== undefined ? p.html : '';
        if (html.length > 0) {
          const links = WebList.expandCatalog(html, pageUrl);
          if (links.length > 0) {
            expandedNotes.push(`「${p.title.length > 0 ? p.title : pageUrl}」展开出 ${links.length} 个内页`);
            ctx.hooks.onAction(`　　「${p.title.length > 0 ? p.title : pageUrl}」是目录页：展开出 ${links.length} 个内页链接，继续逐页抓取`);
            // 只插没入过队的：分页目录的「下一页」会互相展开，不过滤的话
            // 两个目录页会无限互相插队（pages 不增长，循环条件永远成立）→ 挂死
            let insertAt = qi + 1;
            for (let k = 0; k < links.length; k++) {
              if (!queued.has(links[k])) {
                queue.splice(insertAt, 0, links[k]);
                insertAt++;
                queued.add(links[k]);
              }
            }
            continue;
          }
        }
        // 源码的使命（目录判定）已完成，别让它跟着 pages 常驻内存：
        // 几百页 × 每页几百 KB 的原始 HTML 会把内存顶爆
        p.html = undefined;
        pages.push(p);
        requestedUrls.push(pageUrl);
        totalChars += p.chars;
        ctx.hooks.onAction(`　　第 ${pages.length} 页「${p.title.length > 0 ? p.title : pageUrl}」：约 ${p.chars} 字${p.note.length > 0 ? `（${p.note}）` : ''}`);
      } else {
        failedNotes.push(`「${pageUrl}」：${p.note}`);
        failedUrls.push(pageUrl);
        ctx.hooks.onAction(`　　「${pageUrl}」抓取失败：${p.note}`);
      }
    }
    if (pages.length === 0) {
      // 目录展开后可能有上百个失败页，全列出来回包会爆，只举前几例 + 计数
      const shown = failedNotes.slice(0, 5).join('；');
      const why = failedNotes.length > 5
        ? `${shown}（另有 ${failedNotes.length - 5} 个页面同样失败，从略）`
        : shown;
      return FinderTools.reply('fail',
        `所有页面都没抓到正文（已尝试直接抓取和内置浏览器渲染）。${why}。这类页面通常需要登录后才能看，或内容主要是图片、反爬极强（微博、小红书、番茄等），` +
        '可以建议用户：在浏览器里打开文章、等正文显示后把链接分享给本应用，或复制正文存成 TXT 从「导入本地文件」进来',
        null, '', st);
    }
    const titleArg = FinderTools.str(args, 'title');
    const workTitle = titleArg.length > 0 ? titleArg
      : (pages[0].title.length > 0 ? pages[0].title : '未命名作品');
    const authorArg = FinderTools.str(args, 'author');
    // 网页分页是站方切的，和「章」不是一回事：贴吧一帖里塞好几章，一章也会
    // 被页边界劈开。先把各页段落按顺序拼成一条，再按文内标题切；标题不够
    // 两个才退回「一页一章」。
    const merged: ParsedParagraph[] = [];
    const pageUrls: string[] = [];
    const paraPage: number[] = [];
    for (let i = 0; i < pages.length; i++) {
      // 目录展开后 pages 与 urls 不再一一对应，回退只能用每页自己的请求地址
      pageUrls.push(pages[i].url.length > 0 ? pages[i].url : requestedUrls[i]);
      for (let j = 0; j < pages[i].paragraphs.length; j++) {
        merged.push(pages[i].paragraphs[j]);
        paraPage.push(i);
      }
    }
    const chapters: WebChapter[] = [];
    const byHead = WebToBook.splitChapters(merged, pageUrls, paraPage);
    if (byHead !== null) {
      for (let i = 0; i < byHead.length; i++) {
        chapters.push(byHead[i]);
      }
      ctx.hooks.onAction(`　　按文内标题切成 ${chapters.length} 章`);
    } else {
      for (let i = 0; i < pages.length; i++) {
        const p = pages[i];
        // 多页时每页一章，章名用页面标题；单页时章名就是书名
        const name = pages.length > 1
          ? (p.title.length > 0 ? p.title : `第 ${chapters.length + 1} 章`)
          : workTitle;
        chapters.push({ title: name, paragraphs: p.paragraphs, url: pageUrls[i] });
      }
    }
    // 章节清单：章号 + 标题 + 来源链接，随边车落盘。补章/追更时模型靠它
    // 直接知道「缺第几章、链接是什么」，不用再拿 list_links 试探
    const chapterIndex: ChapterRef[] = [];
    for (let i = 0; i < chapters.length; i++) {
      chapterIndex.push({
        no: WebToBook.chapterNumber(chapters[i].title),
        title: chapters[i].title,
        url: chapters[i].url
      });
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
      chapters: chapters.length,
      words: totalChars,
      info: expandedNotes.length > 0
        ? `网页抓取 · ${pages.length} 页（目录展开 ${expandedNotes.length} 处）`
        : (urls.length > 1 ? `网页抓取 · ${pages.length}/${urls.length} 页` : '网页抓取'),
      epubUrl: '',
      sourceUrl: urls[0]
    };
    // 章数已经真实切出来了，这时查重比早期拦截更准（书架+待入库、含章数比较）；
    // 命中拦截就把刚生成的临时 HTML 删掉，别留下孤儿文件
    const dup = await FinderTools.checkDup(ctx, workTitle, authorArg, urls[0], chapters.length);
    if (dup !== null) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
        // 删不掉无所谓
      }
      ctx.hooks.onAction(`　　《${dup.title}》已存在（${dup.where === 'shelf' ? '书架' : '待入库区'}，${dup.chapters} 章），跳过重复保存`);
      return FinderTools.reply('exists', FinderTools.dupNote(dup), meta, '', st);
    }
    try {
      const item: PendingItem = await PendingStore.save(ctx.ui, meta, path, chapterIndex, failedUrls);
      st.hits.push(meta);
      st.downloaded.push(item);
      ctx.hooks.onHit(meta);
      ctx.hooks.onAction(`📥 已抓成书：《${workTitle}》（待入库，${chapters.length} 章）`);
      ctx.hooks.onDownloaded(item);
      const failBrief = failedNotes.length > 5
        ? `${failedNotes.slice(0, 5).join('；')}（另有 ${failedNotes.length - 5} 个页面同样失败，从略）`
        : failedNotes.join('；');
      let note = failedNotes.length > 0
        ? `已放进待入库区（${failedNotes.length} 个页面抓取失败：${failBrief}）。失败页链接已记在这本待入库条目里，本回合接着用 add_chapters（target=这本书，sources=失败链接）补抓，或留给之后的回合（check_pending 能查到 failed_urls）`
        : '已放进待入库区，用户确认后才会进书架';
      if (expandedNotes.length > 0) {
        note = `${note}。目录页已自动展开：${expandedNotes.join('；')}——书按展开后的完整目录合成，不用再补传章节链接`;
      }
      return FinderTools.reply('ok', note, meta, item.epubPath, st);
    } catch (e) {
      const why = (e as Error).message;
      return FinderTools.reply('fail', `网页已抓取但入库失败：${why}`, null, path, st);
    }
  }

  /**
   * add_chapters：把 sources 的章节补进 target —— 合并、补章、追更统一入口。
   *
   * target 可以是待入库条目（合成一本新的待入库 HTML）也可以是书架作品
   * （新章直接插库、已有章与译文/进度不动）。找不到目标或来源时把
   * 待入库区 + 书架的清单回给模型，让它自己修正参数重试。
   */
  private static async addChapters(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const targetTok = FinderTools.str(args, 'target');
    const srcToks = FinderTools.strList(args, 'sources');
    if (targetTok.length === 0 || srcToks.length === 0) {
      return FinderTools.reply('bad_args',
        '缺少 target（补进哪本书）或 sources（要补的内容：待入库条目或网页链接，按阅读顺序）', null, '', st);
    }
    const target: TargetRef | null = await BookMerge.resolveTarget(ctx.ui, targetTok);
    if (target === null) {
      const inv = await FinderTools.inventory(ctx.ui);
      return FinderTools.reply('bad_args', `没找到目标「${targetTok}」。现有的：${inv}`, null, '', st);
    }
    const pend = await PendingStore.list(ctx.ui);
    const sourceItems: PendingItem[] = [];
    const sourceUrls: string[] = [];
    const missing: string[] = [];
    for (let i = 0; i < srcToks.length; i++) {
      const t = srcToks[i];
      let found: PendingItem | null = null;
      for (let j = 0; j < pend.length; j++) {
        const it = pend[j];
        if (target.item !== null && it.epubPath === target.item.epubPath) {
          continue;
        }
        if (it.epubPath === t || it.sourceUrl === t || it.title === t) {
          found = it;
          break;
        }
      }
      if (found !== null) {
        sourceItems.push(found);
      } else if (/^https?:\/\//i.test(t)) {
        sourceUrls.push(t);
      } else {
        missing.push(t);
      }
    }
    if (missing.length > 0) {
      const inv = await FinderTools.inventory(ctx.ui);
      return FinderTools.reply('bad_args',
        `这些没找到：${missing.join('；')}。现有的：${inv}。注意 sources 里的每一项要么是待入库条目（书名/来源链接），要么是 http(s) 网页链接`,
        null, '', st);
    }
    if (sourceItems.length === 0 && sourceUrls.length === 0) {
      return FinderTools.reply('bad_args', 'sources 里没有可用内容', null, '', st);
    }
    const parts: string[] = [];
    for (let i = 0; i < sourceItems.length; i++) {
      parts.push(`《${sourceItems[i].title}》`);
    }
    for (let i = 0; i < sourceUrls.length; i++) {
      parts.push(sourceUrls[i]);
    }
    const targetTitle = target.kind === 'shelf'
      ? (target.work !== null ? target.work.title : '')
      : (target.item !== null ? target.item.title : '');
    ctx.hooks.onAction(`📚 补章：《${targetTitle}》 ← ${parts.join(' + ')}`);
    const titleArg = FinderTools.str(args, 'title');
    const authorArg = FinderTools.str(args, 'author');
    const keep = FinderTools.bool(args, 'keep_originals', false);
    const numbers = FinderTools.numList(args, 'numbers');
    try {
      const out: AppendOutcome = await BookMerge.append(ctx.ui, target, sourceItems, sourceUrls,
        titleArg, authorArg, keep, numbers, (m: string) => ctx.hooks.onStatus(m));
      if (out.item !== null) {
        const meta: FicMeta = {
          title: out.item.title, author: out.item.author, chapters: out.item.chapters,
          words: out.item.words, info: out.item.info, epubUrl: '', sourceUrl: out.item.sourceUrl
        };
        st.hits.push(meta);
        st.downloaded.push(out.item);
        ctx.hooks.onDownloaded(out.item);
      } else {
        ctx.hooks.onAction(`　　书架《${out.title}》已更新：+${out.added} 章，现共 ${out.totalChapters} 章`);
      }
      const where = out.kind === 'shelf'
        ? `书架《${out.title}》已直接补章`
        : `已合成新的待入库条目《${out.title}》`;
      const skipNote = out.skipped > 0 ? `，${out.skipped} 章和已有内容重复被跳过` : '';
      const orderNote = out.gaps.length > 0 ? `。${out.gaps}——继续把这些章抓了再 add_chapters 一次` : '';
      const tailNote = out.unnumbered > 0
        ? `。另有 ${out.unnumbered} 章标题里读不出章号，被追加在末尾（补章时尽量带上 numbers 章号参数）`
        : '';
      const keepNote = out.kind === 'pending'
        ? (keep ? '；来源条目按你的要求保留' : '；原来的条目已清理')
        : '；来源待入库条目保留着，用户可以自行清理';
      const note = `${where}：+${out.added} 章，现共 ${out.totalChapters} 章${skipNote}` +
        `。开头「${out.firstTitle}」，结尾「${out.lastTitle}」${orderNote}${tailNote}${keepNote}` +
        '。核对没问题就让用户确认入库或在书架里查看';
      const meta2: FicMeta | null = out.item !== null ? {
        title: out.item.title, author: out.item.author, chapters: out.item.chapters,
        words: out.item.words, info: out.item.info, epubUrl: '', sourceUrl: out.item.sourceUrl
      } : null;
      return FinderTools.reply('ok', note, meta2,
        out.item !== null ? out.item.epubPath : '', st);
    } catch (e) {
      const why = (e as Error).message;
      Log.e(`补章失败：${why}`);
      ctx.hooks.onAction(`　　补章失败：${why}`);
      return FinderTools.reply('fail', `补章失败：${why}`, null, '', st);
    }
  }

  /** 待入库区 + 书架的完整清单（找不到目标/来源时回给模型自愈） */
  private static async inventory(ui: common.UIAbilityContext): Promise<string> {
    const lines: string[] = [];
    const pend = await PendingStore.list(ui);
    for (let i = 0; i < pend.length; i++) {
      lines.push(`[待入库]《${pend[i].title}》${pend[i].chapters} 章 · 来源 ${pend[i].sourceUrl}`);
    }
    const works = await WorkDao.list();
    for (let i = 0; i < works.length; i++) {
      lines.push(`[书架]《${works[i].title}》${works[i].chapterCount} 章`);
    }
    if (lines.length === 0) {
      return '（待入库区和书架都是空的）';
    }
    return lines.join(' ｜ ');
  }

  /**
   * debug_fetch：网页体检报告。
   *
   * 只直抓不渲染（渲染的观测交给 fetch_page / 日志）。目标是用一次调用
   * 回答「这个站属于哪种形态」：静态页直抓就能出段数；壳 + 内嵌数据会
   * 报出标记和 JSON 结构速览，模型据此写站点规则；真 CSR 两项都为空，
   * 只能走渲染或建议用户分享。
   */
  private static async debugFetch(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    if (url.length === 0) {
      return FinderTools.reply('bad_args', '缺少 url 参数', null, '', st);
    }
    ctx.hooks.onAction(`🩺 体检：${url}`);
    const b = FinderTools.budget(st);
    const dir = `${ctx.ui.cacheDir}/finder_dl`;
    // 体检必须看「真正会被抓的那份页面」。不过镜像的话，/p/ 链接会报出
    // 「贴吧小程序、可抽出 0 段」——一份和实际抓取结果相反的假报告，
    // 模型据此会判定此路不通，然后自己去拼接口（上次就是这么偏的）。
    const target = SiteMirror.url(url);
    if (target !== url) {
      ctx.hooks.onAction(`　　等效地址：${target}`);
    }
    const res = await HttpFetch.toFile(target, dir);
    if (!res.ok) {
      // 403 时把响应体摸一眼：是反爬挑战页还是真登录墙，判断完全不同
      const diag = await HttpFetch.getText(target, '');
      const block = AntiBot.detect(diag.text);
      const note = `${res.note}${block.length > 0 ? `（识别为拦截页：${AntiBot.hint(block)}）` : ''}`;
      const reply: DebugReply = {
        status: 'fail', http_status: 0, content_type: '', bytes: 0, title: '',
        visible_text_chars: 0, direct_extract: '', markers: [], data_outline: [],
        rule_hit: '', preview: '', json_max_text: 0, note: note,
        mirrored_from: target !== url ? target : '',
        steps_left: b.steps_left, hint: b.hint
      };
      ctx.hooks.onAction(`　　体检失败：${note}`);
      return JSON.stringify(reply);
    }
    let text = '';
    try {
      text = FileTextReader.read(res.path);
    } catch (e) {
      text = '';
    } finally {
      try {
        fs.unlinkSync(res.path);
      } catch (e) {
        // 忽略
      }
    }
    const root = HtmlParser.parse(text);
    // 标题走和 book 管线同一个函数：体检报的书名必须和真正入库的书名一致
    const title = WebToBook.pageTitle(root);
    const visible = WebPage.toText(text);
    let paraCount = 0;
    let paraChars = 0;
    try {
      const ps = XhtmlConverter.toParagraphs(root);
      for (let i = 0; i < ps.length; i++) {
        let len = 0;
        for (let j = 0; j < ps[i].runs.length; j++) {
          len += ps[i].runs[j].text.length;
        }
        paraChars += len;
        if (ps[i].type !== 'divider' && len > 0) {
          paraCount++;
        }
      }
    } catch (e) {
      paraCount = -1;
    }
    const markers = SiteRules.markersIn(text);
    const outline: string[] = [];
    let jsonMaxText = 0;
    for (let i = 0; i < markers.length; i++) {
      const json = SiteRules.extractJsonAfter(text, markers[i]);
      if (json === null) {
        continue;
      }
      try {
        const data = JSON.parse(json) as Object;
        SiteRules.outline(data, outline, 40);
        jsonMaxText = SiteRules.maxStrLen(data, 0);
      } catch (e) {
        outline.push(`${markers[i]}：JSON 解析失败`);
      }
      break;
    }
    const hit = SiteRules.extract(text, target);
    const mirrorNote = target !== url
      ? `这份报告抓的是等效地址 ${target}（原链接会被站方重定向到空壳页），html_to_book 抓同一个链接时用的也是它。`
      : '';
    let note = '';
    if (markers.length > 0 && hit === null) {
      // 有标记不等于正文在里面：B 站专栏这类站的 JSON 只有标题/封面，
      // 正文是接口取的，写规则怎么写都抽不到 —— 用最长字符串长度区分开。
      note = jsonMaxText >= 600
        ? `页面内嵌了数据（最长字符串 ${jsonMaxText} 字，正文很可能就在里面）但规则未命中：按 data_outline 的路径用 manage_site_rules(add) 写规则`
        : `内嵌数据里只有元信息（最长字符串 ${jsonMaxText} 字，不足正文）：真正文不在这份 JSON 里，属于接口取数的动态页 —— 别写站点规则，直接用 html_to_book / fetch_page 走内置渲染`;
    } else if (markers.length === 0 && visible.length < 300) {
      note = '可见文本极少且没有内嵌数据标记：这是 JS 动态渲染页，正文由接口异步塞进 DOM —— 走内置渲染（html_to_book / fetch_page 会自动降级），别写规则';
    }
    if (mirrorNote.length > 0) {
      note = note.length > 0 ? `${mirrorNote}${note}` : mirrorNote;
    }
    const reply: DebugReply = {
      status: 'ok',
      http_status: 200,
      content_type: res.contentType,
      bytes: res.bytes,
      title: title,
      visible_text_chars: visible.length,
      direct_extract: paraCount === -1 ? '直抓解析异常' : `直抓可抽出 ${paraCount} 段约 ${paraChars} 字`,
      markers: markers,
      data_outline: outline,
      rule_hit: hit === null ? '' : `命中规则「${hit.rule.note}」：标题「${hit.title}」，${hit.paragraphs.length} 段`,
      preview: visible.length > 0 ? visible.substring(0, 300) : '',
      json_max_text: jsonMaxText,
      note: note,
      mirrored_from: target !== url ? target : '',
      steps_left: b.steps_left,
      hint: b.hint
    };
    ctx.hooks.onAction(`　　体检完成：${res.bytes} 字节，${title.length > 0 ? title : '（无标题）'}，${reply.direct_extract}${markers.length > 0 ? `，内嵌标记 ${markers.join('/')}` : ''}`);
    return JSON.stringify(reply);
  }

  /** manage_site_rules：站点规则的增删查，模型自己适配新站的入口 */
  private static manageSiteRules(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): string {
    const action = FinderTools.str(args, 'action');
    const b = FinderTools.budget(st);
    const send = (status: string, note: string, rules: SiteRule[]): string => {
      const reply: RulesReply = {
        status: status, note: note, rules: rules,
        steps_left: b.steps_left, hint: b.hint
      };
      return JSON.stringify(reply);
    };
    if (action === 'list') {
      const rules = SiteRules.allRules();
      const off = SiteRules.loadDisabled();
      ctx.hooks.onAction(`📋 站点规则：共 ${rules.length} 条${off.length > 0 ? `（停用 ${off.length} 条）` : ''}`);
      const note = rules.length === 0 ? '还没有任何规则'
        : (off.length > 0 ? `已停用：${off.join('、')}（这些站现在走通用解析）` : '');
      return send('ok', note, rules);
    }
    if (action === 'disable' || action === 'enable') {
      const pattern = FinderTools.str(args, 'url_pattern');
      if (pattern.length === 0) {
        return send('bad_args', '缺少 url_pattern（要停用/恢复哪条规则）', SiteRules.allRules());
      }
      const why = SiteRules.setEnabled(pattern, action === 'enable');
      ctx.hooks.onAction(`📐 站点规则：${why}`);
      return send(why.indexOf('已') === 0 ? 'ok' : 'bad_args', why, SiteRules.allRules());
    }
    if (action === 'add') {
      const pattern = FinderTools.str(args, 'url_pattern');
      const marker = FinderTools.str(args, 'marker');
      const jsonTitle = FinderTools.str(args, 'json_title');
      const jsonContent = FinderTools.str(args, 'json_content');
      const selector = FinderTools.str(args, 'selector');
      const note = FinderTools.str(args, 'note');
      const fromFirst = FinderTools.bool(args, 'title_from_first_paragraph', true);
      const why = SiteRules.addRule(pattern, marker, jsonTitle, jsonContent, selector, fromFirst, note);
      ctx.hooks.onAction(`📐 站点规则：${why}`);
      return send(why.indexOf('已') === 0 ? 'ok' : 'bad_args', why, SiteRules.allRules());
    }
    if (action === 'remove') {
      const pattern = FinderTools.str(args, 'url_pattern');
      const why = SiteRules.removeRule(pattern);
      ctx.hooks.onAction(`📐 站点规则：${why}`);
      return send(why.indexOf('已') === 0 ? 'ok' : 'bad_args', why, SiteRules.allRules());
    }
    return send('bad_args', `不认识的 action：${action}（可用 list / add / remove）`, SiteRules.allRules());
  }

  /** read_recent_logs：把应用内日志环形缓冲回喂给模型，失败现场自己看 */
  private static readRecentLogs(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): string {
    const lines = FinderTools.int(args, 'lines', 80);
    const logs = Log.recent(lines);
    const b = FinderTools.budget(st);
    ctx.hooks.onAction('📜 已读取应用日志');
    const payload: LogsReply = {
      status: 'ok',
      logs: logs.length > 0 ? logs : '（还没有日志）',
      steps_left: b.steps_left,
      hint: b.hint
    };
    return JSON.stringify(payload);
  }

  /** list_links：列出网页链接目录（LOFTER 走归档接口，其它站解析 <a>） */
  private static async listLinks(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    const keyword = FinderTools.str(args, 'keyword');
    if (url.length === 0) {
      return FinderTools.reply('bad_args', 'url 不能为空', null, '', st);
    }
    const res = await WebList.list(url, keyword);
    const b = FinderTools.budget(st);
    ctx.hooks.onAction(res.ok ? `🔗 已列出链接清单（${res.items.length} 条）` : '🔗 列链接清单失败');
    const capped = res.items.slice(0, MAX_LINKS_REPLY);
    let note = res.note;
    if (res.items.length > capped.length) {
      // 回包自描述：截断必须说清还剩多少、怎么拿到，否则模型会拿半份目录当全量
      note = `${note}。注意：清单被截断——共 ${res.items.length} 条，只返回了前 ${capped.length} 条，` +
        `剩下的条目这次没有给。用 keyword 按标题换词分批拉取，或改用 html_to_book 直接传目录页链接（它会自动展开全部章节）`;
    }
    const payload: LinksReply = {
      status: res.ok ? 'ok' : 'failed',
      note: res.note,
      count: res.items.length,
      links: capped,
      steps_left: b.steps_left,
      hint: b.hint
    };
    return JSON.stringify(payload);
  }

  /**
   * check_pending：待入库区 + 书架的真实状态。
   * 模型对「抓过什么」的记忆会随对话压缩衰减，任务卡只是摘要不是账本——
   * 跨回合判断（要不要抓、抓到哪了）以这里的查询结果为准。
   */
  private static async checkPendingList(ctx: FinderCtx, st: FinderState): Promise<string> {
    const b = FinderTools.budget(st);
    const pend = await PendingStore.list(ctx.ui);
    const works = await WorkDao.list();
    const pending: PendingBrief[] = [];
    for (let i = 0; i < pend.length && i < 50; i++) {
      const it = pend[i];
      const brief: PendingBrief = {
        title: it.title, author: it.author, chapters: it.chapters,
        source_url: it.sourceUrl.length > 0 ? it.sourceUrl : ''
      };
      // 失败链接是「接着抓」的抓手：模型看到它就知道补抓哪几个，
      // 不用靠上一回合的对话记忆（早被压缩没了）
      if (it.failedUrls !== undefined && it.failedUrls.length > 0) {
        brief.failed_count = it.failedUrls.length;
        brief.failed_urls = it.failedUrls.slice(0, 5);
      }
      pending.push(brief);
    }
    const shelf: ShelfBrief[] = [];
    for (let i = 0; i < works.length && i < 100; i++) {
      const w = works[i];
      shelf.push({ title: w.title, author: w.author, chapters: w.chapterCount });
    }
    ctx.hooks.onAction(`📋 待入库 ${pend.length} 条，书架 ${works.length} 本`);
    const payload: PendingReply = {
      status: 'ok',
      pending_count: pend.length,
      shelf_count: works.length,
      pending: pending,
      shelf: shelf,
      note: `待入库区 ${pend.length} 条、书架 ${works.length} 本（各只列前一部分）。判断重复或补章前先对照这份清单`,
      steps_left: b.steps_left,
      hint: b.hint
    };
    return JSON.stringify(payload);
  }

  /**
   * http_probe：受限的原始请求。给模型探内部接口的能力，但把风险收窄：
   * 只 GET/POST、不能带 Cookie/自定义头、只许 Referer、禁内网地址、
   * 每回合次数上限，响应截断后再回包。
   */
  private static async httpProbe(args: Record<string, Object>, ctx: FinderCtx, st: FinderState): Promise<string> {
    const url = FinderTools.str(args, 'url');
    let method = FinderTools.str(args, 'method');
    method = method.length > 0 ? method.toUpperCase() : 'GET';
    const body = FinderTools.str(args, 'body');
    const bodyType = FinderTools.str(args, 'body_type');
    const referer = FinderTools.str(args, 'referer');
    const maxChars = Math.min(FinderTools.int(args, 'max_chars', 6000), MAX_PROBE_CHARS);
    const b = FinderTools.budget(st);
    if (url.length === 0) {
      return FinderTools.reply('bad_args', 'url 不能为空', null, '', st);
    }
    if (!/^https?:\/\//i.test(url)) {
      return FinderTools.reply('bad_args', '只支持 http/https 地址', null, '', st);
    }
    const host = FinderTools.hostOfUrl(url);
    if (FinderTools.isPrivateHost(host)) {
      return FinderTools.reply('bad_args', '不允许访问本机/内网地址', null, '', st);
    }
    if (st.probes >= MAX_PROBES) {
      const limited: ProbeReply = {
        status: 'limited', code: 0, content_type: '', chars: 0, truncated: false,
        text: '', markers: [], probes_left: 0,
        note: `本回合 ${MAX_PROBES} 次原始请求已用完。别再试探接口了：用手上已有的线索给结论，或建议用户换路`,
        steps_left: b.steps_left, hint: b.hint
      };
      return JSON.stringify(limited);
    }
    st.probes++;
    const res = await HttpFetch.request(method, url, referer, body, bodyType);
    Log.i(`http_probe ${method} ${url} → HTTP ${res.code}，${res.text.length} 字符`);
    const full = res.text;
    let text = full;
    const truncated = full.length > maxChars;
    if (truncated) {
      text = full.substring(0, maxChars);
    }
    const markers = SiteRules.markersIn(full);
    const payload: ProbeReply = {
      status: res.ok ? 'ok' : (res.code === 0 ? 'error' : 'http_error'),
      code: res.code,
      content_type: res.contentType,
      chars: full.length,
      truncated: truncated,
      text: text,
      markers: markers,
      probes_left: MAX_PROBES - st.probes,
      note: res.note.length > 0 ? res.note : FinderTools.probeHint(full),
      steps_left: b.steps_left,
      hint: b.hint
    };
    ctx.hooks.onAction(`🛰️ 已请求接口（HTTP ${res.code}）`);
    return JSON.stringify(payload);
  }

  /** 根据响应形态给一句判读提示，省模型一轮推理 */
  private static probeHint(text: string): string {
    const t = text.trim();
    if (t.indexOf('//#DWR-REPLY') >= 0) {
      return '这是 DWR 接口的返回：带 _remoteHandleCallback 说明成功，带 _remoteHandleException 说明参数不对（报错原文会说明缺什么）';
    }
    if (t.startsWith('{') || t.startsWith('[')) {
      return '响应是 JSON/JS 对象：可以据此推断字段路径，用 manage_site_rules(marker + json_content) 把它变成站点规则';
    }
    if (t.indexOf('<html') >= 0 || t.indexOf('<!DOCTYPE') >= 0) {
      return '响应是 HTML：可能被重定向到登录/验证页，或接口地址不对';
    }
    if (t.length === 0) {
      return '响应是空的：接口可能需要别的参数或鉴权';
    }
    return '响应是纯文本，看内容判断是否为接口数据';
  }

  private static hostOfUrl(url: string): string {
    const m = /^https?:\/\/([^/?#]+)/i.exec(url);
    if (m === null || m.length < 2) {
      return '';
    }
    let host = m[1].toLowerCase();
    const colon = host.indexOf(':');
    if (colon >= 0) {
      host = host.substring(0, colon);
    }
    return host;
  }

  /** 只拦本机与内网网段，不做严格域名白名单（要探的是任意长尾站） */
  private static isPrivateHost(host: string): boolean {
    if (host.length === 0) {
      return true;
    }
    if (host === 'localhost' || host === '0.0.0.0' || host === '::1' || host === '[::1]') {
      return true;
    }
    if (host.endsWith('.local') || host.endsWith('.internal') || host.endsWith('.lan')) {
      return true;
    }
    if (host.startsWith('127.') || host.startsWith('10.') || host.startsWith('192.168.') || host.startsWith('169.254.')) {
      return true;
    }
    if (host.startsWith('172.')) {
      const parts = host.split('.');
      if (parts.length >= 2) {
        const second = parseInt(parts[1], 10);
        if (second >= 16 && second <= 31) {
          return true;
        }
      }
    }
    return false;
  }

  private static bool(args: Record<string, Object>, key: string, def: boolean): boolean {
    const v = args[key];
    if (typeof v === 'boolean') {
      return v;
    }
    if (typeof v === 'string') {
      return v === 'true' || v === '1';
    }
    return def;
  }

  /**
   * 工具层查重：落盘前拦住重复抓取/下载，别让用户看到同一本书下了两遍。
   *
   * 只在「身份足够强」时才拦，宁可不拦也不错杀：
   * - 待入库区 sourceUrl 精确匹配（同一地址反复下）；
   * - 待入库区 / 书架的 标题+作者键匹配（双方作者都非空才比，
   *   佚名和佚名的同名书是两回事，不能互撞）。
   *
   * 章节数可比时（newChapters > 0 且旧版也有章数），新版更全就放行，
   * 并清掉旧 pending 条目——这是「连载追更 / 上次没抓全再抓一次」的通道；
   * 放行后的书架替换由 Importer 入库时兜底（allowReplace）。
   */
  private static async checkDup(ctx: FinderCtx, title: string, author: string,
    sourceUrl: string, newChapters: number): Promise<DupHit | null> {
    const key = (title.length > 0 && author.length > 0) ? Dedupe.keyOf(title, author) : '';
    if (sourceUrl.length === 0 && key.length === 0) {
      return null;
    }
    const pend = await PendingStore.list(ctx.ui);
    for (let i = 0; i < pend.length; i++) {
      const it = pend[i];
      const urlHit = sourceUrl.length > 0 && it.sourceUrl === sourceUrl;
      const keyHit = key.length > 0 && it.author.length > 0 &&
        Dedupe.keyOf(it.title, it.author) === key;
      if (urlHit || keyHit) {
        // URL 精确命中时 >= 即可覆盖（同源重抓：旧条目有毛病要换新的，或补抓后章数持平）；
        // 待入库条目还没入库、没有译文/进度，覆盖无损。key 命中（不同来源同书）
        // 维持严格 >，防止别的站抓的同名书把旧版冲掉。
        const coverable = urlHit && newChapters > 0 && it.chapters > 0 && newChapters >= it.chapters;
        if (newChapters > 0 && it.chapters > 0 && (newChapters > it.chapters || coverable)) {
          await PendingStore.remove(ctx.ui, it);
          ctx.hooks.onAction(`　　待入库区已有旧版（${it.chapters} 章），本次规模更大（${newChapters}），清掉旧版重抓`);
          return null;
        }
        return { where: 'pending', title: it.title, chapters: it.chapters, item: it };
      }
    }
    if (key.length === 0) {
      return null;
    }
    const w = await WorkDao.findByDedupeKey(key);
    if (w !== null) {
      if (newChapters > 0 && w.chapterCount > 0 && newChapters > w.chapterCount) {
        ctx.hooks.onAction(`　　书架已有旧版（${w.chapterCount} 章），本次抓到 ${newChapters} 章更全，继续（入库时替换旧版）`);
        return null;
      }
      return { where: 'shelf', title: w.title, chapters: w.chapterCount, item: null };
    }
    return null;
  }

  /** 查重命中时给模型的解释：说清在哪、让它怎么转述 */
  private static dupNote(hit: DupHit): string {
    if (hit.where === 'shelf') {
      return `这本已在书架（${hit.chapters} 章），不要重复下载，直接告诉用户书架里已经有这本`;
    }
    return `这本之前已抓过（${hit.chapters} 章），就在待入库区等用户确认入库，不要重复下载`;
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

  /** 从参数里取整数数组（add_chapters 的 numbers）；解析不了的按 0 占位，保持对齐 */
  private static numList(args: Record<string, Object>, key: string): number[] {
    const out: number[] = [];
    const v = args[key];
    if (Array.isArray(v)) {
      const arr = v as Object[];
      for (let i = 0; i < arr.length; i++) {
        const n = Number(arr[i]);
        out.push(Number.isNaN(n) ? 0 : Math.max(0, Math.floor(n)));
      }
    }
    return out;
  }

  /** 从参数里取字符串数组（sources/books）；也容忍模型把单个值塞成字符串 */
  private static strList(args: Record<string, Object>, key: string): string[] {
    const out: string[] = [];
    const v = args[key];
    if (Array.isArray(v)) {
      const arr = v as string[];
      for (let i = 0; i < arr.length; i++) {
        const e = arr[i];
        if (typeof e === 'string' && e.trim().length > 0) {
          out.push(e.trim());
        }
      }
    } else if (typeof v === 'string' && (v as string).trim().length > 0) {
      out.push((v as string).trim());
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
