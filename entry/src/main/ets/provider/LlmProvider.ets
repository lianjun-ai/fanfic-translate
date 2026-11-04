import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ProviderConfig } from '../common/Settings';
import { Log } from '../common/Logger';

/** 一次工具调用的函数部分（OpenAI 兼容格式，字段名保持 snake_case 直接序列化） */
export interface ToolFuncCall {
  name: string;
  arguments: string;
}

/** 模型回包里的单次工具调用 */
export interface ToolCallShape {
  id: string;
  type: string;
  function: ToolFuncCall;
}

export interface ChatMessage {
  role: string;
  content: string;
  /** assistant 消息携带的工具调用请求（tool-calling 循环用） */
  tool_calls?: ToolCallShape[];
  /** role=tool 消息标注本结果对应哪次调用 */
  tool_call_id?: string;
}

/** 工具的参数 schema（JSON Schema 对象，用 JSON.parse 构造以规避 ArkTS 动态对象限制） */
export interface ToolFuncDef {
  name: string;
  description: string;
  parameters: Object;
}

export interface ToolDef {
  type: string;
  function: ToolFuncDef;
}

/** 一轮工具调用请求的产出 */
export interface AssistantTurn {
  content: string;
  /** 服务端返回的推理内容（deepseek-reasoner / qwen3 思考模式等），有就展示给用户看 */
  reasoning: string;
  toolCalls: ToolCallShape[];
}

/** 流式回包里 tool_calls 的分片（index 标识归属哪一次调用，字段按需出现） */
interface DeltaFuncShape {
  name?: string;
  arguments?: string;
}

interface DeltaCallShape {
  index?: number;
  id?: string;
  type?: string;
  function?: DeltaFuncShape;
}

interface DeltaShape {
  content?: string;
  reasoning_content?: string;
  tool_calls?: DeltaCallShape[];
}

/** 流式累积中的一次工具调用 */
interface AccCall {
  index: number;
  id: string;
  name: string;
  args: string;
}

interface ChoiceShape {
  delta?: DeltaShape;
  message?: DeltaShape;
}

interface ApiErrorShape {
  message?: string;
  type?: string;
}

interface ChunkShape {
  choices?: ChoiceShape[];
  error?: ApiErrorShape;
}

interface ThinkingShape {
  type: string;
}

interface ReqBody {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  stream: boolean;
  thinking?: ThinkingShape;
  enable_thinking?: boolean;
  /** GLM-5.3 系专用思考深度档位（该系不支持 thinking.disabled） */
  reasoning_effort?: string;
  tools?: ToolDef[];
}

const MAX_RAW: number = 4000;

/**
 * OpenAI 兼容接口的流式客户端。
 *
 * 用 requestInStream 而不是 request：翻译一段要几秒到几十秒，
 * 非流式只能干等，用户会以为卡死。流式还能让"正在翻译的这一段"
 * 边生成边显示，这是 M3 的核心体验。
 *
 * 同时兼容不返回 SSE 的服务（少数自建网关）：到流结束时如果一段
 * 增量都没收到，就把整体响应当普通 JSON 解析一次。
 */
export class LlmProvider {
  /** 中断信号的固定文案，调用方靠它区分「用户主动停止」和真实故障 */
  static readonly ABORTED: string = 'ABORTED';

  private cfg: ProviderConfig;
  private request: http.HttpRequest | null = null;
  /**
   * 进行中那次流式请求的 reject 句柄。
   *
   * 只 destroy 请求是不够的：dataEnd 回调里 `req !== this.request` 会为真、
   * 直接 return，Promise 既不 resolve 也不 reject，整个 await 永久挂起。
   * 所以中断时必须主动把这个 Promise 打掉。
   */
  private rejectCurrent: ((e: Error) => void) | null = null;

  constructor(cfg: ProviderConfig) {
    this.cfg = cfg;
  }

  /** 中断进行中的请求：销毁连接 + 打掉挂起的 Promise */
  abort(): void {
    const r = this.request;
    const rej = this.rejectCurrent;
    this.request = null;
    this.rejectCurrent = null;
    if (r !== null) {
      try {
        r.destroy();
      } catch (e) {
        Log.w(`中断请求异常：${(e as Error).message}`);
      }
    }
    if (rej !== null) {
      rej(new Error(LlmProvider.ABORTED));
    }
  }

  /**
   * 是否 DeepSeek 官方接口。
   *
   * 只有它家的 V4 系列需要显式关掉思考模式，而其它厂商不认识 thinking 参数，
   * 无脑下发会被严格校验的服务端以 400 驳回，所以按地址判断。
   */
  private static isDeepSeek(cfg: ProviderConfig): boolean {
    return cfg.baseUrl.toLowerCase().indexOf('deepseek') >= 0;
  }

  private static isDashScope(cfg: ProviderConfig): boolean {
    return cfg.baseUrl.toLowerCase().indexOf('dashscope') >= 0;
  }

  /** 是否智谱官方接口（open.bigmodel.cn） */
  private static isBigmodel(cfg: ProviderConfig): boolean {
    return cfg.baseUrl.toLowerCase().indexOf('bigmodel') >= 0;
  }

  /** 思维链模型（deepseek-reasoner / qwq 等）：思考是它的卖点，不能关 */
  private static isReasoner(cfg: ProviderConfig): boolean {
    const m = cfg.model.toLowerCase();
    return m.indexOf('reasoner') >= 0 || m.indexOf('-r1') >= 0 || m.indexOf('qwq') >= 0;
  }

  private endpoint(): string {
    let base = this.cfg.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) {
      return base;
    }
    return `${base}/chat/completions`;
  }

  /**
   * 统一构造请求体。流式（翻译）与非流式（工具循环）共用，
   * 思考模式的关闭逻辑只写一份。
   */
  private static buildBody(cfg: ProviderConfig, messages: ChatMessage[],
    tools: ToolDef[] | null, stream: boolean): ReqBody {
    const body: ReqBody = {
      model: cfg.model,
      messages: messages,
      temperature: cfg.temperature,
      stream: stream
    };
    // DeepSeek 的 V4 系列默认开着思考模式，必须显式关掉，理由见 isDeepSeek。
    // 但用户主动选了思维链模型时，思考正是我们要展示的东西，不能关。
    if (LlmProvider.isDeepSeek(cfg) && !LlmProvider.isReasoner(cfg)) {
      const off: ThinkingShape = { type: 'disabled' };
      body.thinking = off;
    }
    // 百炼的 qwen3 系默认开启思考（enable_thinking）。只对这个前缀下发：
    // qwen-plus 这类别名不支持该参数，传了会 400。
    if (LlmProvider.isDashScope(cfg) && cfg.model.toLowerCase().startsWith('qwen3')) {
      body.enable_thinking = false;
    }
    // 智谱：5.3 系（含 5.3-flash/flashx）默认思考且【不支持 disabled】，传了直接报错，
    // 只能降到 reasoning_effort=low 控制思考开销；更早的 5.2/5.1/4.x 仍支持 disabled。
    if (LlmProvider.isBigmodel(cfg)) {
      const m = cfg.model.toLowerCase();
      if (m.indexOf('5.3') >= 0) {
        body.reasoning_effort = 'low';
      } else if (!LlmProvider.isReasoner(cfg)) {
        const off: ThinkingShape = { type: 'disabled' };
        body.thinking = off;
      }
    }
    if (tools !== null) {
      body.tools = tools;
    }
    return body;
  }

  /**
   * 发起一次补全，onDelta 收到的是"累计文本"而不是增量片段 ——
   * 上层要按 [[n]] 标记重新切分，拿到全量比自己拼接更不容易错。
   */
  async complete(messages: ChatMessage[], onDelta: (acc: string) => void): Promise<string> {
    const key = this.cfg.apiKey.trim();
    if (key.length === 0) {
      throw new Error('还没有填写 API Key，请先到设置里配置');
    }

    const header: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'Authorization': `Bearer ${key}`
    };
    const body = LlmProvider.buildBody(this.cfg, messages, null, true);
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 180000
    };

    const req = http.createHttp();
    this.request = req;

    const decoder = util.TextDecoder.create('utf-8');
    let buffer = '';
    let raw = '';
    let content = '';
    let status = 0;

    try {
      content = await new Promise<string>((resolve: (v: string) => void,
        reject: (e: Error) => void) => {
        req.on('dataReceive', (data: ArrayBuffer) => {
          if (req !== this.request) {
            // 已被 abort，丢弃迟到的数据
            return;
          }
          let text = '';
          try {
            text = decoder.decodeToString(new Uint8Array(data), { stream: true });
          } catch (e) {
            text = decoder.decodeToString(new Uint8Array(data));
          }
          if (raw.length < MAX_RAW) {
            raw += text;
          }
          buffer += text;

          let nl = buffer.indexOf('\n');
          while (nl >= 0) {
            const line = buffer.substring(0, nl).trim();
            buffer = buffer.substring(nl + 1);
            nl = buffer.indexOf('\n');
            if (line.length === 0) {
              continue;
            }
            const piece = LlmProvider.readSse(line);
            if (piece.length > 0) {
              content += piece;
              onDelta(content);
            }
          }
        });

        req.on('dataEnd', () => {
          if (req !== this.request) {
            return;
          }
          if (status !== 0 && status !== 200) {
            reject(new Error(`接口返回 HTTP ${status}：${LlmProvider.hint(raw)}`));
            return;
          }
          if (content.length === 0) {
            // 非流式服务的兜底：整包当 JSON 解析
            const fallback = LlmProvider.parseWhole(raw);
            if (fallback.length > 0) {
              resolve(fallback);
              return;
            }
            reject(new Error(`接口没有返回内容：${LlmProvider.hint(raw)}`));
            return;
          }
          resolve(content);
        });

        req.requestInStream(this.endpoint(), options)
          .then((code: number) => {
            status = code;
            Log.i(`翻译请求已连接，HTTP ${code}`);
          })
          .catch((e: Error) => {
            reject(new Error(`网络请求失败：${e.message}`));
          });
      });
      return content;
    } finally {
      if (this.request === req) {
        this.request = null;
      }
      try {
        req.destroy();
      } catch (e) {
        Log.d('请求已释放');
      }
    }
  }

  /**
   * 流式的工具调用回合：带 tools 发一次请求，边收边把文本推给 onText。
   *
   * 回包可能是文本（模型在说明思路，或给出最终回复）也可能是 tool_calls
   * （模型要求执行工具）。流式下 tool_calls 是分片下发的 —— 第一片带
   * id + name，后续片只带 arguments 增量，按 index 归并到同一次调用。
   *
   * onText 收到的是"累计文本"（reasoning + content 合并），上层直接
   * 覆盖显示即可，不用自己拼接。
   * 循环控制与消息回填由调用方（FinderAgent）负责，这里只管一回合。
   */
  async callWithToolsStream(messages: ChatMessage[], tools: ToolDef[],
    onText: (acc: string) => void): Promise<AssistantTurn> {
    const key = this.cfg.apiKey.trim();
    if (key.length === 0) {
      throw new Error('还没有填写 API Key，请先到设置里配置');
    }
    const header: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'Authorization': `Bearer ${key}`
    };
    const body = LlmProvider.buildBody(this.cfg, messages, tools, true);
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 180000
    };

    const req = http.createHttp();
    this.request = req;
    const decoder = util.TextDecoder.create('utf-8');
    const turn: AssistantTurn = { content: '', reasoning: '', toolCalls: [] };
    const calls: AccCall[] = [];
    let buffer = '';
    let raw = '';
    let status = 0;

    try {
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        this.rejectCurrent = reject;
        req.on('dataReceive', (data: ArrayBuffer) => {
          if (req !== this.request) {
            return;
          }
          let text = '';
          try {
            text = decoder.decodeToString(new Uint8Array(data), { stream: true });
          } catch (e) {
            text = decoder.decodeToString(new Uint8Array(data));
          }
          if (raw.length < MAX_RAW) {
            raw += text;
          }
          buffer += text;

          // 一个 chunk 可能含多行 SSE，处理完再整体回调一次，避免每行都刷 UI
          let changed = false;
          let nl = buffer.indexOf('\n');
          while (nl >= 0) {
            const line = buffer.substring(0, nl).trim();
            buffer = buffer.substring(nl + 1);
            nl = buffer.indexOf('\n');
            if (line.length === 0) {
              continue;
            }
            if (LlmProvider.readChunk(line, turn, calls)) {
              changed = true;
            }
          }
          if (changed) {
            onText(LlmProvider.mergeText(turn.reasoning, turn.content));
          }
        });

        req.on('dataEnd', () => {
          if (req !== this.request) {
            return;
          }
          if (status !== 0 && status !== 200) {
            reject(new Error(`接口返回 HTTP ${status}：${LlmProvider.hint(raw)}`));
            return;
          }
          resolve();
        });

        req.requestInStream(this.endpoint(), options)
          .then((code: number) => {
            status = code;
            Log.i(`工具循环请求已连接，HTTP ${code}`);
          })
          .catch((e: Error) => {
            reject(new Error(`网络请求失败：${e.message}`));
          });
      });
    } catch (e) {
      if ((e as Error).message === LlmProvider.ABORTED) {
        // 用户中断：半截的 tool_calls 参数可能是残缺 JSON，整段丢弃，
        // 交回一个空 turn，由调用方检查取消标志决定怎么收尾
        Log.i('工具循环请求已被用户中断');
        return { content: '', reasoning: '', toolCalls: [] };
      }
      throw new Error((e as Error).message);
    } finally {
      this.rejectCurrent = null;
      if (this.request === req) {
        this.request = null;
      }
      try {
        req.destroy();
      } catch (e) {
        Log.d('请求已释放');
      }
    }

    // 兜底：个别网关忽略 stream=true，整包返回普通 JSON
    if (turn.content.length === 0 && turn.reasoning.length === 0 && calls.length === 0) {
      const whole = LlmProvider.parseWholeTurn(raw);
      if (whole !== null) {
        onText(LlmProvider.mergeText(whole.reasoning, whole.content));
        return whole;
      }
      throw new Error(`接口没有返回内容：${LlmProvider.hint(raw)}`);
    }

    // 组装工具调用（分片已按 index 归并）
    for (let i = 0; i < calls.length; i++) {
      const a = calls[i];
      if (a.name.length === 0) {
        continue;
      }
      const call: ToolCallShape = {
        id: a.id.length > 0 ? a.id : `call_${a.index}`,
        type: 'function',
        function: { name: a.name, arguments: a.args }
      };
      turn.toolCalls.push(call);
    }
    return turn;
  }

  /** 解析一行 SSE 并累积到 turn；返回是否产生了新内容 */
  private static readChunk(line: string, turn: AssistantTurn, calls: AccCall[]): boolean {
    if (!line.startsWith('data:')) {
      return false;
    }
    const payload = line.substring(5).trim();
    if (payload.length === 0 || payload === '[DONE]') {
      return false;
    }
    let obj: ChunkShape;
    try {
      obj = JSON.parse(payload) as ChunkShape;
    } catch (e) {
      // 半行（被网络切断）或被插入心跳，忽略
      return false;
    }
    const err = obj.error;
    if (err !== undefined && err !== null && err.message !== undefined) {
      Log.w(`服务端错误事件：${err.message}`);
      return false;
    }
    const choices = obj.choices;
    if (choices === undefined || choices === null || choices.length === 0) {
      return false;
    }
    const d = choices[0].delta;
    if (d === undefined || d === null) {
      return false;
    }
    let changed = false;
    const r = d.reasoning_content;
    if (r !== undefined && r !== null && r.length > 0) {
      turn.reasoning += r;
      changed = true;
    }
    const c = d.content;
    if (c !== undefined && c !== null && c.length > 0) {
      turn.content += c;
      changed = true;
    }
    const tc = d.tool_calls;
    if (tc !== undefined && tc !== null) {
      for (let i = 0; i < tc.length; i++) {
        const piece = tc[i];
        if (piece !== undefined && piece !== null) {
          LlmProvider.mergeCallDelta(calls, piece);
        }
      }
    }
    return changed;
  }

  /** 把一片 tool_calls 增量并到对应槽位（index 缺省时按新槽处理） */
  private static mergeCallDelta(calls: AccCall[], piece: DeltaCallShape): void {
    const idx = piece.index === undefined || piece.index === null ? calls.length : piece.index;
    let slot: AccCall | null = null;
    for (let i = 0; i < calls.length; i++) {
      if (calls[i].index === idx) {
        slot = calls[i];
        break;
      }
    }
    if (slot === null) {
      const fresh: AccCall = { index: idx, id: '', name: '', args: '' };
      calls.push(fresh);
      slot = fresh;
    }
    if (piece.id !== undefined && piece.id !== null && piece.id.length > 0) {
      slot.id = piece.id;
    }
    const fn = piece.function;
    if (fn !== undefined && fn !== null) {
      if (fn.name !== undefined && fn.name !== null && fn.name.length > 0) {
        slot.name = fn.name;
      }
      if (fn.arguments !== undefined && fn.arguments !== null) {
        slot.args += fn.arguments;
      }
    }
  }

  /** 推理内容与正文合并：reasoner 先吐思考再吐正文，两段之间空一行 */
  private static mergeText(reasoning: string, content: string): string {
    if (reasoning.length === 0) {
      return content;
    }
    if (content.length === 0) {
      return reasoning;
    }
    return `${reasoning}\n\n${content}`;
  }

  /** 非流式兜底：把整包响应当普通 JSON 解析成一轮结果 */
  private static parseWholeTurn(raw: string): AssistantTurn | null {
    const start = raw.indexOf('{');
    const end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }
    let obj: ChunkShape;
    try {
      obj = JSON.parse(raw.substring(start, end + 1)) as ChunkShape;
    } catch (e) {
      return null;
    }
    const choices = obj.choices;
    if (choices === undefined || choices === null || choices.length === 0) {
      return null;
    }
    const m = choices[0].message;
    if (m === undefined || m === null) {
      return null;
    }
    const turn: AssistantTurn = {
      content: m.content ?? '',
      reasoning: m.reasoning_content ?? '',
      toolCalls: []
    };
    const calls = m.tool_calls;
    if (calls !== undefined && calls !== null) {
      for (let i = 0; i < calls.length; i++) {
        const c = calls[i];
        if (c === undefined || c === null) {
          continue;
        }
        const fn = c.function;
        if (fn === undefined || fn === null || fn.name === undefined || fn.name === null) {
          continue;
        }
        const call: ToolCallShape = {
          id: c.id ?? `call_${i}`,
          type: 'function',
          function: { name: fn.name, arguments: fn.arguments ?? '' }
        };
        turn.toolCalls.push(call);
      }
    }
    return turn;
  }

  /** 解析一行 SSE，取出增量文本；非数据行返回空串 */
  private static readSse(line: string): string {
    if (!line.startsWith('data:')) {
      return '';
    }
    const payload = line.substring(5).trim();
    if (payload.length === 0 || payload === '[DONE]') {
      return '';
    }
    try {
      const obj = JSON.parse(payload) as ChunkShape;
      const err = obj.error;
      if (err !== undefined && err !== null && err.message !== undefined) {
        // 不在这里抛：流里的错误事件不该被自己的 catch 吞掉，
        // 记下来交给流结束时的统一错误处理（带上完整响应体）
        Log.w(`服务端错误事件：${err.message}`);
        return '';
      }
      const choices = obj.choices;
      if (choices === undefined || choices === null || choices.length === 0) {
        return '';
      }
      const d = choices[0].delta;
      if (d === undefined || d === null) {
        return '';
      }
      const c = d.content;
      return c === undefined || c === null ? '' : c;
    } catch (e) {
      // 半行（被网络切断）或被服务端插入了心跳，忽略即可，不能中断整条流
      return '';
    }
  }

  private static parseWhole(raw: string): string {
    const start = raw.indexOf('{');
    const end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return '';
    }
    try {
      const obj = JSON.parse(raw.substring(start, end + 1)) as ChunkShape;
      const choices = obj.choices;
      if (choices === undefined || choices === null || choices.length === 0) {
        return '';
      }
      const m = choices[0].message;
      if (m === undefined || m === null || m.content === undefined || m.content === null) {
        return '';
      }
      return m.content;
    } catch (e) {
      return '';
    }
  }

  /** 从响应体里抠出人话，避免把整页 HTML 甩给用户 */
  private static hint(raw: string): string {
    const t = raw.trim();
    if (t.length === 0) {
      return '（空响应）';
    }
    const start = t.indexOf('{');
    const end = t.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        const obj = JSON.parse(t.substring(start, end + 1)) as ChunkShape;
        const err = obj.error;
        if (err !== undefined && err !== null && err.message !== undefined) {
          return err.message;
        }
      } catch (e) {
        Log.d('响应体不是 JSON');
      }
    }
    const flat = t.replace(/\s+/g, ' ');
    return flat.length > 180 ? `${flat.substring(0, 180)}…` : flat;
  }
}
