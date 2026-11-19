import AppKit
import SwiftUI
import Translation
import SubtitleCore

@MainActor final class CaptionController: ObservableObject {
    struct Player: Identifiable {
        let id: pid_t
        let name: String
    }

    private enum Job {
        case live(Player)
        case iina
        case export(URL, URL)
        case sample
    }

    static let japanese = Locale.Language(identifier: "ja")
    static let chinese = Locale.Language(identifier: "zh-Hans")

    @Published private(set) var players: [Player] = []
    @Published var selectedPlayer: pid_t = 0
    @Published var showJapanese = true
    @Published private(set) var status = "选择播放器后开始实时翻译。"
    @Published private(set) var lastJapanese = ""
    @Published private(set) var lastChinese = ""
    @Published private(set) var isRunning = false
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

    init() { refreshPlayers() }

    func refreshPlayers() {
        players = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let name = app.localizedName else { return nil }
            return Player(id: app.processIdentifier, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if !players.contains(where: { $0.id == selectedPlayer }) {
            selectedPlayer = players.first(where: { ["IINA", "VLC", "QuickTime Player"].contains($0.name) })?.id
                ?? players.first?.id ?? 0
        }
    }

    func startLive() {
        guard let player = players.first(where: { $0.id == selectedPlayer }) else { return }
        start(.live(player))
    }

    func playerDidExit(_ pid: pid_t) {
        if case let .live(player) = job, player.id == pid {
            stop()
            status = "\(player.name) 已退出。"
        }
        refreshPlayers()
    }

    func startIINA() { start(.iina) }
    func testTranslation() { start(.sample) }

    func exportSubtitles() {
        let open = NSOpenPanel()
        open.message = "选择要生成简体中文字幕的本地视频"
        open.canChooseDirectories = false
        guard open.runModal() == .OK, let input = open.url else { return }

        let save = NSSavePanel()
        save.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + ".zh-Hans.srt"
        guard save.runModal() == .OK, let output = save.url else { return }
        guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath(),
              output.pathExtension.lowercased() == "srt" else {
            status = "请另存为 .srt 字幕文件。"
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
        status = "检查日译中语言包…"
        isRunning = true
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
                    status = "翻译测试结束"
                }
            } catch is CancellationError {
                // User cancellation is reflected in stop().
            } catch {
                if token == generation { status = error.localizedDescription }
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
        status = "正在连接 \(player.name)（PID \(player.id)）。首次使用请查看系统音频授权提示。"
        let audio = try await ProcessAudio.open(pid: player.id)
        try Task.checkCancellation()
        self.audio = audio
        status = "正在捕获 \(player.name) · \(recognizer.name)"
        for await chunk in audio.chunks {
            try Task.checkCancellation()
            guard chunk.finishedAt.duration(to: .now) < .seconds(7) else { continue }
            let cues = try await recognizer.transcribe(chunk)
            let translated = try await translate(cues, with: session)
            guard !translated.isEmpty else { continue }
            let source = translated.map(\.japanese).joined(separator: "\n")
            let target = translated.map(\.chinese).joined(separator: "\n")
            record(japanese: source, chinese: target)
            floating.show(chinese: target, japanese: showJapanese ? source : nil)
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
            iinaCues = []
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
        let media = try await MediaFile.open(input)
        let written = try await media.japaneseSubtitles()
        let recognizer = written.isEmpty ? try await Recognizer.prepare() : nil
        let total = Int(ceil(media.duration / MediaFile.blockSize))
        var all: [TranslatedCaption] = []
        for block in 0..<total {
            try Task.checkCancellation()
            status = "生成字幕 \(block + 1) / \(total)…"
            let source = try await sourceCues(for: block, media: media, written: written, recognizer: recognizer)
            all += try await translate(source, with: session)
        }
        try Task.checkCancellation()
        guard !all.isEmpty else { throw ToolError("没有识别到可导出的日语对白。") }
        try SRT.render(all.map(\.subtitle)).write(to: output, atomically: true, encoding: .utf8)
        status = "已导出 \(all.count) 条字幕 · \(output.lastPathComponent)"
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
}
