import { webview } from '@kit.ArkWeb';
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
}

/** 轮询参数 */
const POLL_INTERVAL_MS: number = 500;
/** 连续 N 次读数不变即认为渲染稳定 */
const STABLE_COUNT: number = 3;
/** onPageEnd 后先等这么久再开始判稳（给数据请求留时间，防止停在骨架上就「稳定」） */
const GRACE_MS: number = 2000;
/** 从 loadUrl 开始的总超时，超时也抽取（抽到多少算多少） */
const TOTAL_TIMEOUT_MS: number = 20000;
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

  /** SearchPage 在 aboutToAppear 里注册宿主 */
  static setHost(host: RendererHost): void {
    HeadlessRenderer.host = host;
  }

  /** SearchPage 的 Web 组件 onControllerAttached 时调用 */
  static attachController(ctrl: webview.WebviewController): void {
    HeadlessRenderer.ctrl = ctrl;
    const waiter = HeadlessRenderer.attachWaiter;
    HeadlessRenderer.attachWaiter = null;
    if (waiter !== null) {
      waiter();
    }
    Log.i('内置渲染器 Web 组件已就绪');
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
    // 1. 确保宿主已挂载 Web 组件、controller 可用
    const ready = await HeadlessRenderer.ensureMounted();
    if (!ready) {
      return { ok: false, html: '', note: '内置渲染器未能启动' };
    }
    const ctrl = HeadlessRenderer.ctrl;
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
      return { ok: false, html: '', note: `内置渲染加载失败：${(e as Error).message}` };
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
    const lengthScript = 'document.body ? String(document.body.innerText.length) : "0"';
    let last = -1;
    let stable = 0;
    while (Date.now() - startedAt < TOTAL_TIMEOUT_MS) {
      let reading = -1;
      try {
        const raw = await ctrl.runJavaScript(lengthScript);
        reading = parseInt(raw, 10);
        if (isNaN(reading)) {
          reading = -1;
        }
      } catch (e) {
        Log.w(`内置渲染轮询失败：${(e as Error).message}`);
      }
      if (reading >= 0 && reading === last) {
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
      html = await ctrl.runJavaScript('document.documentElement.outerHTML');
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
    Log.i(`内置渲染完成：${url}（HTML ${html.length} 字符，正文文本约 ${Math.max(last, 0)} 字符）`);
    return { ok: true, html: html, note: '' };
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

  /** 带超时等待：到点就继续，不等了（Promise 结果被丢弃） */
  private static async withDeadline(p: Promise<void>, timeoutMs: number): Promise<void> {
    const timer = new Promise<void>((resolve) => setTimeout(resolve, timeoutMs));
    await Promise.race([p, timer]);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}
