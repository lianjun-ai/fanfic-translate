import { webview } from '@kit.ArkWeb';
import { MOBILE_UA } from './NetUa';
import { AntiBot } from './AntiBot';
import { Log } from '../common/Logger';

/** 渲染结果：成功时 html 是渲染完成后的完整文档 */
export interface RenderResult {
  ok: boolean;
  html: string;
  note: string;
}

/** 渲染器宿主（SearchPage）：负责按需挂载隐藏的 Web 组件 */
export interface RendererHost {
  requestMount: () => void;
  /** 重建隐藏 Web 组件（旧 controller 已和组件脱钩时用）：先卸载再挂一个新的 */
  remount: () => void;
}

/** 轮询参数 */
const POLL_INTERVAL_MS: number = 500;
/** 连续 N 次读数不变即认为渲染稳定 */
const STABLE_COUNT: number = 3;
/** onPageEnd 后先等这么久再开始判稳（给数据请求留时间，防止停在骨架上就「稳定」） */
const GRACE_MS: number = 2000;
/** 从 loadUrl 开始的总超时，超时也抽取（抽到多少算多少） */
const TOTAL_TIMEOUT_MS: number = 20000;
/** 撞上反爬挑战页时的放宽超时：脚本要跑、要写 Cookie、要自动重载，一次 20 秒不够 */
const CHALLENGE_TIMEOUT_MS: number = 35000;
/** 挑战页上如果一直不自动重载，到这个时间点主动刷一次（只刷一次） */
const CHALLENGE_REFRESH_MS: number = 9000;
/** 刷过一次还是挑战页，到此就认输（不等满 35 秒：脚本进了死循环，再等也不会变） */
const CHALLENGE_GIVEUP_MS: number = 18000;
/** 等宿主挂载 Web 组件的超时 */
const MOUNT_TIMEOUT_MS: number = 6000;

/**
 * 隐藏 ArkWeb 渲染器（单例）。
 *
 * 解决的问题：直抓网页源码只能拿到「渲染前」的字节 —— SPA 的正文是页面
 * JS 调接口后插入 DOM 的。这里用寄宿在 SearchPage 里的 1×1 隐藏 Web 组件
 * 真实加载页面，等异步数据回填完毕，再用 runJavaScript 把渲染后的 DOM
 * 抽出来，交给调用方走既有解析管线。
 *
 * 「渲染完了」没有接口可问，只能观察：onPageEnd（骨架到达）后每隔
 * POLL_INTERVAL 读一次正文文本长度，连续 STABLE_COUNT 次不变即认为稳定；
 * 自 GRACE_MS 起才开始判稳（否则骨架本身的两三次相同读数会造成假稳定）。
 * 总超时 TOTAL_TIMEOUT 兜底，超时也抽取 —— 部分正文总比空壳好。
 *
 * 串行队列：同一时刻只渲染一页，多页请求排队；渲染完 loadUrl('about:blank')
 * 释放页面内存，组件本身随 SearchPage 生命周期存活。
 */
export class HeadlessRenderer {
  private static ctrl: webview.WebviewController | null = null;
  private static host: RendererHost | null = null;
  /** 等待 controller attach 的回调（惰性挂载后由 attachController 唤醒） */
  private static attachWaiter: (() => void) | null = null;
  /** onPageEnd 到达时唤醒 doRender */
  private static pageEndWaiter: (() => void) | null = null;
  /** 串行队列尾部 */
  private static tail: Promise<void> = Promise.resolve();
  /**
   * 本次运行里「渲染过、被站点校验页拦住」的 URL。
   *
   * 记下来的理由：拦不拦是站点对这套环境的判定，同一个 URL 重试不会变。
   * 真机上模型对知乎那条链接连试了三次渲染，每次都白等十几秒 —— 第二次
   * 直接返回上次的结论，模型的步数和用户的时间都省下来。
   */
  private static blocked: Map<string, string> = new Map<string, string>();

  /** SearchPage 在 aboutToAppear 里注册宿主 */
  static setHost(host: RendererHost): void {
    HeadlessRenderer.host = host;
  }

  /** SearchPage 的 Web 组件 onControllerAttached 时调用 */
  static attachController(ctrl: webview.WebviewController): void {
    HeadlessRenderer.ctrl = ctrl;
    // ArkWeb 默认 UA 带 ArkWeb/OpenHarmony 字样，知乎、小红书这类风控站会
    // 直接判成爬虫返回 403（真机实测：直抓/探接口/渲染三条路全 403）。
    // 伪装成常规 Android Chrome 移动端，让渲染降级在这些站上真正可用。
    try {
      ctrl.setCustomUserAgent(MOBILE_UA);
    } catch (e) {
      Log.w(`设置自定义 UA 失败（用默认 UA 继续）：${(e as Error).message}`);
    }
    const waiter = HeadlessRenderer.attachWaiter;
    HeadlessRenderer.attachWaiter = null;
    if (waiter !== null) {
      waiter();
    }
    Log.i('内置渲染器 Web 组件已就绪');
  }

  /**
   * SearchPage 销毁时调用，把静态引用清掉。
   *
   * 不清会踩一个必现的坑：页面重建后新的 SearchPage 有自己的 controller，
   * 但静态 ctrl 还是上一页那个已卸载组件的 —— ensureMounted 看 ctrl 非空就
   * 直接放行，loadUrl 抛「WebviewController must be associated with a
   * Web component」（真机 B1 知乎那条就是这么挂的）。
   */
  static detachController(ctrl: webview.WebviewController): void {
    if (HeadlessRenderer.ctrl === ctrl) {
      HeadlessRenderer.ctrl = null;
      HeadlessRenderer.attachWaiter = null;
      Log.w('内置渲染器宿主已销毁，controller 置空');
    }
  }

  /**
   * SearchPage 的 Web 组件 onPageEnd 时调用。
   * url 用来过滤占位加载：组件挂载和渲染完释放时都会 loadUrl('about:blank')，
   * 它们的 onPageEnd 不能误当成目标页面渲染完成。
   */
  static notifyPageEnd(url: string): void {
    if (url.length === 0 || url.indexOf('about:blank') >= 0) {
      return;
    }
    const waiter = HeadlessRenderer.pageEndWaiter;
    HeadlessRenderer.pageEndWaiter = null;
    if (waiter !== null) {
      waiter();
    }
  }

  /** 渲染一个 URL，返回渲染完成后的 HTML。请求排队串行执行。 */
  static render(url: string): Promise<RenderResult> {
    const run = HeadlessRenderer.tail.then((): Promise<RenderResult> => HeadlessRenderer.doRender(url));
    HeadlessRenderer.tail = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  private static async doRender(url: string): Promise<RenderResult> {
    const known = HeadlessRenderer.blocked.get(url);
    if (known !== undefined) {
      Log.i(`内置渲染跳过（该链接本次已被拦过）：${url}`);
      return { ok: false, html: '', note: `${known}；同一链接本次已渲染过，不再重复尝试` };
    }
    // 1. 确保宿主已挂载 Web 组件、controller 可用
    const ready = await HeadlessRenderer.ensureMounted();
    if (!ready) {
      return { ok: false, html: '', note: '内置渲染器未能启动' };
    }
    let ctrl = HeadlessRenderer.ctrl;
    if (ctrl === null) {
      return { ok: false, html: '', note: '内置渲染器未能启动' };
    }
    Log.i(`内置渲染开始：${url}`);

    // 2. 加载页面，等 onPageEnd（骨架到达）
    const pageEndPromise = new Promise<void>((resolve) => {
      HeadlessRenderer.pageEndWaiter = resolve;
    });
    try {
      ctrl.loadUrl(url);
    } catch (e) {
      const msg = (e as Error).message;
      Log.w(`内置渲染加载失败：${msg}`);
      if (msg.indexOf('associated') < 0) {
        return { ok: false, html: '', note: `内置渲染加载失败：${msg}` };
      }
      // controller 和 Web 组件脱钩（宿主页面重建过）：重建组件，重取 controller 再试一次
      const fresh = await HeadlessRenderer.remount();
      if (fresh === null) {
        return { ok: false, html: '', note: '内置渲染器未能启动（宿主页面已重建，重新挂载失败）' };
      }
      ctrl = fresh;
      try {
        ctrl.loadUrl(url);
      } catch (e2) {
        return { ok: false, html: '', note: `内置渲染加载失败：${(e2 as Error).message}` };
      }
    }
    const startedAt = Date.now();
    await HeadlessRenderer.withDeadline(pageEndPromise, 12000);
    if (HeadlessRenderer.pageEndWaiter !== null) {
      // onPageEnd 没来（超时）：清掉 waiter 继续轮询，页面可能还是能读
      HeadlessRenderer.pageEndWaiter = null;
      Log.w('内置渲染：onPageEnd 超时，直接尝试轮询抽取');
    }

    // 3. 给数据请求留宽限期，然后轮询文本长度直到稳定或总超时
    const elapsed = Date.now() - startedAt;
    if (elapsed < GRACE_MS) {
      await HeadlessRenderer.sleep(GRACE_MS - elapsed);
    }
    let last = -1;
    let stable = 0;
    let challenged = false;
    let refreshed = false;
    let hitTimeout = false;
    while (true) {
      // 撞上挑战页就换成更长的总超时：它要靠 JS 写 Cookie + reload 才能过
      const limit = challenged ? CHALLENGE_TIMEOUT_MS : TOTAL_TIMEOUT_MS;
      if (Date.now() - startedAt >= limit) {
        hitTimeout = true;
        break;
      }
      let reading = -1;
      let chal = false;
      try {
        const raw = await ctrl.runJavaScript(HeadlessRenderer.STATE_SCRIPT);
        const obj = JSON.parse(HeadlessRenderer.unwrap(raw)) as Record<string, Object>;
        const n = obj['n'];
        reading = typeof n === 'number' ? n as number : -1;
        chal = obj['c'] === 1;
      } catch (e) {
        Log.w(`内置渲染轮询失败：${(e as Error).message}`);
      }
      if (chal) {
        // 挑战页：不判稳（正文还没来），等脚本重载或主动刷一次
        if (!challenged) {
          challenged = true;
          Log.i('内置渲染：命中反爬挑战页，等脚本执行后重载（最长 35 秒）');
        }
        stable = 0;
        if (!refreshed && Date.now() - startedAt > CHALLENGE_REFRESH_MS) {
          refreshed = true;
          try {
            ctrl.refresh();
            Log.i('内置渲染：挑战页未自动重载，主动刷新一次');
          } catch (e) {
            Log.w(`挑战页刷新失败：${(e as Error).message}`);
          }
        }
        // 刷过一次还是挑战页：说明脚本判定了环境可疑，再等也不会放行
        if (refreshed && Date.now() - startedAt > CHALLENGE_GIVEUP_MS) {
          Log.w('内置渲染：刷新后仍是挑战页，提前收手');
          break;
        }
        last = reading;
        await HeadlessRenderer.sleep(POLL_INTERVAL_MS);
        continue;
      }
      // 容差判稳：轮播图、弹幕数、计时器会让正文长度一直小幅抖动，
      // 严格相等就永远判不稳，只能等满总超时（真机上 B站 就是这样被报成「渲染超时」）
      const same = reading >= 0 && last >= 0 &&
        Math.abs(reading - last) <= Math.max(2, Math.round(last * 0.01));
      if (same) {
        stable++;
        if (stable >= STABLE_COUNT - 1) {
          break;
        }
      } else {
        stable = 0;
      }
      last = reading;
      await HeadlessRenderer.sleep(POLL_INTERVAL_MS);
    }

    // 4. 抽取渲染后的完整文档
    let html = '';
    try {
      html = HeadlessRenderer.unwrap(await ctrl.runJavaScript('document.documentElement.outerHTML'));
    } catch (e) {
      return { ok: false, html: '', note: `抽取渲染结果失败：${(e as Error).message}` };
    }
    // 释放页面内存：组件还在，只是卸掉内容
    try {
      ctrl.loadUrl('about:blank');
    } catch (e) {
      // 不影响结果
    }
    if (html.length === 0) {
      return { ok: false, html: '', note: '内置渲染后仍抽取不到内容' };
    }
    const took = Math.max(1, Math.round((Date.now() - startedAt) / 1000));
    // 把「等满了超时」和「正常判稳」区分开写进 note：调用方（模型/用户）不必靠猜，
    // 也不会把一次成功的降级说成失败。
    const prefix = hitTimeout
      ? `内置浏览器渲染超时（等满 ${took} 秒仍未判稳，抽取了当时的内容）；`
      : `已用内置浏览器渲染（${took} 秒）；`;
    // 渲染完还是挑战页 = 这次真过不去（脚本被拦、或站点认定环境可疑）。
    // 说清楚是哪堵墙，调用方才能给用户正确建议，而不是含糊一句「抓不到」。
    const block = AntiBot.detectRendered(html, last > 0 ? last : 0);
    if (block.length > 0) {
      const why = `内置浏览器渲染 ${took} 秒后仍停在站点校验页：${AntiBot.hint(block)}`;
      HeadlessRenderer.blocked.set(url, why);
      Log.w(`内置渲染仍是拦截页（${block}）：${url}`);
      return { ok: false, html: html, note: why };
    }
    Log.i(`内置渲染完成：${url}（HTML ${html.length} 字符，正文文本约 ${Math.max(last, 0)} 字符，${took} 秒${hitTimeout ? '，超时' : ''}）`);
    return { ok: true, html: html, note: prefix };
  }

  /**
   * 轮询脚本：一次返回「正文文本长度」和「是否停在反爬挑战页」。
   * 挑战页判定只用 querySelector 看几个固定节点（不读整页 innerHTML，
   * 每 500ms 跑一次，读大页会明显拖慢渲染）。
   */
  private static readonly STATE_SCRIPT: string =
    '(function(){var b=document.body;var t=document.title||"";var c=0;' +
      'if(document.querySelector("meta#zh-zse-ck")){c=1;}' +
      'else if(t.indexOf("Just a moment")>=0){c=1;}' +
      'else if(document.querySelector("#challenge-form,#challenge-running,.cf-browser-verification")){c=1;}' +
      'return JSON.stringify({n:b?b.innerText.length:0,c:c});})()';

  /**
   * ArkWeb runJavaScript 返回的是结果的 JSON 序列化形式：
   * 字符串会被包上引号，< 变 \u003C、换行变 \n 字面量。
   * 不解码的话整份 HTML 就是一段转义文本，解析器读不出任何标签。
   * 首尾带引号且能 JSON.parse 成功才解码，其余原样返回。
   */
  private static unwrap(result: string): string {
    const s = result.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        const decoded = JSON.parse(s) as string;
        if (typeof decoded === 'string') {
          return decoded;
        }
      } catch (e) {
        // 不是合法 JSON 字符串，按原样返回
      }
    }
    return result;
  }

  /** 首次请求时让宿主挂载 Web 组件，并等 controller attach */
  private static async ensureMounted(): Promise<boolean> {
    if (HeadlessRenderer.ctrl !== null) {
      return true;
    }
    if (HeadlessRenderer.host !== null) {
      HeadlessRenderer.host.requestMount();
    }
    const attached = new Promise<void>((resolve) => {
      HeadlessRenderer.attachWaiter = resolve;
    });
    await HeadlessRenderer.withDeadline(attached, MOUNT_TIMEOUT_MS);
    const ok = HeadlessRenderer.ctrl !== null;
    HeadlessRenderer.attachWaiter = null;
    return ok;
  }

  /**
   * 让宿主重建 Web 组件并等新的 controller 就绪。
   * 只用于「ctrl 存在但已和组件脱钩」的补救；正常情况下 detachController 已经把
   * 引用清空了，走 ensureMounted 即可。
   */
  private static async remount(): Promise<webview.WebviewController | null> {
    const host = HeadlessRenderer.host;
    if (host === null) {
      return null;
    }
    HeadlessRenderer.ctrl = null;
    const attached = new Promise<void>((resolve) => {
      HeadlessRenderer.attachWaiter = resolve;
    });
    host.remount();
    await HeadlessRenderer.withDeadline(attached, MOUNT_TIMEOUT_MS + 2000);
    HeadlessRenderer.attachWaiter = null;
    return HeadlessRenderer.ctrl;
  }

  /** 带超时等待：到点就继续，不等了（Promise 结果被丢弃） */
  private static async withDeadline(p: Promise<void>, timeoutMs: number): Promise<void> {
    const timer = new Promise<void>((resolve) => setTimeout(resolve, timeoutMs));
    await Promise.race([p, timer]);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}
