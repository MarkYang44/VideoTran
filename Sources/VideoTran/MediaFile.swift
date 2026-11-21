import Foundation
import SubtitleCore

struct MediaFile {
    private struct Metadata: Decodable {
        struct Stream: Decodable {
            let index: Int
            let codec_name: String?
            let codec_type: String
            let tags: [String: String]?
            var isJapanese: Bool {
                let code = tags?["language"]?.lowercased() ?? ""
                return ["jpn", "ja", "ja-jp"].contains(code)
            }
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]
        let format: Format
    }

    let url: URL
    let duration: Double
    private let ffmpeg: URL
    private let audio: Int?
    private let subtitle: Int?

    static let blockSize: Double = 16
    static let extensions = ["mp4", "mkv", "mov", "m4v", "webm"]

    static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    static func open(_ url: URL, selectedAudio: Int? = nil) async throws -> Self {
        guard let ffmpeg = LocalTools.executable("ffmpeg"), let ffprobe = LocalTools.executable("ffprobe") else {
            throw ToolError("读取本地视频需要 FFmpeg 和 ffprobe。")
        }
        guard isSupported(url), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError("请选择本地 MP4、MKV、MOV、M4V 或 WebM 文件。")
        }
        let data = try await LocalTools.run(ffprobe, [
            "-v", "error", "-protocol_whitelist", "file,pipe", "-show_format", "-show_streams", "-of", "json", "-i", url.path
        ])
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard let duration = metadata.format.duration.flatMap(Double.init),
              duration.isFinite, duration > 0, duration < 36_000_000 else {
            throw ToolError("无法读取视频时长。")
        }
        let audioTracks = metadata.streams.filter { $0.codec_type == "audio" }
        let selected = audioTracks.first { $0.index == selectedAudio }
        let audio = (selected.flatMap { $0.isJapanese ? $0 : nil }
                     ?? audioTracks.first(where: \.isJapanese) ?? selected ?? audioTracks.first)?.index
        let textCodecs = ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"]
        let subtitle = metadata.streams.first {
            $0.isJapanese && $0.codec_type == "subtitle" && textCodecs.contains($0.codec_name ?? "")
        }?.index

        return Self(url: url, duration: duration, ffmpeg: ffmpeg, audio: audio, subtitle: subtitle)
    }

    func japaneseSubtitles() async throws -> [Caption] {
        let sidecars = ["ja", "jpn", "ja-JP"].map { language in
            url.deletingPathExtension().appendingPathExtension("\(language).srt")
        }
        for sidecar in sidecars where FileManager.default.isReadableFile(atPath: sidecar.path) {
            let cues = SRT.parse(try String(contentsOf: sidecar, encoding: .utf8))
            if !cues.isEmpty { return cues }
        }
        guard let subtitle else { return [] }
        let data = try await LocalTools.run(ffmpeg, [
            "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", url.path,
            "-map", "0:\(subtitle)", "-c:s", "srt", "-f", "srt", "pipe:1"
        ])
        return SRT.parse(String(decoding: data, as: UTF8.self))
    }

    func transcribe(block: Int, with recognizer: Recognizer) async throws -> [Caption] {
        guard let audio else { throw ToolError("此文件没有可用音轨或日文文本字幕。") }
        let start = Double(block) * Self.blockSize
        let end = min(start + Self.blockSize, duration)
        let extractStart = max(0, start - 1.5)
        let extractEnd = min(duration, end + 1.5)

        let directory = try LocalTools.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wave = directory.appendingPathComponent("audio.wav")
        _ = try await LocalTools.run(ffmpeg, [
            "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
            "-ss", String(extractStart), "-i", url.path, "-t", String(extractEnd - extractStart),
            "-map", "0:\(audio)", "-af", "aresample=16000:async=1:first_pts=0",
            "-ac", "1", "-c:a", "pcm_s16le", wave.path
        ])
        return try await recognizer.transcribe(wave).compactMap { cue in
            let absoluteStart = max(0, cue.start + extractStart)
            let absoluteEnd = min(duration, cue.end + extractStart)
            let midpoint = (absoluteStart + absoluteEnd) / 2
            guard midpoint >= start, midpoint < end, absoluteEnd > absoluteStart else { return nil }
            return Caption(start: absoluteStart, end: absoluteEnd, text: cue.text)
        }
    }
}
