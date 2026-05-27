# M4BCreater

M4BCreater 是一个原生 macOS 有声书转换工具，用于把散集音频文件转换成带章节、封面和元数据的 `.m4b` 有声书文件。

项目目标是提供一个本地优先、可恢复、进度清晰的桌面工作台：本地目录输入/输出是核心能力，WebDAV 作为可选的远程目录来源或目标。

## 功能特性

- 原生 macOS 14+ SwiftUI 界面。
- 本地目录输入、本地目录输出。
- 可选 WebDAV 输入/输出，支持可视化添加服务器和目录选择。
- WebDAV 凭据通过 macOS Keychain 保存。
- WebDAV 下载采用任务缓存和预取流水线：转码当前音轨时预取后续音轨。
- 每个任务独立保存输入目录、输出目录、元数据、章节、编码配置和进度状态。
- 任务开始后锁定元数据、章节和编码配置，避免恢复状态与产物不一致。
- 支持暂停、继续、取消、重试和删除任务。
- 支持章节/音轨编辑：改名、删除、添加、拖放排序、自动自然排序。
- 支持中英文数字自然排序，避免 `1, 10, 11, 2` 这类顺序错误。
- 支持 `metadata.json`、`nfo`、`cover.*` 自动导入元数据和封面。
- 支持 AAC 编码，默认 `192 kbps`，可选 `32-320 kbps`。
- 内置 FFmpeg/ffprobe，打包后开箱即用。
- 单实例保护：重复启动时会激活已有窗口，不会同时运行多个转换实例。

## 支持的音频格式

当前扫描和添加音轨时识别以下扩展名：

- `mp3`
- `m4a`
- `m4b`
- `aac`
- `flac`
- `wav`
- `ogg`
- `wma`
- `asf`

实际能否转码取决于内置 FFmpeg 的解码能力。

## 元数据导入

创建任务时，应用会扫描输入目录中的辅助文件：

- `cover.jpg`
- `cover.jpeg`
- `cover.png`
- `cover.webp`
- `cover.heic`
- `cover.tiff`
- 其他文件名为 `cover` 且系统可识别的图片格式
- `metadata.json`
- `.nfo`

`metadata.json` 示例：

```json
{
  "title": "别读博，会脱单",
  "subtitle": null,
  "authors": ["Llosa"],
  "narrators": [],
  "series": [],
  "genres": ["Chinese fiction"],
  "tags": ["双男主", "校园"],
  "publishedYear": "2025",
  "publisher": "猫耳FM",
  "description": "<p>讨厌鬼邻居是暗恋的数学教授。</p>",
  "chapters": [
    {
      "id": 0,
      "title": "第一集·逆境和厄运自有妙处",
      "start": 0,
      "end": 2872.068005
    }
  ]
}
```

章节数组会按顺序覆盖扫描到的音轨标题和时长。若章节数量与音轨数量不一致，只会应用重叠部分，并在任务日志中提示。

## WebDAV 缓存策略

WebDAV 不是必须配置的能力。本地输入和本地输出始终可用。

WebDAV 输入时，应用会把远程音轨下载到本地任务缓存，再交给 FFmpeg 转码。流程不是等待全部下载完成才开始，而是：

1. 下载当前可处理音轨。
2. 同时预取后续音轨。
3. 当前音轨下载完成后立即转码成中间片段。
4. 已完成的下载和转码片段会写入任务状态。
5. 任务暂停、失败或应用重启后，已完成部分不会重复执行。

WebDAV 输出时，最终 `.m4b` 会先在本地任务工作区生成，确认完成后再上传到目标目录。

## 构建

```bash
swift build
```

Release 构建：

```bash
swift build -c release
```

## 运行

```bash
swift run M4BCreater
```

## 打包 macOS App 和 DMG

项目提供了打包脚本：

```bash
scripts/package-macos.sh
```

脚本会生成：

- `dist/M4BCreater.app`
- `dist/M4BCreater.dmg`

当前打包产物是本地未公证版本，适合本机使用和开发测试。如果需要正式分发，建议后续切到 Xcode app target 或调整资源加载路径后，再进行 Developer ID 签名和 notarization。

## 内置 FFmpeg

打包前需要确保以下文件存在且可执行：

- `Sources/M4BCreater/Resources/FFmpeg/ffmpeg`
- `Sources/M4BCreater/Resources/FFmpeg/ffprobe`

当前项目按 universal binary 使用，支持 Apple Silicon 和 Intel macOS。

这两个二进制文件不会提交到 git。原因是 FFmpeg/ffprobe 体积通常超过 GitHub 的普通文件限制，克隆仓库后需要自行放入上述目录，再执行构建或打包。

FFmpeg/ffprobe 是第三方组件，不属于本项目原创代码。使用、分发或替换 FFmpeg 时，请同时遵守 FFmpeg 及其编译依赖的许可证要求。

## 项目结构

```text
Sources/M4BCreater/
  App/                 应用入口和单实例控制
  Models/              任务、元数据、缓存和设置模型
  Services/            转换、缓存、存储、WebDAV、元数据和 FFmpeg 服务
  UI/                  SwiftUI 界面
  Resources/           FFmpeg、图标和其他资源

Tests/M4BCreaterTests/ 单元测试
scripts/               打包脚本
dist/                  本地打包产物，不提交到仓库
```

## 许可证

本项目采用 GNU General Public License v3.0 or later 开源。

详见 [LICENSE](LICENSE)。
