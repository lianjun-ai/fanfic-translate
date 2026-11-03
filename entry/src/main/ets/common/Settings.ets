import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from './Logger';

/**
 * 翻译服务配置。
 *
 * 只存"调用某家 OpenAI 兼容接口"所需的四个要素，不绑定具体厂商：
 * 换服务商只改 baseUrl 与 model，代码一行不动。
 */
export interface ProviderConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  temperature: number;
  /** 原语言，auto 表示让模型自行判断 */
  sourceLang: string;
  /** 目标语言 */
  targetLang: string;
  /** 单次请求的源文本 token 上限 */
  batchTokens: number;
  /** 智能检索用的搜索服务 Key（Tavily，tavily.com 免费申请），与翻译 Key 分开 */
  searchKey: string;
}

const STORE_NAME: string = 'app_settings';
const KEY_CONFIG: string = 'provider_config';

export class Settings {
  private static store: preferences.Preferences | null = null;
  private static pending: Promise<preferences.Preferences> | null = null;
  private static ctx: common.Context | null = null;

  /** 由 EntryAbility.onCreate 调用一次 */
  static init(ctx: common.Context): void {
    Settings.ctx = ctx;
  }

  private static open(): Promise<preferences.Preferences> {
    if (Settings.store !== null) {
      return Promise.resolve(Settings.store);
    }
    if (Settings.pending !== null) {
      return Settings.pending;
    }
    const ctx = Settings.ctx;
    if (ctx === null) {
      return Promise.reject(new Error('Settings 未初始化'));
    }
    Settings.pending = preferences.getPreferences(ctx, STORE_NAME)
      .then((p: preferences.Preferences) => {
        Settings.store = p;
        Settings.pending = null;
        return p;
      })
      .catch((e: Error) => {
        Settings.pending = null;
        Log.e(`打开配置存储失败：${e.message}`);
        throw e as Error;
      });
    return Settings.pending;
  }

  static defaults(): ProviderConfig {
    const c: ProviderConfig = {
      baseUrl: 'https://api.deepseek.com',
      apiKey: '',
      model: 'deepseek-flash',
      temperature: 0.3,
      sourceLang: 'auto',
      targetLang: 'zh',
      batchTokens: 1200,
      searchKey: ''
    };
    return c;
  }

  /**
   * 旧模型名迁移。
   *
   * deepseek-chat / deepseek-reasoner 已于 2026-07-24 停止服务，
   * 现在可用的是 deepseek-flash 与 deepseek-v4-pro。老配置直接调用会报
   * 「Model Not Exist」，用户只会看到一句莫名其妙的失败，所以读到就换掉。
   */
  private static fixModel(model: string): string {
    const m = model.trim();
    if (m === 'deepseek-chat' || m === 'deepseek-reasoner') {
      return 'deepseek-flash';
    }
    return m;
  }

  /** 官方给的 base_url 不带 /v1（SDK 自己拼 /chat/completions），老配置里带了就去掉 */
  private static fixBaseUrl(url: string): string {
    let u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u === 'https://api.deepseek.com/v1') {
      return 'https://api.deepseek.com';
    }
    return u;
  }

  static async load(): Promise<ProviderConfig> {
    try {
      const p = await Settings.open();
      const raw = await p.get(KEY_CONFIG, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return Settings.defaults();
      }
      const parsed = JSON.parse(raw) as ProviderConfig;
      const d = Settings.defaults();
      // 逐字段兜底：老版本配置缺字段时不应该炸掉整个流程
      const cfg: ProviderConfig = {
        baseUrl: Settings.fixBaseUrl(parsed.baseUrl !== undefined && parsed.baseUrl !== null
          ? parsed.baseUrl : d.baseUrl),
        apiKey: parsed.apiKey !== undefined && parsed.apiKey !== null ? parsed.apiKey : '',
        model: Settings.fixModel(parsed.model !== undefined && parsed.model !== null ? parsed.model : d.model),
        temperature: parsed.temperature !== undefined && parsed.temperature !== null ? parsed.temperature : d.temperature,
        sourceLang: parsed.sourceLang !== undefined && parsed.sourceLang !== null ? parsed.sourceLang : d.sourceLang,
        targetLang: parsed.targetLang !== undefined && parsed.targetLang !== null ? parsed.targetLang : d.targetLang,
        batchTokens: parsed.batchTokens !== undefined && parsed.batchTokens !== null ? parsed.batchTokens : d.batchTokens,
        searchKey: parsed.searchKey !== undefined && parsed.searchKey !== null ? parsed.searchKey : ''
      };
      return cfg;
    } catch (e) {
      Log.w(`读取配置失败，使用默认值：${(e as Error).message}`);
      return Settings.defaults();
    }
  }

  static async save(cfg: ProviderConfig): Promise<void> {
    const p = await Settings.open();
    await p.put(KEY_CONFIG, JSON.stringify(cfg));
    await p.flush();
  }

  /** 是否已经具备发起翻译的条件 */
  static ready(cfg: ProviderConfig): boolean {
    return cfg.baseUrl.trim().length > 0 && cfg.apiKey.trim().length > 0 && cfg.model.trim().length > 0;
  }
}

/** 语言代码 → 中文名，用于提示词与界面 */
export function langName(code: string): string {
  if (code === 'zh') {
    return '简体中文';
  }
  if (code === 'zh-tw') {
    return '繁體中文';
  }
  if (code === 'en') {
    return 'English';
  }
  if (code === 'ja') {
    return '日本語';
  }
  if (code === 'ko') {
    return '한국어';
  }
  if (code === 'auto') {
    return '原文语言';
  }
  return code;
}
