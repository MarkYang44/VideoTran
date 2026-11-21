import AppKit
import Speech
import SwiftUI
import Translation
import SubtitleCore

@main struct EntryPoint {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        switch arguments.dropFirst().first {
        case "--probe-media" where arguments.count == 3:
            cli {
                let file = try await MediaFile.open(URL(fileURLWithPath: arguments[2]))
                let cues = try await file.japaneseSubtitles()
                print("duration=\(file.duration) subtitleCues=\(cues.count)")
                print(SRT.render(cues))
            }
        case "--probe-models":
            cli {
                let availability = await LanguageAvailability().status(
                    from: CaptionController.japanese, to: CaptionController.chinese
                )
                print("Japanese → Simplified Chinese: \(availability)")
                if #available(macOS 26, *) {
                    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP"))
                    let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
                    print("Japanese SpeechTranscriber: \(locale?.identifier ?? "unsupported"), installed: \(installed)")
                }
            }
        case "--probe-block" where arguments.count == 4:
            cli {
                guard let block = Int(arguments[3]), (0..<2_250_000).contains(block) else {
                    throw ToolError("Expected a valid nonnegative media block.")
                }
                let file = try await MediaFile.open(URL(fileURLWithPath: arguments[2]))
                guard Double(block) * MediaFile.blockSize < file.duration else {
                    throw ToolError("The media block starts after the end of the file.")
                }
                let recognizer = try await Recognizer.prepare()
                let cues = try await file.transcribe(block: block, with: recognizer)
                print(SRT.render(cues))
                guard !cues.isEmpty else { throw ToolError("No speech recognized.") }
            }
        case "--probe-speech" where arguments.count == 3:
            cli {
                let recognizer = try await Recognizer.prepare()
                print("backend=\(recognizer.name)")
                let cues = try await recognizer.transcribe(URL(fileURLWithPath: arguments[2]))
                print(SRT.render(cues))
                guard !cues.isEmpty else { throw ToolError("No speech recognized.") }
            }
        default:
            SubtitleApp.main()
        }
    }

    @MainActor private static func cli(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

private struct SubtitleApp: App {
    @StateObject private var controller = CaptionController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("VideoTran", id: "control") {
            ControlView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("VideoTran", systemImage: controller.isRunning ? "captions.bubble.fill" : "captions.bubble") {
            Button("打开字幕控制台") {
                openWindow(id: "control")
                NSApp.activate()
            }
            Button("停止翻译") { controller.stop() }.disabled(!controller.isRunning)
            Divider()
            Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

private extension Animation {
    /// Strong ease-out: responsive at the start, gentle at the end.
    static func easeOutQuint(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

private struct ControlView: View {
    @ObservedObject var controller: CaptionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VideoTran").font(.title2.weight(.semibold))
                    Text("日语 → 简体中文").foregroundStyle(.secondary)
                }
            }

            GroupBox("实时悬浮字幕") {
                HStack {
                    Picker("播放器", selection: $controller.selectedPlayer) {
                        if controller.players.isEmpty { Text("没有运行的播放器").tag(pid_t(0)) }
                        playerRows(controller.players.filter(\.isMediaPlayer))
                        if controller.players.contains(where: \.isMediaPlayer),
                           controller.players.contains(where: { !$0.isMediaPlayer }) {
                            Divider()
                        }
                        playerRows(controller.players.filter { !$0.isMediaPlayer })
                    }
                    Button("开始") { controller.startLive() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.selectedPlayer == 0)
                }
                .padding(.vertical, 3)
                .disabled(controller.isRunning)
            }

            GroupBox("本地视频") {
                HStack {
                    Button("IINA 同步") { controller.startIINA() }
                        .help("在 IINA 中选择「插件 → 同步翻译此窗口」后，VideoTran 会自动开始同步")
                    Button("导出 SRT…") { controller.exportSubtitles() }
                    Spacer()
                    Text("或将视频拖到这里").font(.callout)
                        .foregroundStyle(controller.isRunning ? HierarchicalShapeStyle.tertiary : .secondary)
                }
                .padding(.vertical, 3)
                .disabled(controller.isRunning)
            }

            HStack {
                Toggle("显示日文原文", isOn: $controller.showJapanese)
                Spacer()
                Button("测试翻译") { controller.testTranslation() }
                    .disabled(controller.isRunning)
            }
            Divider()
            statusRow
            if controller.isCaptioning || !controller.lastChinese.isEmpty {
                GroupBox {
                    ZStack(alignment: .topLeading) {
                        // Reserves one Chinese and two Japanese lines, enough for most captions,
                        // so the window keeps its height while they change.
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: "中").font(.body.weight(.medium))
                            if controller.showJapanese { Text(verbatim: "日").lineLimit(2, reservesSpace: true) }
                        }
                        .hidden()
                        VStack(alignment: .leading, spacing: 5) {
                            if controller.lastChinese.isEmpty {
                                Text("译文会显示在这里").foregroundStyle(.tertiary)
                            } else {
                                Text(controller.lastChinese).font(.body.weight(.medium)).textSelection(.enabled)
                            }
                            if controller.showJapanese {
                                Text(controller.lastJapanese).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true) // The window grows to fit instead of truncating.
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .overlay {
            if controller.isDropTargeted { DropHint().transition(.opacity) }
        }
        // Enter quickly, leave a little faster.
        .animation(.easeOutQuint(controller.isDropTargeted ? 0.18 : 0.12), value: controller.isDropTargeted)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            controller.exportDropped(urls)
        } isTargeted: { targeted in
            controller.isDropTargeted = targeted && !controller.isRunning
        }
        .translationTask(controller.configuration) { session in
            await controller.connectTranslation(session)
        }
        .task {
            // Picks up 同步翻译此窗口 from IINA without a second click here.
            while !Task.isCancelled {
                controller.answerIINARequest()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { if controller.isRunning { controller.stop() } }
    }

    private func playerRows(_ players: [CaptionController.Player]) -> some View {
        ForEach(players) { player in
            Label {
                Text(verbatim: player.title)
            } icon: {
                if let icon = player.icon { Image(nsImage: icon) }
            }
            .tag(player.id)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                        // A spinner has no baseline; center it on the first line of text instead.
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                } else if let outcome = controller.outcome {
                    Image(systemName: outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(outcome == .succeeded ? .green : .orange)
                        .accessibilityLabel(outcome == .succeeded ? "完成" : "出错")
                }
                Text(controller.status).font(.callout).lineLimit(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(controller.status)
                Spacer(minLength: 12)
                if controller.isRunning {
                    Button("停止") { controller.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else if controller.exportedFile != nil {
                    Button("在 Finder 中显示") { controller.revealExportedFile() }
                }
            }
            if let progress = controller.progress {
                ProgressView(value: progress)
            }
        }
    }
}

private struct DropHint: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Label("松开即可导出简体中文字幕", systemImage: "captions.bubble")
            .font(.title3.weight(.medium))
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.tint, lineWidth: 2))
            .padding(8)
    }
}
