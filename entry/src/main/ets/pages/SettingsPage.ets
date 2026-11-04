import { ProviderConfig, Settings, langName } from '../common/Settings';
import { ChatMessage, LlmProvider } from '../provider/LlmProvider';
import { Log } from '../common/Logger';

interface Preset {
  name: string;
  baseUrl: string;
  model: string;
}

/**
 * 预设。三个字段都按各家官方文档的写法核对过：
 * - DeepSeek 的 base_url 不带 /v1（SDK 自己拼 /chat/completions），模型只有 flash / v4-pro
 * - 智谱 GLM 用 glm-5.3-flash：注意 5.3 系不支持关闭思考（LlmProvider 对它发 reasoning_effort）
 * - OpenAI 的 gpt-4o-mini 已被官方标记弃用（2027-01-14 关停），改用当前在售的 gpt-5-mini
 * - 百炼的兼容模式地址必须是 compatible-mode/v1，qwen-plus 是官方长期保留的通用别名
 * - 硅基流动的模型名带组织前缀，官方示例已推进到 DeepSeek-V3.2
 */
const PRESETS: Preset[] = [
  { name: 'DeepSeek', baseUrl: 'https://api.deepseek.com', model: 'deepseek-flash' },
  { name: '智谱 GLM', baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-5.3-flash' },
  { name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', model: 'gpt-5-mini' },
  { name: '通义千问', baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus' },
  { name: '硅基流动', baseUrl: 'https://api.siliconflow.cn/v1', model: 'deepseek-ai/DeepSeek-V3.2' }
];

const LANGS: string[] = ['zh', 'zh-tw', 'en', 'ja'];

/** 单次请求的源文本 token 上限 */
const BATCHES: number[] = [800, 1200, 2000];

@Entry
@Component
struct SettingsPage {
  @State baseUrl: string = '';
  @State apiKey: string = '';
  @State model: string = '';
  @State searchKey: string = '';
  @State targetLang: string = 'zh';
  @State batchTokens: number = 1200;
  @State preset: number = -1;

  /** 「自定义」chip 的下标：不填充任何字段，三个输入框保持手填 */
  private readonly customIdx: number = PRESETS.length;

  @State testing: boolean = false;
  @State testMsg: string = '';
  @State testOk: boolean = false;
  @State dirty: boolean = false;

  aboutToAppear(): void {
    this.loadConfig();
  }

  private async loadConfig(): Promise<void> {
    const cfg = await Settings.load();
    this.baseUrl = cfg.baseUrl;
    this.apiKey = cfg.apiKey;
    this.model = cfg.model;
    this.searchKey = cfg.searchKey;
    this.targetLang = cfg.targetLang;
    this.batchTokens = cfg.batchTokens;
    this.preset = SettingsPage.matchPreset(cfg.baseUrl) >= 0
      ? SettingsPage.matchPreset(cfg.baseUrl) : this.customIdx;
  }

  private static matchPreset(baseUrl: string): number {
    const b = baseUrl.trim();
    for (let i = 0; i < PRESETS.length; i++) {
      if (PRESETS[i].baseUrl === b) {
        return i;
      }
    }
    return -1;
  }

  private collect(): ProviderConfig {
    const cfg: ProviderConfig = {
      baseUrl: this.baseUrl.trim(),
      apiKey: this.apiKey.trim(),
      model: this.model.trim(),
      temperature: 0.3,
      sourceLang: 'auto',
      targetLang: this.targetLang,
      batchTokens: this.batchTokens,
      searchKey: this.searchKey.trim()
    };
    return cfg;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private async applyPreset(i: number): Promise<void> {
    if (i === this.preset && i === this.customIdx) {
      return;
    }
    // 切走前先把当前 key 记在当前 baseUrl 名下，来回切就不用重填
    await Settings.rememberKey(this.baseUrl, this.apiKey);
    this.preset = i;
    this.dirty = true;
    this.testMsg = '';
    if (i < this.customIdx) {
      const p = PRESETS[i];
      this.baseUrl = p.baseUrl;
      this.model = p.model;
      // 这家存过 key 就自动回填，没存过就清空等着填新的
      const saved = await Settings.savedKey(p.baseUrl);
      this.apiKey = saved;
    } else {
      // 自定义：三个字段全清空，不预填任何内容
      this.baseUrl = '';
      this.apiKey = '';
      this.model = '';
    }
  }

  private async test(): Promise<void> {
    if (this.testing) {
      return;
    }
    const cfg = this.collect();
    if (!Settings.ready(cfg)) {
      this.testOk = false;
      this.testMsg = '接口地址、API Key、模型都填好才能测试';
      return;
    }
    this.testing = true;
    this.testOk = false;
    this.testMsg = '正在连接…';
    try {
      const provider = new LlmProvider(cfg);
      const msgs: ChatMessage[] = [{ role: 'user', content: '请回复两个字：可用' }];
      const reply = await provider.complete(msgs, () => {
      });
      const shown = reply.trim();
      this.testOk = true;
      this.testMsg = shown.length > 0 ? `连接成功，模型回复：${shown.substring(0, 40)}` : '连接成功';
    } catch (e) {
      this.testOk = false;
      this.testMsg = (e as Error).message;
      Log.w(`测试连接失败：${this.testMsg}`);
    } finally {
      this.testing = false;
    }
  }

  private async save(): Promise<void> {
    const cfg = this.collect();
    if (cfg.baseUrl.length === 0) {
      this.toast('请填写接口地址');
      return;
    }
    try {
      await Settings.save(cfg);
      this.dirty = false;
      this.toast('已保存');
    } catch (e) {
      this.toast(`保存失败：${(e as Error).message}`);
    }
  }

  /* ------------------------- 组件 ------------------------- */

  @Builder
  label(text: string, hint: string) {
    Column({ space: 2 }) {
      Text(text)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  chipGroup() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(PRESETS, (p: Preset, i: number) => {
        Text(p.name)
          .fontSize(13)
          .fontColor(this.preset === i ? Color.White : $r('app.color.text_secondary'))
          .backgroundColor(this.preset === i ? $r('app.color.brand_primary') : $r('app.color.page_background'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(14)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => this.applyPreset(this.preset === i ? this.customIdx : i))
      }, (p: Preset) => p.name)
      Text('自定义')
        .fontSize(13)
        .fontColor(this.preset === this.customIdx ? Color.White : $r('app.color.text_secondary'))
        .backgroundColor(this.preset === this.customIdx ? $r('app.color.brand_primary') : $r('app.color.page_background'))
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .borderRadius(14)
        .margin({ right: 8, bottom: 8 })
        .onClick(() => this.applyPreset(this.customIdx))
    }
    .width('100%')
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text('返回')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => this.goBack())
        Text('翻译设置')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(this.dirty ? '保存' : '')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 10 })

      Divider().color($r('app.color.divider'))

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 10 }) {
            this.label('服务商', '自动填好接口地址与模型，Key 会按服务商记住；自定义可填任意 OpenAI 兼容服务商，模型名以各家 /models 接口为准')
            this.chipGroup()
          }
          .width('100%')

          Column({ space: 8 }) {
            this.label('接口地址', 'OpenAI 兼容格式，末尾不需要带 /chat/completions')
            TextInput({ text: $$this.baseUrl })
              .fontSize(13)
              .height(44)
              .backgroundColor($r('app.color.page_background'))
              .fontColor($r('app.color.text_primary'))
              .onChange((v: string) => {
                this.baseUrl = v;
                this.dirty = true;
              })
          }
          .width('100%')

          Column({ space: 8 }) {
            this.label('API Key', '只保存在本机，不会上传到任何第三方')
            TextInput({ text: $$this.apiKey })
              .type(InputType.Password)
              .fontSize(13)
              .height(44)
              .backgroundColor($r('app.color.page_background'))
              .fontColor($r('app.color.text_primary'))
              .onChange((v: string) => {
                this.apiKey = v;
                this.dirty = true;
              })
          }
          .width('100%')

          Column({ space: 8 }) {
            this.label('模型', '必须与所选服务商提供的名称一致')
            TextInput({ text: $$this.model })
              .fontSize(13)
              .height(44)
              .backgroundColor($r('app.color.page_background'))
              .fontColor($r('app.color.text_primary'))
              .onChange((v: string) => {
                this.model = v;
                this.dirty = true;
              })
          }
          .width('100%')

          Column({ space: 8 }) {
            this.label('搜索 Key（可选）', 'Tavily，tavily.com 免费注册。填写后智能检索改为真实联网搜索（更准确）；留空则用模型记忆检索')
            TextInput({ text: $$this.searchKey })
              .type(InputType.Password)
              .fontSize(13)
              .height(44)
              .backgroundColor($r('app.color.page_background'))
              .fontColor($r('app.color.text_primary'))
              .onChange((v: string) => {
                this.searchKey = v;
                this.dirty = true;
              })
          }
          .width('100%')

          Divider().color($r('app.color.divider'))

          Column({ space: 10 }) {
            this.label('译文语言', '')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(LANGS, (code: string) => {
                Text(langName(code))
                  .fontSize(13)
                  .fontColor(this.targetLang === code ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.targetLang === code ? $r('app.color.brand_primary') :
                  $r('app.color.page_background'))
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.targetLang = code;
                    this.dirty = true;
                  })
              }, (code: string) => code)
            }
            .width('100%')
          }
          .width('100%')

          Column({ space: 10 }) {
            this.label('单次请求量', '越小越省上下文、越稳；越大越省请求次数、译名更统一')
            Row({ space: 8 }) {
              ForEach(BATCHES, (n: number) => {
                Text(`约 ${n}`)
                  .fontSize(13)
                  .fontColor(this.batchTokens === n ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.batchTokens === n ? $r('app.color.brand_primary') :
                  $r('app.color.page_background'))
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .onClick(() => {
                    this.batchTokens = n;
                    this.dirty = true;
                  })
              }, (n: number) => `${n}`)
              Blank()
            }
            .width('100%')
          }
          .width('100%')

          Divider().color($r('app.color.divider'))

          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Button(this.testing ? '连接中…' : '测试连接')
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .backgroundColor($r('app.color.page_background'))
                .fontColor($r('app.color.text_primary'))
                .enabled(!this.testing)
                .onClick(() => {
                  this.test();
                })
              Button('保存')
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .backgroundColor($r('app.color.brand_primary'))
                .fontColor(Color.White)
                .onClick(() => {
                  this.save();
                })
            }
            .width('100%')

            if (this.testMsg.length > 0) {
              Text(this.testMsg)
                .fontSize(12)
                .fontColor(this.testOk ? $r('app.color.brand_primary') : $r('app.color.danger'))
                .width('100%')
                .lineHeight(18)
            }
          }
          .width('100%')

          Text('说明：译文只保存在本机数据库，不会上传。调用第三方接口产生的费用由你的账号承担。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(17)
            .width('100%')
            .margin({ bottom: 20 })
        }
        .width('100%')
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_background'))
  }
}
