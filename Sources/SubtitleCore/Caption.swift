import Foundation

public struct Caption: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public static func text(at time: Double, in cues: [Caption]) -> String {
        cues.lazy.filter { $0.start <= time && time < $0.end }
            .map(\.text).joined(separator: "\n")
    }
}

public enum SRT {
    public static func parse(_ input: String) -> [Caption] {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let timing = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let fields = lines[timing].components(separatedBy: " --> ")
            guard fields.count == 2, let start = seconds(fields[0]), let end = seconds(fields[1]),
                  end > start else { return nil }
            let text = lines.dropFirst(timing + 1).joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : Caption(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }

    public static func render(_ cues: [Caption]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func seconds(_ string: String) -> Double? {
        let fields = string.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).first?.split(separator: ":")
        guard let fields, fields.count == 3,
              let hour = Int(fields[0]), hour >= 0, hour < 10_000,
              let minute = Int(fields[1]), (0..<60).contains(minute),
              let second = Double(fields[2].replacingOccurrences(of: ",", with: ".")),
              (0..<60).contains(second) else { return nil }
        return Double(hour * 3600 + minute * 60) + second
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int64((max(0, seconds) * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld",
                      milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

public enum Prefetch {
    public static func blocks(at time: Double, duration: Double, blockSize: Double) -> [Int] {
        guard time >= 0, time < duration, duration.isFinite, blockSize > 0 else { return [] }
        let first = Int(time / blockSize)
        return (first..<(first + 3)).filter { Double($0) * blockSize < duration }
    }
}

public struct IINAState: Codable, Sendable {
    public let session: String
    public let path: String
    public let position: Double
    public let duration: Double
    public let paused: Bool
    public let updated: Double
    public let audioStream: Int?

    public init(session: String, path: String, position: Double, duration: Double,
                paused: Bool, updated: Double, audioStream: Int?) {
        self.session = session
        self.path = path
        self.position = position
        self.duration = duration
        self.paused = paused
        self.updated = updated
        self.audioStream = audioStream
    }

    public func isUsable(now: Double) -> Bool {
        !session.isEmpty && path.hasPrefix("/") && position.isFinite && position >= 0
            && duration.isFinite && duration > 0 && position <= duration + 1
            && now - updated >= -1 && now - updated < 3
    }
}
