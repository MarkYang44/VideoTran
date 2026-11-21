import AppKit
import Combine
import SwiftUI
import Translation
import UniformTypeIdentifiers
import SubtitleCore

@MainActor final class CaptionController: ObservableObject {
    struct Player: Identifiable {
        let id: pid_t
        let name: String
        /// The picker title. It adds the PID only when two running apps share a name.
        let title: String
        /// Bundle identifier, or the name for apps without one. Survives relaunches.
        let key: String
        let icon: NSImage?
        let isMediaPlayer: Bool
    }

    enum Outcome { case succeeded, failed }

    private enum Job {
        case live(Player)
        case iina
        case export(URL, URL)
        case sample
    }

    private enum Defaults {
        static let showJapanese = "showJapanese"
        static let lastPlayer = "lastPlayer"
    }

    static let japanese = Locale.Language(identifier: "ja")
    static let chinese = Locale.Language(identifier: "zh-Hans")
    private static let mediaPlayers: Set<String> = [
        "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.firecore.infuse", "io.mpv",
    ]

    @Published private(set) var players: [Player] = []
    @Published var selectedPlayer: pid_t = 0
    /// True while a file is dragged over the control window.
    @Published var isDropTargeted = false
    @Published var showJapanese: Bool {
        didSet {
            UserDefaults.standard.set(showJapanese, forKey: Defaults.showJapanese)
            floating.showsJapanese = showJapanese
            if let iinaSession { try? bridge.publish(session: iinaSession, cues: iinaCues, showJapanese: showJapanese) }
        }
    }
    @Published private(set) var status = "选择播放器后开始实时翻译。"
    /// How the last task ended; the status row shows it as a symbol.
    @Published private(set) var outcome: Outcome?
    /// SRT export progress from 0 to 1. Tasks without a known length leave it nil.
    @Published private(set) var progress: Double?
    @Published private(set) var exportedFile: URL?
    @Published private(set) var lastJapanese = ""
    @Published private(set) var lastChinese = ""
    @Published private(set) var isRunning = false
    /// True while a task that produces captions runs. The preview keeps its place from the start.
    @Published private(set) var isCaptioning = false
    @Published private(set) var configuration: TranslationSession.Configuration?

    private let floating = FloatingCaptions()
    private var nextConfiguration = TranslationSession.Configuration(source: japanese, target: chinese)
    private var job: Job?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var audio: ProcessAudio?
    private var hideTask: Task<Void, Never>?
    private let bridge = IINABridge()
    private var iinaSession: String?
    private var iinaCues: [TranslatedCaption] = []
    /// The latest IINA window VideoTran answered. Each request starts IINA Sync once, so Stop stays stopped.
    private var answeredIINASession: String?
    /// The player VideoTran picked on its own. The picker keeps following new candidates until the user chooses.
    private var automaticPlayer: pid_t = 0
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        showJapanese = UserDefaults.standard.object(forKey: Defaults.showJapanese) as? Bool ?? true
        floating.showsJapanese = showJapanese
        refreshPlayers()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in self?.refreshPlayers() }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier }
            .sink { [weak self] pid in self?.playerDidExit(pid) }
            .store(in: &subscriptions)
    }

    func refreshPlayers() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.localizedName != nil
        }
        let sharedNames = Dictionary(grouping: apps) { $0.localizedName ?? "" }.filter { $0.value.count > 1 }.keys
        players = apps.map { app in
            let name = app.localizedName ?? ""
            return Player(id: app.processIdentifier, name: name,
                          title: sharedNames.contains(name) ? "\(name) · \(app.processIdentifier)" : name,
                          key: app.bundleIdentifier ?? name, icon: Self.menuIcon(app.icon),
                          isMediaPlayer: Self.mediaPlayers.contains(app.bundleIdentifier ?? ""))
        }.sorted { a, b in
            a.isMediaPlayer != b.isMediaPlayer ? a.isMediaPlayer
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        let selectionExited = !players.contains { $0.id == selectedPlayer }
        if selectionExited || (selectedPlayer == automaticPlayer && !isRunning) {
            let remembered = UserDefaults.standard.string(forKey: Defaults.lastPlayer)
            automaticPlayer = (players.first { $0.key == remembered } ?? players.first)?.id ?? 0
            if selectedPlayer != automaticPlayer { selectedPlayer = automaticPlayer }
        }
    }

    func startLive() {
        guard let player = players.first(where: { $0.id == selectedPlayer }) else { return }
        UserDefaults.standard.set(player.key, forKey: Defaults.lastPlayer)
        start(.live(player))
    }

    private func playerDidExit(_ pid: pid_t) {
        if case let .live(player) = job, player.id == pid {
            stop()
            status = "\(player.name) 已退出。"
        }
        refreshPlayers()
    }

    func startIINA() { start(.iina) }
    func testTranslation() { start(.sample) }

    /// Starts IINA Sync when the plugin asks for a window VideoTran has not answered yet,
    /// so choosing 同步翻译此窗口 in IINA is the only step.
    func answerIINARequest() {
        // Waits while an open or save panel is up, so it never takes over an export being set up.
        guard !isRunning, NSApp.modalWindow == nil,
              let state = bridge.state(), state.session != answeredIINASession else { return }
        answeredIINASession = state.session
        start(.iina)
    }

    func exportSubtitles() {
        let open = NSOpenPanel()
        open.message = "选择要生成简体中文字幕的本地视频"
        open.canChooseDirectories = false
        open.allowedContentTypes = MediaFile.extensions.compactMap { UTType(filenameExtension: $0) }
        guard open.runModal() == .OK, let input = open.url else { return }
        saveSubtitles(for: input)
    }

    /// Handles files dropped on the control window. Returning false bounces the drop back.
    func exportDropped(_ urls: [URL]) -> Bool {
        guard !isRunning else { return false }
        let videos = urls.filter(MediaFile.isSupported)
        guard videos.count == 1, let input = videos.first else {
            status = videos.isEmpty ? "请拖入 MP4、MKV、MOV、M4V 或 WebM 视频。" : "一次拖入一个视频即可。"
            outcome = .failed
            return false
        }
        // Let the drag session finish before the save panel takes over.
        DispatchQueue.main.async {
            NSApp.activate()
            self.saveSubtitles(for: input)
        }
        return true
    }

    func revealExportedFile() {
        if let exportedFile { NSWorkspace.shared.activateFileViewerSelecting([exportedFile]) }
    }

    private func saveSubtitles(for input: URL) {
        let save = NSSavePanel()
        save.message = "选择简体中文字幕的保存位置"
        save.directoryURL = input.deletingLastPathComponent()
        save.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + ".zh-Hans.srt"
        save.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let output = save.url else { return }
        guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath(),
              output.pathExtension.lowercased() == "srt" else {
            status = "请另存为 .srt 字幕文件。"
            outcome = .failed
            return
        }
        start(.export(input, output))
    }

    private func start(_ job: Job) {
        guard !isRunning else { return }
        self.job = job
        generation = UUID()
        lastJapanese = ""
        lastChinese = ""
        outcome = nil
        exportedFile = nil
        status = "检查日译中语言包…"
        isRunning = true
        if case .export = job { isCaptioning = false } else { isCaptioning = true }
        nextConfiguration.invalidate()
        configuration = nextConfiguration
    }

    func stop() {
        work?.cancel()
        cleanup()
        status = "已停止"
    }

    private func cleanup() {
        generation = UUID()
        work = nil
        hideTask?.cancel()
        hideTask = nil
        audio?.stop()
        audio = nil
        floating.hide()
        if let iinaSession { try? bridge.publish(session: iinaSession, cues: [], showJapanese: false) }
        iinaSession = nil
        iinaCues = []
        job = nil
        configuration = nil
        progress = nil
        isCaptioning = false
        isRunning = false
    }

    func connectTranslation(_ session: TranslationSession) async {
        guard let job, work == nil else { return }
        let token = generation
        let task = Task {
            do {
                let availability = await LanguageAvailability().status(from: Self.japanese, to: Self.chinese)
                try Task.checkCancellation()
                if availability == .unsupported { throw ToolError("当前系统不支持日语到简体中文。") }
                if availability != .installed {
                    status = "请按系统提示安装日语和简体中文语言包。"
                    try await session.prepareTranslation()
                }
                try Task.checkCancellation()

                switch job {
                case let .live(player):
                    try await live(player, translatingWith: session)
                case .iina:
                    try await iina(translatingWith: session)
                case let .export(input, output):
                    try await export(input: input, output: output, translatingWith: session)
                case .sample:
                    let result = try await translate(
                        [Caption(start: 0, end: 1, text: "くそっ、何やってんだよ！")], with: session
                    )
                    if let cue = result.first { record(japanese: cue.japanese, chinese: cue.chinese) }
                    status = "翻译测试通过"
                    outcome = .succeeded
                }
            } catch is CancellationError {
                // User cancellation is reflected in stop().
            } catch {
                if token == generation {
                    status = error.localizedDescription
                    outcome = .failed
                }
            }
            if token == generation { cleanup() }
        }
        work = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func live(_ player: Player, translatingWith session: TranslationSession) async throws {
        status = "准备日语转写模型…"
        let recognizer = try await Recognizer.prepare()
        try Task.checkCancellation()
        status = "正在连接 \(player.title)。首次使用请留意系统音频录制授权提示。"
        let audio = try await ProcessAudio.open(pid: player.id)
        try Task.checkCancellation()
        self.audio = audio
        status = "正在捕获 \(player.title) · \(recognizer.name)"
        for await chunk in audio.chunks {
            try Task.checkCancellation()
            guard chunk.finishedAt.duration(to: .now) < .seconds(7) else { continue }
            let cues = try await recognizer.transcribe(chunk)
            let translated = try await translate(cues, with: session)
            guard !translated.isEmpty else { continue }
            let source = translated.map(\.japanese).joined(separator: "\n")
            let target = translated.map(\.chinese).joined(separator: "\n")
            record(japanese: source, chinese: target)
            floating.show(chinese: target, japanese: source)
            hideTask?.cancel()
            hideTask = Task {
                let duration = min(8, max(3, Double(target.count) / 7))
                guard (try? await Task.sleep(for: .seconds(duration))) != nil else { return }
                floating.hide()
            }
        }
    }

    private func iina(translatingWith session: TranslationSession) async throws {
        status = "请在 IINA 的插件菜单中选择「同步翻译此窗口」。"
        while !Task.isCancelled {
            guard let state = bridge.state() else {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            iinaSession = state.session
            answeredIINASession = state.session
            iinaCues = []
            // An empty snapshot tells the plugin that VideoTran picked up this window.
            try? bridge.publish(session: state.session, cues: [], showJapanese: showJapanese)
            status = "正在读取 IINA 中的视频…"
            try await translateIINAFile(state, with: session)
            if iinaSession == state.session {
                try? bridge.publish(session: state.session, cues: [], showJapanese: false)
                iinaSession = nil
            }
            status = "等待 IINA 中选中的本地视频…"
        }
    }

    private func translateIINAFile(_ initial: IINAState, with session: TranslationSession) async throws {
        let media = try await MediaFile.open(URL(fileURLWithPath: initial.path), selectedAudio: initial.audioStream)
        let written = try await media.japaneseSubtitles()
        let recognizer = written.isEmpty ? try await Recognizer.prepare() : nil
        try Task.checkCancellation()
        status = written.isEmpty ? "正在预读 IINA 视频 · \(recognizer?.name ?? "")" : "正在翻译 IINA 的日文字幕轨"
        var translated: [Int: [TranslatedCaption]] = [:]
        let heartbeat = Task {
            while iinaSession == initial.session, bridge.state()?.session == initial.session {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                guard iinaSession == initial.session, bridge.state()?.session == initial.session else { return }
                try? bridge.publish(session: initial.session, cues: iinaCues, showJapanese: showJapanese)
            }
        }
        defer { heartbeat.cancel() }

        while let state = bridge.state(), state.session == initial.session, state.path == initial.path {
            try Task.checkCancellation()
            let blocks = Prefetch.blocks(at: state.position, duration: media.duration, blockSize: MediaFile.blockSize)
            let previous = blocks.first.flatMap { $0 > 0 ? $0 - 1 : nil }
            let near = previous.map { [$0] + blocks } ?? blocks
            let currentCues = near.flatMap { translated[$0] ?? [] }
            if currentCues != iinaCues {
                iinaCues = currentCues
                try bridge.publish(session: state.session, cues: iinaCues, showJapanese: showJapanese)
            }

            let priority = Array(blocks.prefix(1)) + (previous.map { [$0] } ?? []) + blocks.dropFirst()
            if let missing = priority.first(where: { translated[$0] == nil }) {
                let source = try await sourceCues(for: missing, media: media, written: written, recognizer: recognizer)
                translated[missing] = try await translate(source, with: session)
                continue
            }
            if let cue = near.lazy.flatMap({ translated[$0] ?? [] })
                .first(where: { $0.start <= state.position && state.position < $0.end }),
               cue.chinese != lastChinese {
                record(japanese: cue.japanese, chinese: cue.chinese)
            }
            try await Task.sleep(for: .milliseconds(180))
        }
    }

    private func export(input: URL, output: URL, translatingWith session: TranslationSession) async throws {
        status = "读取视频…"
        let media = try await MediaFile.open(input)
        let written = try await media.japaneseSubtitles()
        let recognizer = written.isEmpty ? try await Recognizer.prepare() : nil
        let total = Int(ceil(media.duration / MediaFile.blockSize))
        var all: [TranslatedCaption] = []
        for block in 0..<total {
            try Task.checkCancellation()
            status = "生成字幕 \(block + 1) / \(total)…"
            progress = Double(block) / Double(total)
            let source = try await sourceCues(for: block, media: media, written: written, recognizer: recognizer)
            all += try await translate(source, with: session)
        }
        progress = 1
        try Task.checkCancellation()
        guard !all.isEmpty else { throw ToolError("没有识别到可导出的日语对白。") }
        try SRT.render(all.map(\.subtitle)).write(to: output, atomically: true, encoding: .utf8)
        status = "已导出 \(all.count) 条字幕 · \(output.lastPathComponent)"
        outcome = .succeeded
        exportedFile = output
    }

    private func sourceCues(for block: Int, media: MediaFile, written: [Caption],
                            recognizer: Recognizer?) async throws -> [Caption] {
        if let recognizer { return try await media.transcribe(block: block, with: recognizer) }
        let start = Double(block) * MediaFile.blockSize
        let end = start + MediaFile.blockSize
        return written.filter { start <= $0.start && $0.start < end }
    }

    private func translate(_ cues: [Caption], with session: TranslationSession) async throws -> [TranslatedCaption] {
        guard !cues.isEmpty else { return [] }
        try Task.checkCancellation()
        let requests = cues.enumerated().map { index, cue in
            TranslationSession.Request(sourceText: cue.text, clientIdentifier: String(index))
        }
        let responses = try await session.translations(from: requests)
        try Task.checkCancellation()
        return responses.compactMap { response in
            guard let identifier = response.clientIdentifier, let index = Int(identifier),
                  cues.indices.contains(index) else { return nil }
            let cue = cues[index]
            return .init(start: cue.start, end: cue.end, japanese: cue.text, chinese: response.targetText)
        }.sorted { $0.start < $1.start }
    }

    private func record(japanese: String, chinese: String) {
        lastJapanese = japanese
        lastChinese = chinese
    }

    /// App icons sized for the player menu.
    private static func menuIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon = icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
