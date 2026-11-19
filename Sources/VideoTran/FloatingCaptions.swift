import AppKit
import SwiftUI

@MainActor final class FloatingCaptions {
    private let panel: NSPanel

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
    }

    func show(chinese: String, japanese: String?) {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return }
        let width = min(screen.visibleFrame.width * 0.9, 940)
        let content = NSHostingView(rootView: VStack(spacing: 6) {
            Text(chinese).font(.system(size: 27, weight: .semibold))
            if let japanese, !japanese.isEmpty {
                Text(japanese).font(.system(size: 17)).foregroundStyle(.white.opacity(0.88))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .frame(width: width))
        panel.contentView = content
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 60,
                              width: width, height: max(content.fittingSize.height, 45)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
