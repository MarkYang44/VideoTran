# VideoTran

**适用于 Apple silicon Mac 的日语 → 简体中文字幕工具。** 支持实时悬浮字幕、IINA 播放同步和 SRT 导出。语音识别和翻译均在本机运行。

[下载最新版](https://github.com/MarkYang44/VideoTran/releases/latest) · [问题反馈](https://github.com/MarkYang44/VideoTran/issues)

## 下载与安装

1. 从 [GitHub Releases](https://github.com/MarkYang44/VideoTran/releases/latest) 下载 `VideoTran-*-macOS-arm64.dmg`，打开镜像，将 **VideoTran** 拖到「应用程序」。
2. 如需 IINA 同步，下载同一版本的 `VideoTran.iinaplgz`，双击并按 IINA 提示安装。
3. 首次使用 Apple 模型时，按系统提示下载日语和简体中文语言包。

VideoTran 面向 **macOS 15 或更新版本**的 Apple silicon Mac。发行包使用 ad hoc 签名，尚未经过 Apple 公证。Release 同时提供 `SHA256SUMS.txt`。

## 功能与使用方式

| 功能 | 使用方式 | 所需组件 |
| --- | --- | --- |
| 实时悬浮字幕 | 在播放器中播放视频，在 VideoTran 里选中该播放器，点击「开始」。首次使用需授权系统音频录制。 | 日语语音识别模型 |
| IINA 同步 | 在 IINA 打开本地视频，选择「插件 → 同步翻译此窗口」，再在 VideoTran 中点击「IINA 同步」。 | IINA 1.4+、VideoTran 插件、FFmpeg |
| SRT 导出 | 点击「导出 SRT…」，选择本地视频和保存位置。完成后将生成的字幕加载到播放器。 | FFmpeg |

在控制台勾选「显示日文原文」即可对照译文。悬浮字幕显示在鼠标所在的屏幕。使用过程中可最小化控制台，关闭窗口会停止当前任务。

IINA 同步和 SRT 导出支持 **MP4、MKV、MOV、M4V 和 WebM**。VideoTran 会优先翻译带日语标记的内嵌文本字幕，或视频同目录下的 `影片名.ja.srt`、`影片名.jpn.srt`、`影片名.ja-JP.srt`。没有可用文本字幕时，会优先选取日语音轨进行转写。IINA 同步一次处理一个窗口，跳到尚未处理的位置可能需要等待字幕生成。

## 依赖与模型

IINA 同步和 SRT 导出需要 `ffmpeg` 和 `ffprobe`。使用 Whisper 进行实时悬浮转写时也需要 FFmpeg。

```sh
brew install ffmpeg
```

- **Apple Speech** 适用于 macOS 26+，需安装系统日语语音识别模型。
- **Whisper** 可用于 macOS 15 上的语音识别，也可用于较新的 macOS。运行 `brew install whisper-cpp`，然后将 [Whisper 多语模型](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) `ggml-large-v3.bin` 或 `ggml-large-v3-turbo.bin` 放到 `~/Library/Application Support/VideoTran/`。也可从终端通过 `VIDEO_SUBTITLE_MODEL` 和 `VIDEO_SUBTITLE_WHISPER` 指定绝对路径。
- **Apple Translation** 负责生成简体中文译文。已有日文文本字幕时，IINA 同步和 SRT 导出可直接翻译字幕。

识别效果会受音量、背景声和对白重叠影响。实时模式在处理速度不足时可能漏句。需要完整字幕时，可优先使用已有日文字幕或导出 SRT。

## 开发与验证

在 Apple silicon Mac 上使用 Xcode 26 或相应的 Command Line Tools 构建。IINA 插件测试需要 Node.js。

```sh
./Scripts/build-app.sh
swift run SubtitleCoreTests
node Tests/iina-plugin-test.cjs
```

构建产物位于 `dist/`，包括 `VideoTran.app`、Apple silicon DMG 和 `VideoTran.iinaplgz`。实时音频捕获已在 macOS 27.0.1 上使用 IINA 1.4.4、QuickTime Player 和 VLC 3.0.24 验证。更多兼容性与测试范围见[验收记录](docs/implementation-plan.md)。

## English quick start

VideoTran provides on-device Japanese-to-Simplified Chinese subtitles for Apple silicon Macs. Install the DMG from [Releases](https://github.com/MarkYang44/VideoTran/releases/latest), then start playback and select the player in VideoTran. For timeline-synced subtitles, install the companion plugin in IINA 1.4 or later and start IINA Sync in VideoTran. FFmpeg is required for IINA Sync and SRT export.
