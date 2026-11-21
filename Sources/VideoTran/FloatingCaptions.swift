import AppKit
import SwiftUI

@MainActor final class FloatingCaptions {
    /// Applies to the caption on screen right away, not only to the next one.
    var showsJapanese = true {
        didSet { if isVisible { layout() } }
    }

    private let panel: NSPanel
    private let content = NSHostingView(rootView: CaptionBubble(chinese: "", japanese: nil, width: 0))
    private var chinese = ""
    private var japanese = ""
    private var isVisible = false

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        if #available(macOS 26, *) {
            panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .ignoresCycle]
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        panel.contentView = content
    }

    /// Captions appear and change instantly. They arrive many times a minute and are read
    /// against the dialogue, so an entrance animation would only delay them.
    func show(chinese: String, japanese: String) {
        self.chinese = chinese
        self.japanese = japanese
        isVisible = true
        layout()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1 // Replaces a fade-out that is still running.
        }
        panel.orderFrontRegardless()
    }

    /// A short ease-out fade lets an expired caption leave without a hard cut.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func layout() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return }
        let frame = screen.visibleFrame
        let width = min(frame.width * 0.9, 940)
        content.rootView = CaptionBubble(chinese: chinese, japanese: showsJapanese && !japanese.isEmpty ? japanese : nil,
                                         width: width)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 60,
                              width: width, height: max(content.fittingSize.height, 45)), display: true)
    }
}

private struct CaptionBubble: View {
    let chinese: String
    let japanese: String?
    let width: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text(chinese).font(.system(size: 27, weight: .semibold))
            if let japanese {
                Text(japanese).font(.system(size: 17)).foregroundStyle(.white.opacity(0.88))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: width)
    }
}
