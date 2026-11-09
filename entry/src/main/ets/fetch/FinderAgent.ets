import { common } from '@kit.AbilityKit';
import { ProviderConfig } from '../common/Settings';
import { AssistantTurn, ChatMessage, LlmProvider, ToolCallShape } from '../provider/LlmProvider';
import { FicHubError } from './FicHub';
import { SiteRules } from './SiteRules';
import { FinderCtx, AgentHooks, FinderResult, MAX_ROUNDS, RunControl } from './FinderTypes';
import { FinderState, FinderTools } from './FinderTools';
import { Log } from '../common/Logger';

/**
 * 找文 Agent。
 *
 * 与上一版的根本区别：上一版把「搜索 → 核实 → 下载 → 收尾」写死成工作流，
 * FicHub 是流程里不可跳过的一道闸门，模型只是在执行我们的编排。结果就是
 * 它被限制死，稍微换个场景（站点不支持、限流、用户想要别的来源）就卡住。
 *
 * 这一版把决定权交回模型：给它一组通用能力（搜索、读网页、探测、转换、
 * 直接下载），系统提示词只讲「你有什么、每个多贵、哪些事绝对不能做」，
 * 具体怎么组合、先做哪个、要不要用 FicHub，全由它在循环里自己判断。
 *
 * 唯一的预算是单回合步数（可在过程中被用户随时中断），剩余步数会随
 * 工具返回告诉模型，它自己安排。
 */

const FINDER_SYSTEM: string = `你是这个阅读应用里的找文助手。用户想读某篇同人文，你的任务是把「整本书」弄到本地待入库区，等他确认后进书架。

工具是你的能力，不是必须走的步骤，顺序由你决定：

- web_search(query, max_results?) — 联网搜索，返回标题、链接、摘要。成本很低，适合还不知道具体是哪篇时找线索。
- fetch_page(url, max_chars?) — 打开网页读正文（脚本样式会被去掉，长页面会截断）。想确认某个链接是不是那篇文、看章节数、读推荐榜单时用它。它只读网页，不会把网页变成书。页面是 JS 动态渲染（如知乎专栏正文、部分单页应用）时它会自动改用内置浏览器渲染，能读到但每页要多等十几秒，别在一步里并发太多渲染请求。
- fichub_get(url) — 把作品页变成 EPUB 放进待入库区，一步到位。它会先花十几秒探 FicHub 有没有缓存，命中就直接取；没命中会继续等它现场抓源站转换，可能一两分钟。站点不支持或被限流时会失败并说明原因。
- html_to_book(urls, title?, author?) — 把网页抓成本地书放进待入库区，urls 按阅读顺序传数组（每个网页合成一章，单页也行）。这是 FicHub 不支持的站点的兜底路：LOFTER、晋江免费章节、博客、论坛帖子串都能收。**连载长篇可以直接传目录页/作品页链接**：工具认出目录页会自动展开全部章节链接逐页抓，不用你把几百个章节链接一个个抠出来（list_links 有 300 条上限，目录更长时直传目录页最稳）。数量上限 300 页：把全部章节链接一次传齐、合成同一本书也行，不用分批；个别页抓不到会在回包里列出失败位置，不影响其余页面。命中站点规则的站按规则直接抽取（快）；否则静态页直抓，JS 动态渲染的页面会自动用内置浏览器渲染后重试（每页多十几秒）。
- download_file(url, title?, author?) — 直接下载任意 URL 上的文件，EPUB/TXT 会自动放进待入库区。手上已经有文件直链时用它。
- debug_fetch(url) — 网页体检报告：HTTP 状态、字节数、标题、可见文本量、直抓能抽出多少段、源码里的内嵌数据标记（正文藏在源码 JSON 里的信号）和 JSON 结构速览、站点规则命中情况、正文预览。只直抓不渲染。判断不了某个站是什么形态、或 html_to_book 失败想弄清原因时，先调它。
- manage_site_rules(action, ...) — 站点抓取规则的增删查。规则告诉 html_to_book 某个站怎么抽正文（内嵌 JSON 路径或正文元素选择器），存在本地立即生效。list 列出规则；add 添加/覆盖（url_pattern + marker+json_content 或 selector）；remove 删除自定义规则。
- read_recent_logs(lines?) — 读应用最近的运行日志。工具失败但回包没说清原因时调它，日志里有渲染抽取的字节数、正文字符数、HTTP 错误等现场。
- list_links(url, keyword?) — 列出网页上的链接清单。LOFTER 博客传主页或任意一篇帖子的链接：自动走归档接口拿到整个博客的文章清单（标题+链接+发布日期，按时间正序），免登录。其它站点解析页面里的站内 <a> 链接，最多返回 300 条（超出会截断并说明）。keyword 按标题过滤。
- check_pending() — 查待入库区和书架的真实状态（书名/作者/章数/来源链接）。跨回合判断「这本抓没抓过、抓到哪一章」时调它，不要凭对话记忆猜。
- http_probe(url, method?, body?, body_type?, referer?) — 直接发一个 HTTP 请求看原始响应（只 GET/POST、不能带 Cookie、只能加 Referer，每回合最多 6 次）。用来探某个站的内部接口：页面只有空壳又没有内嵌数据时，可以试它的 JSON 接口（从页面脚本里找可疑地址），先 GET 再试 POST 表单参数，报错原文通常就说明了缺什么。探到规律就落地（写站点规则或直接 html_to_book），不要靠它反复试。

一次可以发多个工具调用。互不依赖的操作要一次发出来：比如同时探测 3 个链接、同时读 2 个页面。同一轮里的多个调用只消耗一步，一个一个发是最费步数的做法。

站内搜索入口 —— 晋江、LOFTER 这类站对通用搜索引擎几乎不可见，web_search 往往只能搜到二手榜单，直接拼它们的搜索/列表页更快：
- 晋江文学城搜索：https://www.jjwxc.net/search.php?kw=关键词&t=1 —— t 给 1（按文章标题）或 2（按作者）。结果页是静态 HTML，fetch_page 直读即可（不需要渲染），作品链接形如 onebook.php?novelid=数字。这个站是老式 GBK 编码，我们发出去的是 UTF-8，中文关键词匹配可能不准：结果条数明显不对（个位数或 0）时不要反复调参，改用 web_search 找书名，或直接把 onebook.php 链接交给 html_to_book。
- 晋江的签约 VIP 作品第 5 章起是锁章：免登录打开会返回「用户登入」页。免登录能拿到的只有目录页和免费章节，抓到免费部分就收尾，把「这份只含免费章节」说清楚让用户决定，别去试第 30、100 章（真机实测白花三四步）。
- LOFTER 标签页 https://www.lofter.com/tag/标签名 现在 302 跳登录页，直抓和渲染都拿不到东西，别浪费步数。LOFTER 要目录就走 list_links（见上）。
- LOFTER 抓系列文/合集的关键路：博客主页、搜索页、标签页都要登录直抓拿不到任何东西，别浪费步数去试。正确姿势是从任意一篇帖子链接出发（用户给的链接、web_search 搜到的都行）调 list_links，它免登录列出该博客全部文章的标题+链接+日期，按发布时间正序，再挑目标章节传 html_to_book。
- 微博要分清两种：单条微博（m.weibo.cn/status/…、weibo.com/…/status/…）是登录墙，访客令牌只能拿到空壳，html_to_book 抓不到就直接建议用户换路，别用 http_probe 试探；而微博「头条文章」（weibo.com/ttarticle/p/show?id=…）免登录，html_to_book 直抓就能拿到全文——用户给的若是一条微博，问问是不是长文形式、能否拿到文章链接。
- 百度贴吧帖子直接用用户给的链接就行：抓取层会自动换成能翻页、只看楼主的移动版，不用你拼地址，也不用渲染（/p/ 匿名打开是「贴吧小程序」空壳，硬试渲染也是空壳）。回包里的分页提示会说这帖共几页、后面几页怎么拿——照它把各页链接一次放进 urls，别把一页 30 楼当整本交货。
- 知乎（zhihu.com、zhuanlan.zhihu.com）的 403 是它的 zse-ck 反爬挑战页，不是地区或 UA 问题：直抓、http_probe、debug_fetch 一定都是 403，api.zhihu.com 也照样要签名，别在这些路上花步数。html_to_book / fetch_page 遇到 403 会自动让内置浏览器跑一次，但实测它多半也停在那一张校验页上（拿回来只有几十字符）。回包里出现「仍停在站点校验页」就是这条路走死，直接收手建议用户分享链接或复制正文，**不要对同一条链接再渲染第二次**——重试结果一样，第二次起会直接返回上次的结论。说清是「站方的 JS 校验」就行，别把它说成滑块/验证码——用户照着去找拖动条会找不到。
- 有些站的正文只能从接口拿（页面本身是空壳）。html_to_book 能直接吃接口地址：用 http_probe 确认接口响应里有正文后，用 manage_site_rules 写一条 marker（如 "data":）+ json_content（如 data.content）的规则，再把接口地址交给 html_to_book。B 站专栏这条已内置接口路：专栏链接直接交给 html_to_book 就行，接口偶尔 -509 限流，等十几秒再试一次。
- 用户如果说「别用内置规则、你自己想办法」或要验证自愈能力，就用 manage_site_rules(action=disable, url_pattern=对应站) 把那条规则停掉，然后按 debug_fetch → 推断路径 → add 规则 → html_to_book 验证的流程自己重做一遍，做完记得 enable 恢复。
- 模板可能随站点改版失效：某个入口连续失败就退回 web_search，不要死磕模板。

怎么组合由你判断。下面是一些经验，不是规定：
- 已经确定要这本且站点在 FicHub 支持范围内（AO3、FanFiction.net、SpaceBattles、SufficientVelocity、FictionPress 等），直接 fichub_get，不要再单独探一次 —— 它自己会先探缓存再决定等多久，多调一步只是白等十几秒。
- 中文站点（LOFTER、晋江、博客、论坛等）FicHub 不支持：先 fetch_page 或 web_search 确认链接，然后用 html_to_book。一篇文拆成多帖/多章连载时，把按阅读顺序的链接凑齐，一次传给 urls 合成一本；搜到的每章链接也可以先批量 fetch_page 确认顺序。
- html_to_book 仍抓不到正文时按这个顺序排障，不要盲目重试：
  1) debug_fetch 看体检报告，照它给的结论走，别自己猜「有标记就是正文在里面」（国内能直抓的内嵌正文站点很少，别默认每个站都像 LOFTER）：
     · json_max_text ≥ 600 = 正文确实在源码 JSON 里，按 data_outline 的路径用 manage_site_rules(add) 写规则（marker 填标记名，json_content 填正文路径，猜不准就挑 outline 里最长的那个字段），再重试 html_to_book。规则写对一次，这个站以后永远直抓。
     · json_max_text < 600 = 内嵌数据只有标题封面这类元信息，正文是接口异步塞进 DOM 的，**别写规则**（怎么写都抽不到），直接让 html_to_book / fetch_page 走内置渲染。
     · 没有内嵌标记、可见文本又极少 = 同上，走渲染，不用试规则。
  2) 渲染也抽不到正文时看 read_recent_logs 里的正文字符数：渲染抽到了字数就直接用结果，还是 0 就是登录墙/风控。若你判断这个站有可免登录的数据接口（同平台常有固定 pattern），可以用 http_probe 试一两次：从页面脚本里找可疑地址，先 GET，再试 POST 表单参数。报错原文会告诉你缺什么参数——探通了就把结果变成规则或直接抓书，别把 6 次预算全花在猜参数上。
  3) **区分「裸请求被拦」和「真抓不到」**：403 先看回包里有没有「已用内置浏览器渲染」。直抓被风控拦时 html_to_book / fetch_page 会自动让内置浏览器重试一次，回包没提渲染就是你还没让渲染跑过 —— 先跑，再判断。回包说「页面只抽到几十字，是壳页」同理：源码里没有正文，改走渲染或接口。渲染跑了仍然报「仍停在站点校验页」「需要登录」才是真墙：同一个站别再用 debug_fetch / http_probe 重复撞（它们走直抓，和裸请求是同一堵墙），也别试境外代理/镜像（r.jina.ai 之类在国内解析不了，纯浪费一步）。直接收手，建议用户换路：在浏览器里打开文章、等正文显示后把链接分享给本应用，或复制正文存成 TXT / 打印成 PDF 从「导入本地文件」进来。同样的 URL 反复抓结果不会变。
- FicHub 限流时别死磕：换 html_to_book 或搜 EPUB/TXT 直链走 download_file。
- 搜索结果只有几行摘要，别只凭标题猜内容；要确认就 fetch_page 打开看。
- 同一个 URL 不要反复调同一个工具，结果不会变。
- 下载/抓书类工具会自己查重（待入库区和书架）：返回 status=exists 说明这本已经有了，照着 note 转述给用户即可，不要重试同一个链接。用户明确说「重新抓一遍/补全章节」时才再调，工具发现新版更全会自动放行。
- 书不完整（拆成几段、缺几章、连载出新章）时用 add_chapters 收口：target 传目标书（**待入库条目或书架作品都行**），sources 传要补的内容（待入库条目或网页链接）。目标在待入库 → 合成一本新的；目标在书架 → 新章按章号插到正确位置，已有章和译文/进度不动。**内容已经在本地时不要让用户去补链接**。目标书现在抓到哪几章，用 check_pending 查（回包里有章数，待入库条目还带每章来源链接）。来源网页标题里读不出「第N章」时（LOFTER 帖子页很常见），把章号按顺序放进 numbers 参数（例：补第 20、30 章 → [20,30]），否则新章只能追加在末尾。回包带「按章号看缺：20、30」就把这些章抓了再 add_chapters 一次；参数传错会返回待入库区和书架的完整清单，照着改再调。
- LOFTER 归档接口有返回条数上限（常只给最近 150 篇），目录里的章拿不全时：能拿到的段先抓成书，缺的段等用户补链接或用合集分享页抓，最后统一 add_chapters 收成一本，别反复重试同一个归档接口。

预算：这一回合你最多有 ${MAX_ROUNDS} 步，每次工具返回都会告诉你 steps_left 还剩几步。开头大胆探索，剩 3 步左右就别再开新线索了，把已确认的作品拿到手、然后收尾 —— 不要走到步数用尽被硬截断，那样用户只能看到一句干巴巴的报错。

关于记忆：对话开头有一条 [任务卡] 消息，它是更早对话的压缩摘要（用户的原始需求、口味偏好、已下载和已排除的作品）。回应用户的长期诉求以它为准，但最近的对话永远优先；已下载过的作品在任务卡里会有记录，不要重复下载。

硬性要求：
- 只能用工具返回过的链接和元信息，绝不编造 URL、作品名或作者。确实找不到就直说没找到。
- 搜到符合需求的作品，当场就把它下下来，不要下之前先问用户「要不要下」、也不要只给一串链接让用户自己挑 —— 用户点一下就能在书架看到，这才是这个助手的价值。
- 一条消息里通常下 2-3 本候选（明显符合的都要下），让用户有点挑选余地；但如果搜索结果里大半不相关，只下真正对得上的那几本。
- 同一本不要下第二次：拿不准就先调 check_pending 查一下待入库区和书架的真实清单（对话记忆会衰减，账本以查询为准）。已经在待入库区或已入架的作品，告诉用户就好。
- 只有真的把书放进待入库区才算「找到了」，只搜到链接不算。

说话风格：中文，简洁，不要复述工具返回的原始 JSON。每次调用工具之前，用一两句话说明你此刻的判断和打算（这段话会直接展示给用户当你的思考过程），说人话，不要写成编号计划。全部做完后收尾：下了哪几本、分别是什么、有没有没找到的、下一步建议。`;

/** 发给模型的窗口里保留的最近消息条数（不含 system 与任务卡），对话越长越贵 */
const MAX_HISTORY: number = 24;

/** 非系统消息超过这个条数就触发一次任务卡压缩：一轮工具循环平均消耗 6~10 条消息 */
const COMPACT_MIN_SLICE: number = 12;

/** 压缩时额外保留的余量：防止压完下一句立刻又触发 */
const COMPACT_SLACK: number = 8;

/** 窗口内保留全文的工具轮数；更早轮次的 tool 回复压成一行摘要 */
const TOOL_FULL_GROUPS: number = 2;

/** 任务卡消息的固定前缀：靠它识别（落盘恢复时保留、窗口发送时带上） */
export const CARD_MARK: string = '[任务卡]';

const COMPACT_SYSTEM: string =
  '你是找文助手的会话压缩器。把给定的对话片段压缩成一张「任务卡」，作为后续对话的长期记忆。' +
  '必须保留：用户的核心需求与口味偏好；已确认或已下载到待入库区的作品（书名、作者、章节数）；' +
  '明确排除的候选及原因；尚未完成的线索与下一步打算。不要编造、不要客套，条目式，300 字以内。';

export class FinderAgent {
  /**
   * 当前系统提示词。恢复历史会话时用它替换存下来的那一份 ——
   * 否则老会话会带着几周前的提示词继续跑（提示词改过之后尤其明显）。
   */
  static systemPrompt(): string {
    return FINDER_SYSTEM;
  }

  /**
   * 跑一个回合：把用户这条消息交给模型，循环执行它请求的工具，
   * 直到它给出不带 tool_calls 的回复（或轮次用尽）。
   * history 由调用方持有并跨回合复用 —— 这就是"对话记忆"。
   */
  static async chatTurn(history: ChatMessage[], cfg: ProviderConfig, ui: common.UIAbilityContext,
    hooks: AgentHooks, ctrl: RunControl): Promise<FinderResult> {
    // 老会话恢复时 SearchPage 已把 system 换好；新会话这里补上。
    // 注意不能用 history.length === 0 判断：调用方在这之前已经 push 了
    // 用户消息，按条数判断会导致 system 提示词从未进入对话。
    let hasSystem = false;
    for (let i = 0; i < history.length; i++) {
      if (history[i].role === 'system' && !history[i].content.startsWith(CARD_MARK)) {
        hasSystem = true;
        break;
      }
    }
    if (!hasSystem) {
      const sys: ChatMessage = { role: 'system', content: FINDER_SYSTEM };
      history.unshift(sys);
    }
    if (!ctrl.cancelled) {
      // 上下文压缩：历史太长时把窗口外的内容压成一张任务卡塞回 system 区，
      // 这样用户的原始需求、已下载的结论不会被裸截断丢掉
      await FinderAgent.compact(history, cfg);
    }
    const provider = new LlmProvider(cfg);
    // 把「立刻打断在途请求」的能力交给取消令牌，用户点停止时才不是在干等
    ctrl.bind(() => {
      provider.abort();
    });
    const tools = FinderTools.defs();
    const ctx: FinderCtx = { cfg: cfg, ui: ui, hooks: hooks };
    // 站点规则引擎的存储目录（用户自定义抓取规则的持久化位置）
    SiteRules.init(ui.filesDir);
    const st: FinderState = FinderTools.newState();

    let finalText = '';
    try {
      for (let round = 1; round <= MAX_ROUNDS; round++) {
        if (ctrl.cancelled) {
          break;
        }
        // 把当前轮次写进状态，工具据此算出 steps_left 回喂给模型
        st.round = round;
        hooks.onStatus(round === 1 ? '模型正在思考…' : `第 ${round}/${MAX_ROUNDS} 步 · 模型正在思考…`);
        const send: ChatMessage[] = FinderAgent.withProgress(FinderAgent.window(history), st);
        // 这一轮的输出先落在一个流式气泡里，收到第一个字就开始显示
        const bubbleId = hooks.onRoundStart();
        let turn: AssistantTurn;
        try {
          turn = await provider.callWithToolsStream(send, tools, (acc: string) => {
            hooks.onThinkDelta(bubbleId, acc);
          });
        } catch (e) {
          hooks.onRoundEnd(bubbleId, true);
          if (ctrl.cancelled) {
            break;
          }
          const msg = (e as Error).message;
          Log.e(`找文第 ${round} 轮失败：${msg}`);
          if (msg.includes('tool') || msg.includes('400')) {
            throw new FicHubError(`模型请求失败（当前模型可能不支持工具调用，可换 deepseek-flash / qwen-plus 试试）：${msg}`);
          }
          throw new FicHubError(`模型请求失败：${msg}`);
        }

        // 流到一半被停止：这一轮的产出不完整，直接丢弃走收尾
        if (ctrl.cancelled) {
          hooks.onRoundEnd(bubbleId, true);
          break;
        }

        if (turn.toolCalls.length === 0) {
          // 没有工具调用 = 模型认为可以说完了，这条气泡就是最终回复
          hooks.onRoundEnd(bubbleId, true);
          finalText = turn.content.trim();
          const done: ChatMessage = { role: 'assistant', content: finalText };
          history.push(done);
          break;
        }

        // 有工具调用：这条气泡只是模型的判断说明，定格成思考样式
        hooks.onRoundEnd(bubbleId, false);
        const echo: ChatMessage = { role: 'assistant', content: turn.content, tool_calls: turn.toolCalls };
        history.push(echo);
        for (let i = 0; i < turn.toolCalls.length; i++) {
          if (ctrl.cancelled) {
            break;
          }
          const call = turn.toolCalls[i];
          const resultJson = await FinderAgent.runTool(call, ctx, st);
          const reply: ChatMessage = {
            role: 'tool',
            content: resultJson,
            tool_call_id: call.id
          };
          history.push(reply);
        }
      }
    } finally {
      ctrl.unbind();
    }

    if (ctrl.cancelled) {
      // 中断时可能留下「有 tool_calls 但缺 tool 回复」的半截历史，
      // 不补齐的话用户下一句话会被服务端 400 驳回
      FinderAgent.sealPendingCalls(history);
      finalText = st.downloaded.length > 0 ?
        `已停止。停之前下好了 ${st.downloaded.length} 本，都在待入库区，随时可以确认入库。` :
        '已停止。';
      const id = hooks.onRoundStart();
      hooks.onThinkDelta(id, finalText);
      hooks.onRoundEnd(id, true);
      const tail: ChatMessage = { role: 'assistant', content: finalText };
      history.push(tail);
    } else if (finalText.length === 0) {
      // 轮次用尽：把已下到的结果如实告诉用户，别让他对着半截对话猜
      finalText = st.downloaded.length > 0 ?
        `这一轮下了 ${st.downloaded.length} 本（见上方卡片）。${MAX_ROUNDS} 步跑完了，还想继续找直接说一声。` :
        `这一轮 ${MAX_ROUNDS} 步跑完了，还没拿到可下载的作品。可以换个说法，或者直接把作品页链接发给我。`;
      const id = hooks.onRoundStart();
      hooks.onThinkDelta(id, finalText);
      hooks.onRoundEnd(id, true);
      const tail: ChatMessage = { role: 'assistant', content: finalText };
      history.push(tail);
    }
    Log.i(`回合完成：${st.hits.length} 次命中，${st.downloaded.length} 本已下载，历史 ${history.length} 条`);
    return { hits: st.hits, downloaded: st.downloaded, finalText: finalText };
  }

  /**
   * 中断后收尾：把最后一条 assistant(tool_calls) 后面缺失的 tool 回复补齐。
   *
   * OpenAI 兼容接口要求每个 tool_call 都有对应的 tool 消息，缺一条整段
   * 历史就是非法的 —— 用户停止后再说下一句，请求会被服务端 400 驳回。
   */
  private static sealPendingCalls(history: ChatMessage[]): void {
    let idx = -1;
    for (let i = history.length - 1; i >= 0; i--) {
      if (history[i].role === 'user') {
        break;
      }
      if (history[i].role === 'assistant' && history[i].tool_calls !== undefined) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    const calls = history[idx].tool_calls;
    if (calls === undefined || calls === null) {
      return;
    }
    const answered: string[] = [];
    for (let i = idx + 1; i < history.length; i++) {
      const cid = history[i].tool_call_id;
      if (history[i].role === 'tool' && cid !== undefined && cid !== null) {
        answered.push(cid);
      }
    }
    for (let i = 0; i < calls.length; i++) {
      if (answered.indexOf(calls[i].id) < 0) {
        const reply: ChatMessage = {
          role: 'tool',
          content: JSON.stringify({ status: 'aborted', note: '用户中断了这一轮，这个工具没有执行' }),
          tool_call_id: calls[i].id
        };
        history.push(reply);
      }
    }
  }

  /**
   * 发给模型的窗口：主 system + 最新任务卡 + 最近 MAX_HISTORY 条。
   *
   * 相比裸截断多做了两层上下文工程：
   * 1. 窗口外不丢——被截掉的历史已被 compact() 压成任务卡随窗口发送；
   * 2. 窗口内分层——最近 TOOL_FULL_GROUPS 轮的工具回包保留全文，
   *    更早轮次的 tool 消息压成一行（tool 回包动辄几千字符，是窗口的
   *    大头；不压的话 24 条里全是大 JSON，user/assistant 反而被挤出）。
   *
   * 掐头时必须跳过 role=tool —— 孤立的 tool 消息前面没有对应的
   * assistant(tool_calls)，会被服务端 400 驳回。
   */
  /**
   * 状态外化：把本轮工具已经做到的事（命中/已下载）渲染成一段「当前进度」
   * 附加到 system 上。数据就在 FinderState 里，零成本——但模型看见它就不会
   * 重复下载、忘记自己下过什么。只改发送副本，不污染存储的历史。
   */
  private static withProgress(send: ChatMessage[], st: FinderState): ChatMessage[] {
    const note = FinderAgent.progressNote(st);
    if (note.length === 0) {
      return send;
    }
    const out: ChatMessage[] = [];
    for (let i = 0; i < send.length; i++) {
      const m = send[i];
      if (m.role === 'system') {
        const copy: ChatMessage = { role: 'system', content: `${m.content}\n\n${note}` };
        out.push(copy);
      } else {
        out.push(m);
      }
    }
    return out;
  }

  private static progressNote(st: FinderState): string {
    if (st.hits.length === 0 && st.downloaded.length === 0) {
      return '';
    }
    const lines: string[] = ['[当前进度]（本轮工具的真实产出，回复和决策以此为准，下面的作品不要重复下载）'];
    for (let i = 0; i < st.hits.length; i++) {
      const m = st.hits[i];
      lines.push(`· 命中：《${m.title}》${m.author.length > 0 ? `（${m.author}）` : ''}${m.chapters > 0 ? ` ${m.chapters} 章` : ''}`);
    }
    for (let i = 0; i < st.downloaded.length; i++) {
      const it = st.downloaded[i];
      lines.push(`· 已下载到待入库区：《${it.title}》${it.chapters} 章`);
    }
    return lines.join('\n');
  }

  private static window(history: ChatMessage[]): ChatMessage[] {
    const out: ChatMessage[] = [];
    // 主提示词 + 最新任务卡（正常只有一个卡；兜底：旧的覆盖成最新的）
    let mainSys: ChatMessage | null = null;
    let card: ChatMessage | null = null;
    for (let i = 0; i < history.length; i++) {
      const m = history[i];
      if (m.role !== 'system') {
        continue;
      }
      if (m.content.startsWith(CARD_MARK)) {
        card = m;
      } else if (mainSys === null) {
        mainSys = m;
      }
    }
    if (mainSys !== null) {
      out.push(mainSys);
    }
    if (card !== null) {
      out.push(card);
    }
    // 尾部：最近 MAX_HISTORY 条非系统消息（倒序收集再翻回来）
    const tail: ChatMessage[] = [];
    for (let i = history.length - 1; i >= 0 && tail.length < MAX_HISTORY; i--) {
      if (history[i].role !== 'system') {
        tail.push(history[i]);
      }
    }
    tail.reverse();
    let start = 0;
    while (start < tail.length && tail[start].role === 'tool') {
      start++;
    }
    // 找出「较早轮次」的工具调用 id：从后往前数 assistant(tool_calls) 组，
    // 最近 TOOL_FULL_GROUPS 组保留全文，更早组的 tool 回包压成一行
    const stubNames: Record<string, string> = {};
    let groups = 0;
    for (let i = tail.length - 1; i >= 0; i--) {
      const m = tail[i];
      if (m.role === 'assistant' && m.tool_calls !== undefined && m.tool_calls !== null) {
        groups++;
        if (groups > TOOL_FULL_GROUPS) {
          for (let j = 0; j < m.tool_calls.length; j++) {
            stubNames[m.tool_calls[j].id] = m.tool_calls[j].function.name;
          }
        }
      }
    }
    for (let i = start; i < tail.length; i++) {
      const m = tail[i];
      const stubName = m.tool_call_id !== undefined ? stubNames[m.tool_call_id] : undefined;
      if (m.role === 'tool' && stubName !== undefined) {
        const stub: ChatMessage = {
          role: 'tool',
          content: JSON.stringify({ status: 'archived', tool: stubName,
            note: '这是较早轮次的工具结果，内容已压缩。关键结论见任务卡与上文对话' }),
          tool_call_id: m.tool_call_id
        };
        out.push(stub);
      } else {
        out.push(m);
      }
    }
    return out;
  }

  /**
   * 历史超过阈值时把窗口外的片段压成任务卡。
   *
   * 切割点必须落在某个 user 消息上：工具回包永远跟着它的 assistant(tool_calls)，
   * 只有从 user 边界切才不会把一组 tool_call 拆成两半（拆了服务端 400）。
   * 压缩失败静默跳过——宁可让模型少点记忆，也不能让一句「总结一下」把回合炸掉。
   */
  private static async compact(history: ChatMessage[], cfg: ProviderConfig): Promise<void> {
    // 定位卡与可压缩区间：history[0] 是主 system，卡（若有）紧跟其后
    let cardIdx = -1;
    let start = history.length > 0 && history[0].role === 'system' ? 1 : 0;
    if (start < history.length && history[start].role === 'system'
      && history[start].content.startsWith(CARD_MARK)) {
      cardIdx = start;
      start++;
    }
    const limit = history.length - MAX_HISTORY - COMPACT_SLACK;
    if (limit - start < COMPACT_MIN_SLICE) {
      return;
    }
    let cut = limit;
    while (cut < history.length && history[cut].role !== 'user') {
      cut++;
    }
    if (cut >= history.length) {
      // 没有安全边界（比如尾部一轮特别长）：把整轮留给窗口，下句再压
      return;
    }
    const oldCard = cardIdx >= 0 ? history[cardIdx].content : '';
    const slice = history.slice(start, cut);
    try {
      const provider = new LlmProvider(cfg);
      const summary = await provider.complete([
        { role: 'system', content: COMPACT_SYSTEM },
        {
          role: 'user',
          content: `${oldCard.length > 0 ? `已有任务卡（请合并而非丢弃其中的结论）：\n${oldCard}\n\n` : ''}` +
            `请把下面的对话片段压缩成新的任务卡：\n${FinderAgent.digestSlice(slice)}`
        }
      ], () => {});
      const text = summary.trim();
      if (text.length === 0) {
        return;
      }
      // 替换：删掉被压缩的片段与旧卡，插入新卡
      history.splice(start, cut - start);
      if (cardIdx >= 0) {
        history.splice(cardIdx, 1);
      }
      const pos = cardIdx >= 0 ? cardIdx : start;
      const newCard: ChatMessage = { role: 'system', content: `${CARD_MARK}\n${text}` };
      history.splice(pos, 0, newCard);
      Log.i(`任务卡压缩：并入 ${slice.length} 条消息，历史 ${history.length} 条`);
    } catch (e) {
      Log.w(`任务卡压缩失败（忽略）：${(e as Error).message}`);
    }
  }

  /** 把一段历史压成给压缩模型看的纯文本提纲 */
  private static digestSlice(slice: ChatMessage[]): string {
    const lines: string[] = [];
    const names = new Map<string, string>();
    for (let i = 0; i < slice.length; i++) {
      const m = slice[i];
      if (m.role === 'assistant' && m.tool_calls !== undefined && m.tool_calls !== null) {
        for (let j = 0; j < m.tool_calls.length; j++) {
          names.set(m.tool_calls[j].id, m.tool_calls[j].function.name);
        }
        lines.push(`【助手】${FinderAgent.clip(m.content, 200)}（随后调用工具）`);
      } else if (m.role === 'tool') {
        const cid = m.tool_call_id !== undefined ? m.tool_call_id : '';
        const nm = names.get(cid);
        const label = nm === undefined || nm.length === 0 ? '未知' : nm;
        lines.push(`【工具 ${label}】${FinderAgent.clip(m.content, 150)}`);
      } else if (m.role === 'user') {
        lines.push(`【用户】${FinderAgent.clip(m.content, 500)}`);
      } else {
        lines.push(`【助手回复】${FinderAgent.clip(m.content, 500)}`);
      }
    }
    return lines.join('\n');
  }

  private static clip(s: string, max: number): string {
    const t = s.replace(/\s+/g, ' ').trim();
    return t.length > max ? `${t.substring(0, max)}…` : t;
  }

  private static async runTool(call: ToolCallShape, ctx: FinderCtx, st: FinderState): Promise<string> {
    const name = call.function.name;
    let args: Record<string, Object> = {};
    try {
      args = JSON.parse(call.function.arguments) as Record<string, Object>;
    } catch (e) {
      return JSON.stringify({ status: 'bad_args', note: '工具参数不是合法 JSON' });
    }
    try {
      return await FinderTools.run(name, args, ctx, st);
    } catch (e) {
      const why = (e as Error).message;
      Log.e(`工具 ${name} 执行异常：${why}`);
      return JSON.stringify({ status: 'error', note: `工具执行出错：${why}` });
    }
  }
}
