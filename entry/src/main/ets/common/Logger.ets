export const LOG_DOMAIN: number = 0xF0F1;
export const TAG: string = 'FanficTrans';

/** 环形缓冲上限：模型排障时最多回看的日志条数 */
const RING_MAX: number = 300;

/** 应用内日志环形缓冲：找文模型的 read_recent_logs 工具从这里取数，
 *  相当于把「开发者挂 hilog 看现场」搬到应用里让模型自己看。 */
const ring: string[] = [];

function stamp(): string {
  const d = new Date();
  const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function record(level: string, msg: string): void {
  // 单条截断：异常堆栈或大 payload 不给撑爆缓冲
  const line = `${stamp()} ${level} ${msg.length > 300 ? `${msg.substring(0, 300)}…` : msg}`;
  ring.push(line);
  if (ring.length > RING_MAX) {
    ring.shift();
  }
}

/**
 * 统一日志出口。发布版只需改这一处的开关，不必逐文件删 console。
 */
export class Log {
  static d(msg: string): void {
    record('D', msg);
    console.debug(`[${TAG}] ${msg}`);
  }

  static i(msg: string): void {
    record('I', msg);
    console.info(`[${TAG}] ${msg}`);
  }

  static w(msg: string): void {
    record('W', msg);
    console.warn(`[${TAG}] ${msg}`);
  }

  static e(msg: string): void {
    record('E', msg);
    console.error(`[${TAG}] ${msg}`);
  }

  /** 最近 n 条日志（时间正序），给找文模型排障用 */
  static recent(n: number): string {
    const take = n > 0 ? Math.min(n, ring.length) : ring.length;
    const start = ring.length - take;
    const out: string[] = [];
    for (let i = start; i < ring.length; i++) {
      out.push(ring[i]);
    }
    return out.join('\n');
  }
}
