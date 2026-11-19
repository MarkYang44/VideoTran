import AVFoundation
import Darwin
import Foundation
import Speech
import SubtitleCore

struct ToolError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum LocalTools {
    static func executable(_ name: String, override: String? = nil) -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let candidates = (override.map { [$0] } ?? []) +
            (standard + environmentPath.split(separator: ":").map(String.init))
                .filter { $0.hasPrefix("/") }.map { "\($0)/\(name)" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoTran-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let child = CancellableProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let directory = try tempDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let outputURL = directory.appendingPathComponent("stdout")
                let errorsURL = directory.appendingPathComponent("stderr")
                try Data().write(to: outputURL)
                try Data().write(to: errorsURL)
                let output = try FileHandle(forWritingTo: outputURL)
                let errors = try FileHandle(forWritingTo: errorsURL)
                defer {
                    try? output.close()
                    try? errors.close()
                }

                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                try child.start(process)
                process.waitUntilExit()
                if child.isCancelled { throw CancellationError() }
                guard process.terminationStatus == 0 else {
                    let stderr = (try? Data(contentsOf: errorsURL)) ?? Data()
                    let detail = String(decoding: stderr.suffix(700), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ToolError("\(executable.lastPathComponent) 退出码 \(process.terminationStatus)\n\(detail)")
                }
                return try Data(contentsOf: outputURL)
            }.value
        } onCancel: {
            child.cancel()
        }
    }
}

private final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func start(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}

struct Recognizer {
    enum Backend { case whisper(URL, URL), system(Locale) }
    let backend: Backend

    var name: String {
        switch backend {
        case .whisper: "Whisper"
        case .system: "Apple Speech"
        }
    }

    static func prepare() async throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VideoTran")
        let modelNames = ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin"]
        let legacyDirectory = directory.deletingLastPathComponent().appendingPathComponent("VideoSubtitle")
        let models = env["VIDEO_SUBTITLE_MODEL"].map { [URL(fileURLWithPath: $0)] } ??
            [directory, legacyDirectory].flatMap { folder in
                modelNames.map { folder.appendingPathComponent($0) }
            }

        if let model = models.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }),
           let cli = LocalTools.executable("whisper-cli", override: env["VIDEO_SUBTITLE_WHISPER"]) {
            return Self(backend: .whisper(cli, model))
        }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) {
            let module = systemModule(locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            return Self(backend: .system(locale))
        }
        throw ToolError("请安装 whisper-cli 和日语多语模型。设置方法见 README。")
    }

    func transcribe(_ url: URL) async throws -> [Caption] {
        switch backend {
        case let .whisper(cli, model):
            let directory = try LocalTools.tempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let base = directory.appendingPathComponent("transcript")
            let srt = base.appendingPathExtension("srt")
            _ = try await LocalTools.run(cli, [
                "-m", model.path, "-l", "ja", "-bs", "5", "-osrt", "-of", base.path, "-f", url.path
            ])
            if !FileManager.default.fileExists(atPath: srt.path) { return [] }
            return SRT.parse(try String(contentsOf: srt, encoding: .utf8))
        case let .system(locale):
            if #available(macOS 26, *) { return try await transcribeWithSystem(url, locale: locale) }
            throw ToolError("Apple Speech 需要 macOS 26。")
        }
    }

    func transcribe(_ chunk: ProcessAudio.Chunk) async throws -> [Caption] {
        let directory = try LocalTools.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("capture.wav")
        try write(chunk, to: original)
        if case .whisper = backend {
            guard let ffmpeg = LocalTools.executable("ffmpeg") else { throw ToolError("Whisper 实时模式需要 FFmpeg。") }
            let mono = directory.appendingPathComponent("capture16k.wav")
            _ = try await LocalTools.run(ffmpeg, ["-nostdin", "-v", "error", "-i", original.path,
                                                  "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", mono.path])
            return try await transcribe(mono)
        }
        return try await transcribe(original)
    }

    private func write(_ chunk: ProcessAudio.Chunk, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: chunk.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let destination = buffer.floatChannelData?.pointee else {
            throw ToolError("无法创建音频缓冲区。")
        }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in
            if let source = samples.baseAddress { destination.update(from: source, count: samples.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    @available(macOS 26, *)
    private static func systemModule(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    @available(macOS 26, *)
    private static func sentences(in result: SpeechTranscriber.Result) -> [Caption] {
        let sentenceEnd = "。！？!?"
        var captions: [Caption] = []
        var text = ""
        var start: Double?
        var end: Double?

        func finish() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = max(0, start ?? result.range.start.seconds)
            let last = end ?? result.range.end.seconds
            if !trimmed.isEmpty, first.isFinite, last.isFinite, last > first {
                captions.append(Caption(start: first, end: last, text: trimmed))
            }
            text = ""
            start = nil
            end = nil
        }

        for run in result.text.runs {
            text += String(result.text[run.range].characters)
            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                start = start ?? range.start.seconds
                end = range.end.seconds
            }
            if let last = text.last(where: { !$0.isWhitespace }), sentenceEnd.contains(last), end != nil {
                finish()
            }
        }
        finish()
        return captions
    }

    @available(macOS 26, *)
    private func transcribeWithSystem(_ url: URL, locale: Locale) async throws -> [Caption] {
        let module = Self.systemModule(locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        let reader = Task {
            var captions: [Caption] = []
            for try await result in module.results {
                if result.isFinal {
                    captions += Self.sentences(in: result)
                }
            }
            return captions
        }
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                return try await reader.value
            } catch {
                reader.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
