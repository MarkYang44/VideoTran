import Foundation

/// Accepts mono normalized samples. Short acoustic pauses end a chunk.
/// The hard limit bounds inference latency during continuous speech.
public struct PCMChunker {
    private let minimum: Int
    private let maximum: Int
    private let pause: Int
    private var samples: [Float] = []
    private var trailingSilence = 0

    public init(sampleRate: Int) {
        minimum = sampleRate
        maximum = sampleRate * 6
        pause = max(1, Int(Double(sampleRate) * 0.45))
        samples.reserveCapacity(maximum)
    }

    public mutating func push(_ input: [Float]) -> [[Float]] {
        push(input[...])
    }

    public mutating func push(_ input: some Collection<Float>) -> [[Float]] {
        guard !input.isEmpty else { return [] }
        let peak = input.reduce(Float.zero) { max($0, abs($1)) }
        let quiet = peak < 0.002
        if quiet && samples.isEmpty { return [] }

        var ready: [[Float]] = []
        for value in input {
            if quiet && samples.isEmpty { break }
            samples.append(value)
            trailingSilence = quiet ? trailingSilence + 1 : 0
            if samples.count == maximum || (samples.count >= minimum && trailingSilence >= pause) {
                ready.append(samples)
                samples = []
                samples.reserveCapacity(maximum)
                trailingSilence = 0
            }
        }
        return ready
    }
}
