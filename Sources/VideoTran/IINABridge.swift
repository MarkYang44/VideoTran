import Foundation
import SubtitleCore

struct TranslatedCaption: Codable, Equatable {
    let start: Double
    let end: Double
    let japanese: String
    let chinese: String

    var subtitle: Caption { Caption(start: start, end: end, text: chinese) }
}

struct IINABridge {
    struct Snapshot: Encodable {
        let session: String
        let updated: Double
        let cues: [TranslatedCaption]
        let showJapanese: Bool
    }

    let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("com.colliderli.iina/plugins/.data/local.videosubtitle.iina",
                                                   isDirectory: true)
    }

    func state() -> IINAState? {
        let url = directory.appendingPathComponent("player.json")
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let state = try? JSONDecoder().decode(IINAState.self, from: data),
              state.isUsable(now: Date().timeIntervalSince1970) else { return nil }
        return state
    }

    func publish(session: String, cues: [TranslatedCaption], showJapanese: Bool) throws {
        let snapshot = Snapshot(session: session, updated: Date().timeIntervalSince1970,
                                cues: cues, showJapanese: showJapanese)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("captions.json"), options: .atomic)
    }
}
