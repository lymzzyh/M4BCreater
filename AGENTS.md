# AGENTS.md

本文档面向在本仓库中工作的 AI / 自动化开发代理。开始任何改动前先阅读本文件，再结合 `README.md` 理解产品目标。

## 项目概览

M4BCreater 是一个原生 macOS 14+ SwiftUI 应用，用于把散集有声书音频转换为带章节、封面和元数据的 `.m4b` 文件。

核心能力：

- 本地目录输入、本地目录输出。
- 可选 WebDAV 输入/输出，WebDAV 服务器凭据存入 macOS Keychain。
- WebDAV 输入采用本地缓存和预取流水线：处理当前音轨时预取后续音轨。
- 任务支持暂停、继续、取消、重试、删除和跨重启恢复。
- 任务开始后锁定元数据、章节、编码、调速、分卷等会影响产物一致性的设置。
- 创建任务时扫描音轨、`metadata.json`、`.nfo`、`cover.*`。
- 支持章节编辑、拖拽排序、中英文数字自然排序。
- 支持 AAC 码率选择、输出调速、分卷输出、超大 M4B 分片封装和封面注入。

## 技术栈

- Swift 6 / Swift Package Manager
- macOS 14+
- SwiftUI + AppKit interop
- Swift Concurrency
- JSON 文件持久化，位置在 Application Support
- URLSession / FoundationNetworking 风格的 WebDAV 实现
- bundled FFmpeg / ffprobe
- 测试框架：Swift Testing

## 目录结构

```text
Sources/M4BCreater/
  App/                 应用入口、单实例控制
  Models/              任务、元数据、缓存、设置等 Codable 模型
  Services/            转换协调、缓存、FFmpeg、WebDAV、Keychain、元数据
  UI/                  SwiftUI 界面
  Resources/           图标、FFmpeg 占位目录和打包资源

Tests/M4BCreaterTests/ 单元测试
scripts/               打包脚本
dist/                  本地打包产物，不提交
```

## 常用命令

构建：

```bash
swift build
```

测试：

```bash
swift test
```

运行：

```bash
swift run M4BCreater
```

打包 App 和 DMG：

```bash
bash scripts/package-macos.sh
```

打包产物：

```text
dist/M4BCreater.app
dist/M4BCreater.dmg
```

## FFmpeg 资源规则

`ffmpeg` 和 `ffprobe` 必须放在：

```text
Sources/M4BCreater/Resources/FFmpeg/ffmpeg
Sources/M4BCreater/Resources/FFmpeg/ffprobe
```

这些二进制通常很大，不能提交到 git。`.gitignore` 已忽略以下文件：

```text
Sources/M4BCreater/Resources/FFmpeg/ffmpeg
Sources/M4BCreater/Resources/FFmpeg/ffprobe
Sources/M4BCreater/Resources/FFmpeg/ffmpeg-arm64
Sources/M4BCreater/Resources/FFmpeg/ffmpeg-x86_64
Sources/M4BCreater/Resources/FFmpeg/ffprobe-arm64
Sources/M4BCreater/Resources/FFmpeg/ffprobe-x86_64
```

不要把 FFmpeg 二进制加入提交。GitHub 会拒绝超过 100 MB 的普通文件。

## 持久化与兼容性

当前持久化由 `JobStore` 写 JSON 状态文件，不使用 SwiftData/Core Data。

改动模型时必须注意：

- 所有任务、设置、缓存、WebDAV 连接模型都应保持 `Codable`。
- 新增字段必须提供默认值或自定义 `init(from:)`，保证旧状态文件能加载。
- 旧任务不应因为缺失新字段而丢失或崩溃。
- 如果字段会影响最终产物，任务开始后必须锁定。

重点模型：

- `ConversionJob`
- `EncodingSettings`
- `VolumeSplitSettings`
- `AppSettings`
- `ConversionProgress`
- `CacheEntry`
- `WebDAVCredential`

## 任务锁定规则

只要任务进入过运行状态，`hasStarted` 会变为 `true`。此后无论任务处于 `paused`、`failed`、`completed`、`cancelled`，都不能再编辑会改变产物的内容。

不可在已开始任务中修改：

- 输入/输出位置
- 元数据
- 封面
- 章节/音轨列表
- 章节顺序
- 编码设置
- 输出速度
- 分卷设置

如需修改已开始任务，用户应删除并重新创建任务。

## 转换流程

高层流程在 `ConversionCoordinator`：

1. 创建任务时扫描音轨和辅助元数据。
2. 按章节顺序准备源文件。
3. WebDAV 输入按需下载并预取。
4. 每个音轨转码为中间 `.m4a`。
5. 根据分卷设置把中间片段分组。
6. 每组封装为一个 `.m4b`。
7. 写入本地输出或上传 WebDAV。

本地输入不强制复制源文件；中间产物写入任务工作区以支持恢复。

## WebDAV 缓存与流水线约束

WebDAV 输入必须保留可恢复缓存策略：

- 不要回退成“全部下载完再开始转码”。
- 应保持“下载当前音轨，同时预取后续音轨”的流水线。
- 下载和音轨转码分别使用各自的并发设置，实际并发由剩余音轨数限制。
- 已下载文件、已完成中间转码片段、已完成封装阶段应尽量复用。
- 失败或暂停任务要保留恢复所需缓存和状态。
- 完成任务是否清理缓存由用户设置决定。

WebDAV 输出必须先在本地工作区生成完整 `.m4b`，成功后再上传。

## FFmpeg 约束

`FFmpegRunner` 负责调用内置 FFmpeg/ffprobe。

注意事项：

- 进程必须使用 `-nostdin`，避免输入焦点或终端交互污染。
- 转码进度来自 `-progress pipe:2`。
- 日志进入 UI 前需要节流，避免 FFmpeg 高频输出卡住界面。
- AAC 编码默认 `192 kbps`。
- 输出调速使用 `atempo`，范围 `0.5x...3.0x`，步进 `0.1x`。
- `atempo` 单段仅支持 `0.5...2.0`，大于 `2.0` 时必须拆成链式滤镜，例如 `3.0x` 使用 `atempo=2,atempo=1.5`。
- `1.0x` 不应添加 `-filter:a`。
- 调速会改变音轨时长，章节时长应来自转码后的中间文件探测结果。

## 超大 M4B 与封面

普通 `.m4b` 对超长、超大文件可能在写 trailer 时因 MP4 sample table 过大而失败。

当前策略：

- `AppSettings.fragmentedM4BThresholdHours` 默认 `72`
- `AppSettings.fragmentedM4BThresholdTracks` 默认 `500`
- 超过任一阈值时使用 fragmented M4B：

```text
-movflags +empty_moov+default_base_moof
-frag_duration 60000000
```

FFmpeg fragmented 输出会把 attached picture 退化成普通 video stream，Finder/Music 可能不显示封面。因此分片封装时不要让 FFmpeg 写封面流；封装后由 `MP4ArtworkWriter` 写入 `moov.udta.meta.ilst.covr`。

修改这里时必须验证：

- 普通 M4B 仍有 attached picture。
- fragmented M4B 能保留 `covr` 元数据。
- 大文件处理不能把完整 10GB+ 文件一次性读入内存。

## 分卷输出

分卷是任务级设置，模型为 `VolumeSplitSettings`。

规则：

- `tracksPerVolume <= 0` 表示不分卷。
- 新建任务和任务详情都可设置。
- 任务开始后锁定。
- 分卷按当前章节顺序切分。
- 每卷独立封装、写入章节、元数据和封面。
- 输出命名示例：

```text
书名 - Vol. 01.m4b
书名 - Vol. 02.m4b
```

如果总音轨数不超过每卷音轨数，不应改名，仍输出原始文件名。

## UI 约束

界面是 macOS 原生工具型应用，保持简洁、密集、稳定。

开发 UI 时注意：

- 不要做营销式首页。
- 控件优先使用系统控件和 SF Symbols。
- 任务开始后所有产物相关编辑控件必须 disabled，并显示锁定状态。
- 长列表要使用滚动区域，避免撑爆详情页。
- 进度展示要区分下载、转码、封装、写出。
- WebDAV 下载速度仅在 WebDAV 输入时显示。
- 不要恢复左下角 FFmpeg/WebDAV 提示文案。

## 测试要求

改动后至少运行：

```bash
swift build
swift test
```

涉及打包、资源、图标、FFmpeg bundle 时，还要运行：

```bash
bash scripts/package-macos.sh
```

新增行为应补充测试到 `Tests/M4BCreaterTests/StorageAndCacheTests.swift`，尤其是：

- 旧 JSON 兼容默认值。
- FFmpeg 参数生成。
- 章节排序、分卷命名。
- 缓存和 WebDAV 策略。
- fragmented M4B 封面元数据。

## Git 与提交

- 不要提交 `.build/`、`dist/`、`.DS_Store`。
- 不要提交 FFmpeg/ffprobe 二进制。
- 不要重写或删除用户未要求删除的本地文件。
- 如果工作区已有无关改动，不要回滚。
- 每组完成的功能或修复应提交一个清晰 commit。

## 开发优先级

遇到取舍时按以下顺序判断：

1. 不破坏已有任务和用户状态。
2. 不破坏 WebDAV 缓存恢复能力。
3. 不让超大任务回到内存爆炸路径。
4. 不让 FFmpeg 高频日志卡 UI。
5. 保持 macOS 原生、简洁、可理解的界面。
6. 为新增行为补测试。

