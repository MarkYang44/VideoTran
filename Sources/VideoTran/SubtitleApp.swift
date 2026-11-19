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

        MenuBarExtra("VideoTran", systemImage: "captions.bubble") {
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
                        ForEach(controller.players) { player in
                            Text("\(player.name) · \(player.id)").tag(player.id)
                        }
                    }
                    Button { controller.refreshPlayers() } label: {
                        Image(systemName: "arrow.clockwise").accessibilityLabel("刷新播放器")
                    }
                    .help("刷新播放器")
                    Button("开始") { controller.startLive() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.selectedPlayer == 0)
                }
                .padding(.vertical, 3)
                .disabled(controller.isRunning)
            }

            HStack {
                Button("IINA 同步") { controller.startIINA() }
                Button("导出 SRT…") { controller.exportSubtitles() }
                Button("测试翻译") { controller.testTranslation() }
            }
            .disabled(controller.isRunning)

            Toggle("显示日文原文", isOn: $controller.showJapanese)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(controller.status).font(.callout).lineLimit(3)
                Spacer()
                if controller.isRunning { Button("停止") { controller.stop() } }
            }
            if !controller.lastChinese.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(controller.lastChinese).font(.body.weight(.medium)).textSelection(.enabled)
                        if controller.showJapanese {
                            Text(controller.lastJapanese).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(5)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .translationTask(controller.configuration) { session in
            await controller.connectTranslation(session)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { notification in
            if let player = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                controller.playerDidExit(player.processIdentifier)
            }
        }
        .onDisappear { if controller.isRunning { controller.stop() } }
    }
}
