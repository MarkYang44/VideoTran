import Foundation
import SubtitleCore

@main struct SubtitleCoreTests {
    static func testParsesMultilineSubtitlesAndSelectsByMediaTime() {
        let cues = SRT.parse("\u{feff}1\r\n00:00:01,125 --> 00:00:02,500\r\nこんにちは\r\nまたね\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nおはよう")
        equal(cues.count, 2)
        equal(cues.first?.text, "こんにちは\nまたね")
        equal(SRT.parse(SRT.render(cues)), cues)
        equal(Caption.text(at: 2.499, in: cues), "こんにちは\nまたね")
        equal(Caption.text(at: 2.500, in: cues), "")
        equal(Caption.text(at: 3.0, in: cues), "おはよう")
    }

    static func testOverlappingCaptionsRemainVisible() {
        let cues = [Caption(start: 1, end: 9, text: "先"), Caption(start: 3, end: 4, text: "后")]
        equal(Caption.text(at: 3.5, in: cues), "先\n后")
        equal(Caption.text(at: 6, in: cues), "先")
    }

    static func testSegmentsAfterPauseAndForcesCutDuringContinuousSpeech() {
        var segmenter = PCMChunker(sampleRate: 10)
        check(segmenter.push(Array(repeating: 0, count: 50)).isEmpty)
        check(segmenter.push(Array(repeating: 1, count: 12)).isEmpty)
        let complete = segmenter.push(Array(repeating: 0, count: 10))
        equal(complete.count, 1)
        equal(complete.first?.count, 16)
        let continuous = segmenter.push(Array(repeating: 1, count: 61))
        equal(continuous.first?.count, 60)
    }

    static func testPrefetchPrioritizesTheCurrentPositionAfterASeek() {
        equal(Prefetch.blocks(at: 34, duration: 100, blockSize: 12), [2, 3, 4])
        equal(Prefetch.blocks(at: 3, duration: 100, blockSize: 12), [0, 1, 2])
        equal(Prefetch.blocks(at: 98, duration: 100, blockSize: 12), [8])
        check(Prefetch.blocks(at: 100, duration: 100, blockSize: 12).isEmpty)
    }

    static func testIinaStateExpiresAndRejectsNetworkPaths() throws {
        let state = IINAState(session: "abc", path: "/tmp/local video.mkv", position: 7,
                              duration: 10, paused: true, updated: 100, audioStream: nil)
        check(state.isUsable(now: 101))
        check(!state.isUsable(now: 105))
        let remote = IINAState(session: "abc", path: "https://example.org/video.mkv", position: 7,
                               duration: 10, paused: true, updated: 100, audioStream: nil)
        check(!remote.isUsable(now: 101))
    }
    static func main() throws {
        testParsesMultilineSubtitlesAndSelectsByMediaTime()
        testOverlappingCaptionsRemainVisible()
        testSegmentsAfterPauseAndForcesCutDuringContinuousSpeech()
        testPrefetchPrioritizesTheCurrentPositionAfterASeek()
        try testIinaStateExpiresAndRejectsNetworkPaths()
        print("5 core tests passed")
    }

    static func check(_ result: Bool, line: UInt = #line) {
        precondition(result, "Assertion failed on line \(line)")
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
        precondition(actual == expected, "Line \(line): got \(actual), expected \(expected)")
    }
}
