import CoreAudio
import Foundation
import SubtitleCore

struct CaptureError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// The startup worker owns the tap until open returns. The controller then
// owns teardown. The I/O block only shares its separately confined processor.
final class ProcessAudio: @unchecked Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let finishedAt: ContinuousClock.Instant
    }

    let chunks: AsyncStream<Chunk>
    private let continuation: AsyncStream<Chunk>.Continuation
    private let queue = DispatchQueue(label: "video-subtitle.tap", qos: .userInitiated)
    private var tap = kAudioObjectUnknown
    private var device = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?

    static func open(pid: pid_t) async throws -> ProcessAudio {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try ProcessAudio(pid: pid) })
            }
        }
    }

    private init(pid: pid_t) throws {
        (chunks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
        do {
            try start(pid: pid)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(pid: pid_t) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var process = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try require(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size),
                                               &pid, &size, &process), "查询播放器音频进程")
        guard process != kAudioObjectUnknown else {
            throw CaptureError("请先让选中的播放器播放声音，再重试。")
        }

        let description = CATapDescription(monoMixdownOfProcesses: [process])
        description.name = "VideoTran"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try require(AudioHardwareCreateProcessTap(description, &tap), "创建音频捕获")

        var format = AudioStreamBasicDescription()
        address = property(kAudioTapPropertyFormat)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try require(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "读取音频格式")
        let sampleRate = format.mSampleRate
        guard (8_000...384_000).contains(sampleRate), format.mChannelsPerFrame == 1,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureError("目前支持单声道 Float32 音频捕获。")
        }

        var tapUID: CFString?
        address = property(kAudioTapPropertyUID)
        size = UInt32(MemoryLayout<CFString?>.size)
        try require(withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
        }, "读取音频捕获标识")
        guard let tapUID else { throw CaptureError("系统没有返回音频捕获标识。") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VideoTran",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try require(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "创建音频输入")
        let processor = CaptureProcessor(sampleRate: sampleRate, continuation: continuation)

        try require(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels == 1 else { return }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            processor.accept(samples)
        }, "注册音频回调")
        try require(AudioDeviceStart(device, ioProc), "启动捕获（检查系统音频录制权限）")
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
        continuation.finish()
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func require(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CaptureError("\(action)失败（\(status)）。") }
    }
}

private final class CaptureProcessor: @unchecked Sendable {
    // Core Audio invokes this processor serially on the dedicated capture queue.
    private let sampleRate: Double
    private let continuation: AsyncStream<ProcessAudio.Chunk>.Continuation
    private var chunker: PCMChunker

    init(sampleRate: Double, continuation: AsyncStream<ProcessAudio.Chunk>.Continuation) {
        self.sampleRate = sampleRate
        self.continuation = continuation
        chunker = PCMChunker(sampleRate: Int(sampleRate.rounded()))
    }

    func accept(_ samples: UnsafeBufferPointer<Float>) {
        for samples in chunker.push(samples) {
            continuation.yield(.init(samples: samples, sampleRate: sampleRate, finishedAt: .now))
        }
    }
}
