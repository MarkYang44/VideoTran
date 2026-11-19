# VideoTran

Apple silicon Mac 上的日语 → 简体中文菜单栏应用。日语转写和翻译都在本机运行。首次使用 Apple 模型时需要下载相应的语言包。

## 安装

从 [GitHub Releases](https://github.com/MarkYang44/VideoTran/releases/latest) 下载 Apple silicon DMG。打开镜像，将 VideoTran 拖到 Applications。使用 IINA 同步时，另行下载并安装同一版本的插件包。DMG 内的应用使用 ad hoc 签名，未经过 Apple 公证。

## 开始用

- **实时悬浮字幕**。打开视频并开始播放，启动 `VideoTran.app`，在列表里选择播放器，点「开始」。首次使用按 macOS 提示授权系统音频录制。悬浮字幕显示在鼠标所在的屏幕。保留或最小化控制台窗口，关闭窗口会停止当前任务。
- **IINA 同步**。在 IINA 1.4+ 中打开 `VideoTran.iinaplgz` 安装本机插件。打开本地视频后，从 IINA 的「插件」菜单选「同步翻译此窗口」，再到字幕 App 点「IINA 同步」。插件使用 IINA 的播放位置显示译文。应用会先翻译匹配的日文文本字幕，没有就预读音轨。
- **导出 SRT**。在应用中点「导出 SRT…」，选择本地视频和输出位置。完成后把生成的字幕文件加载到播放器中。

同步和导出支持 MP4、MKV、MOV、M4V、WebM，需要 `ffmpeg` 和 `ffprobe`。会识别有日语标记的内嵌文本字幕，或视频旁的 `影片名.ja.srt`、`影片名.jpn.srt`、`影片名.ja-JP.srt`。图像字幕走音轨转写。影片含多条音轨时优先用日语轨。IINA 同步目前一次处理一个窗口，切片缺少缓存时跳转后要等推理。

**原文和译文**。应用没有敏感词过滤、打码或同义词替换。Apple Speech 的礼貌化替换选项已关闭。译文由 Apple Translation 生成，模型仍可能误听、误译或处理不好语境。勾选「显示日文原文」可对照。

## 模型与依赖

macOS 15+，仅 Apple silicon。macOS 26+ 可使用 Apple Speech 日语模型。macOS 15 的无字幕视频需要安装 Whisper。只翻译已有日文文本字幕时无需语音模型。

```sh
brew install ffmpeg
brew install whisper-cpp       # 使用 Whisper 时安装
```

Whisper 使用[官方多语模型](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md)。将 `ggml-large-v3.bin` 或 `ggml-large-v3-turbo.bin` 放在 `~/Library/Application Support/VideoTran/`。两者同时存在时优先使用大型模型。也可通过 `VIDEO_SUBTITLE_MODEL` 和 `VIDEO_SUBTITLE_WHISPER` 从终端指定绝对路径。实时模式按停顿或最长约 6 秒切段，推理跟不上时优先处理新音频，可能漏句。IINA 预读和 SRT 导出更适合追求时间轴和完整性的场景。

## 构建与验证

需要 Xcode 26 或对应的 Command Line Tools，在 Apple silicon Mac 上运行。

```sh
./Scripts/build-app.sh
swift run SubtitleCoreTests
node Tests/iina-plugin-test.cjs
```

构建产物在 `dist`，包括 App、Apple silicon DMG 和 IINA 插件包。App 为本地 ad hoc 签名，重新构建后 macOS 可能再次提示授权。IINA 桥接使用插件数据目录内的文件，暂停或跳转由播放器位置决定。通过「停止同步翻译」结束窗口的桥接。
