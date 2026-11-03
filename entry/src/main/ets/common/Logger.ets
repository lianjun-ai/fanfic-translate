export const LOG_DOMAIN: number = 0xF0F1;
export const TAG: string = 'FanficTrans';

/**
 * 统一日志出口。发布版只需改这一处的开关，不必逐文件删 console。
 */
export class Log {
  static d(msg: string): void {
    console.debug(`[${TAG}] ${msg}`);
  }

  static i(msg: string): void {
    console.info(`[${TAG}] ${msg}`);
  }

  static w(msg: string): void {
    console.warn(`[${TAG}] ${msg}`);
  }

  static e(msg: string): void {
    console.error(`[${TAG}] ${msg}`);
  }
}
