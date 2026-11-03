import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from './Logger';

const STORE_NAME: string = 'ui_state';
const KEY_FONT_STEP: string = 'reader_font_step';

/**
 * 界面偏好。
 *
 * 阅读字号是「一次设定、长期使用」的参数，每次都回到默认值会让人反复调整。
 * 这类状态与翻译配置无关，单独一个 preferences 文件，免得污染 Settings 的结构。
 */
export class UiPrefs {
  private static store: preferences.Preferences | null = null;
  private static pending: Promise<preferences.Preferences> | null = null;
  private static ctx: common.Context | null = null;

  static init(ctx: common.Context): void {
    UiPrefs.ctx = ctx;
  }

  private static open(): Promise<preferences.Preferences> {
    if (UiPrefs.store !== null) {
      return Promise.resolve(UiPrefs.store);
    }
    if (UiPrefs.pending !== null) {
      return UiPrefs.pending;
    }
    const ctx = UiPrefs.ctx;
    if (ctx === null) {
      return Promise.reject(new Error('UiPrefs 未初始化'));
    }
    UiPrefs.pending = preferences.getPreferences(ctx, STORE_NAME)
      .then((p: preferences.Preferences) => {
        UiPrefs.store = p;
        UiPrefs.pending = null;
        return p;
      })
      .catch((e: Error) => {
        UiPrefs.pending = null;
        Log.e(`打开界面偏好失败：${e.message}`);
        throw e as Error;
      });
    return UiPrefs.pending;
  }

  /** 读失败一律回落默认值，阅读界面不该因为一个偏好读不到而报错 */
  static async fontStep(fallback: number): Promise<number> {
    try {
      const p = await UiPrefs.open();
      const raw = await p.get(KEY_FONT_STEP, fallback);
      const n = typeof raw === 'number' ? raw : fallback;
      return n;
    } catch (e) {
      return fallback;
    }
  }

  static async setFontStep(step: number): Promise<void> {
    try {
      const p = await UiPrefs.open();
      await p.put(KEY_FONT_STEP, step);
      await p.flush();
    } catch (e) {
      Log.w(`保存字号失败：${(e as Error).message}`);
    }
  }
}
