# 同人译站

一款 HarmonyOS NEXT 上的同人小说**抓取 · 翻译 · 阅读**助手。支持 AI 对话式找文、FicHub 一键转 EPUB、本地导入，并内置基于大模型的逐章翻译流水线（含术语表）。

> 仅供个人学习与技术研究使用。所有小说内容的版权归原作者及原站点所有。

## 功能特性

### 🔍 AI 找文（对话式 Agent）
- 像聊天一样描述需求：「HP 时间穿越的长篇同人文」
- 模型自主决定调用哪些工具：`web_search`（Tavily 搜索）、`fetch_page`（读网页）、`fichub_get`（FicHub 转 EPUB 并下载）、`download_file`（直链下载）
- 思考过程与工具调用全程流式上屏，可随时中断
- 命中即自动下载到本地，点一下按钮直接进书架；已下载过的作品自动去重，避免对 FicHub 重复请求触发限流

### 📥 本地导入
- 支持 EPUB / TXT / HTML 三种格式，文件解析后自动分章入库
- 默认跳过书架里已有的书（内容指纹 + 标题作者双层去重），需要时可用开关允许重复导入
- 在其它应用里分享作品链接，可直接唤起本应用的 AI 找文继续下载

### 📚 书架
- 分组管理：自定义分组、长按删除分组（书自动退回「未分组」）
- 手动排序：排序模式下 ↑↓ 调整顺序，分组内重排不影响其它分组
- 从搜索页、导入页一键入库，重复导入自动识别（内容指纹 + 标题作者双层去重）

### 📖 阅读与翻译
- EPUB / TXT / HTML 解析入库，分章阅读
- 基于 OpenAI 兼容接口的逐章翻译流水线（支持 DeepSeek 等任何兼容服务商）
- 术语表：自定义译名对照，翻译时统一人名/地名/专有名词
- 翻译任务可中断续跑，进度持久化

## 构建运行

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（需支持 API 6.1.0(23)）
2. 克隆本仓库后用 DevEco Studio 打开
3. `File > Project Structure > Signing Configs` 勾选 **Automatically generate signature** 自动生成调试签名
4. 连接真机或启动模拟器，Run 即可

命令行构建：

```bash
hvigorw.js assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

## 配置说明

在 App 内 **设置** 页填写：

| 配置项 | 说明 |
|---|---|
| LLM 服务商 | 任意 OpenAI 兼容接口（Base URL + API Key + 模型名），默认预设 DeepSeek |
| Tavily API Key | AI 找文使用，[tavily.com](https://tavily.com) 免费申请 |

API Key 仅保存在设备本地偏好中，不上传任何服务器。

## 工程结构

```
entry/src/main/ets/
├── pages/          # 页面：书架、AI 找文、导入、阅读、术语表、设置
├── fetch/          # AI 找文 Agent：工具集、FicHub 客户端、下载暂存
├── parser/         # EPUB/TXT/HTML 解析入库
├── translator/     # 翻译流水线（分章任务、术语注入）
├── provider/       # LLM 调用封装（OpenAI 兼容协议 + SSE 流式）
├── data/           # 关系型数据库 DAO（作品/章节/段落/术语/进度）
├── model/          # 数据模型
└── common/         # 日志等通用工具
```

## License

MIT
