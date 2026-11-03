import { common } from '@kit.AbilityKit';
import { ProviderConfig } from '../common/Settings';
import { AssistantTurn, ChatMessage, LlmProvider, ToolCallShape } from '../provider/LlmProvider';
import { FicHubError } from './FicHub';
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
- fetch_page(url, max_chars?) — 打开网页读正文（脚本样式会被去掉，长页面会截断）。想确认某个链接是不是那篇文、看章节数、读推荐榜单时用它。它只读网页，不会把网页变成书。
- fichub_get(url) — 把作品页变成 EPUB 放进待入库区，一步到位。它会先花十几秒探 FicHub 有没有缓存，命中就直接取；没命中会继续等它现场抓源站转换，可能一两分钟。站点不支持或被限流时会失败并说明原因。
- html_to_book(urls, title?, author?) — 把网页抓成本地书放进待入库区，urls 按阅读顺序传数组（每个网页合成一章，单页也行）。这是 FicHub 不支持的站点的兜底路：LOFTER、晋江免费章节、博客、论坛帖子串都能收。只对网页源码里就有正文的静态页面有效。
- download_file(url, title?, author?) — 直接下载任意 URL 上的文件，EPUB/TXT 会自动放进待入库区。手上已经有文件直链时用它。

一次可以发多个工具调用。互不依赖的操作要一次发出来：比如同时探测 3 个链接、同时读 2 个页面。同一轮里的多个调用只消耗一步，一个一个发是最费步数的做法。

怎么组合由你判断。下面是一些经验，不是规定：
- 已经确定要这本且站点在 FicHub 支持范围内（AO3、FanFiction.net、SpaceBattles、SufficientVelocity、FictionPress 等），直接 fichub_get，不要再单独探一次 —— 它自己会先探缓存再决定等多久，多调一步只是白等十几秒。
- 中文站点（LOFTER、晋江、博客、论坛等）FicHub 不支持：先 fetch_page 或 web_search 确认链接，然后用 html_to_book。一篇文拆成多帖/多章连载时，把按阅读顺序的链接凑齐，一次传给 urls 合成一本；搜到的每章链接也可以先批量 fetch_page 确认顺序。
- html_to_book 抓不到正文（页面要登录、是 JS 动态渲染、或内容是图片，典型如微博、小红书、番茄）时不要反复重试 —— 同样的 URL 结果不会变。直接建议用户换路：在浏览器里打开文章、等正文显示后把链接分享给本应用，或复制正文存成 TXT 从「导入本地文件」进来。
- FicHub 限流时别死磕：换 html_to_book 或搜 EPUB/TXT 直链走 download_file。
- 搜索结果只有几行摘要，别只凭标题猜内容；要确认就 fetch_page 打开看。
- 同一个 URL 不要反复调同一个工具，结果不会变。

预算：这一回合你最多有 ${MAX_ROUNDS} 步，每次工具返回都会告诉你 steps_left 还剩几步。开头大胆探索，剩 3 步左右就别再开新线索了，把已确认的作品拿到手、然后收尾 —— 不要走到步数用尽被硬截断，那样用户只能看到一句干巴巴的报错。

硬性要求：
- 只能用工具返回过的链接和元信息，绝不编造 URL、作品名或作者。确实找不到就直说没找到。
- 搜到符合需求的作品，当场就把它下下来，不要下之前先问用户「要不要下」、也不要只给一串链接让用户自己挑 —— 用户点一下就能在书架看到，这才是这个助手的价值。
- 一条消息里通常下 2-3 本候选（明显符合的都要下），让用户有点挑选余地；但如果搜索结果里大半不相关，只下真正对得上的那几本。
- 同一本不要下第二次：已经在待入库区或已入架的作品，告诉用户就好。
- 只有真的把书放进待入库区才算「找到了」，只搜到链接不算。

说话风格：中文，简洁，不要复述工具返回的原始 JSON。每次调用工具之前，用一两句话说明你此刻的判断和打算（这段话会直接展示给用户当你的思考过程），说人话，不要写成编号计划。全部做完后收尾：下了哪几本、分别是什么、有没有没找到的、下一步建议。`;

/** 发给模型的历史条数上限（不含 system），对话越长越贵 */
const MAX_HISTORY: number = 24;

export class FinderAgent {
  /**
   * 跑一个回合：把用户这条消息交给模型，循环执行它请求的工具，
   * 直到它给出不带 tool_calls 的回复（或轮次用尽）。
   * history 由调用方持有并跨回合复用 —— 这就是"对话记忆"。
   */
  static async chatTurn(history: ChatMessage[], cfg: ProviderConfig, ui: common.UIAbilityContext,
    hooks: AgentHooks, ctrl: RunControl): Promise<FinderResult> {
    if (history.length === 0) {
      const sys: ChatMessage = { role: 'system', content: FINDER_SYSTEM };
      history.push(sys);
    }
    const provider = new LlmProvider(cfg);
    // 把「立刻打断在途请求」的能力交给取消令牌，用户点停止时才不是在干等
    ctrl.bind(() => {
      provider.abort();
    });
    const tools = FinderTools.defs();
    const ctx: FinderCtx = { cfg: cfg, ui: ui, hooks: hooks };
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
        const send: ChatMessage[] = FinderAgent.window(history);
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
   * 发给模型的窗口：保留 system + 最近 MAX_HISTORY 条。
   * 掐头时必须跳过 role=tool —— 孤立的 tool 消息前面没有对应的
   * assistant(tool_calls)，会被服务端 400 驳回。
   */
  private static window(history: ChatMessage[]): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i = 0; i < history.length; i++) {
      if (history[i].role === 'system') {
        out.push(history[i]);
      }
    }
    let start = 0;
    if (history.length > MAX_HISTORY) {
      start = history.length - MAX_HISTORY;
      while (start < history.length && history[start].role === 'tool') {
        start++;
      }
    }
    for (let i = start; i < history.length; i++) {
      if (history[i].role !== 'system') {
        out.push(history[i]);
      }
    }
    return out;
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
