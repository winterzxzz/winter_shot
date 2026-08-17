import AppKit
import SwiftUI

/// The first step of the record flow: a floating pill at the bottom-center of
/// the screen under the pointer asking what to record — a dragged area, a
/// window, or the whole screen. Esc or the ✕ cancels.
///
/// Set WINTERSHOT_AUTORECORD=area|window|screen (optionally
/// WINTERSHOT_AUTORECORD_DELAY=<seconds>) to auto-choose — used by smoke tests.
@MainActor
final class RecordingTargetChooser {
    static let shared = RecordingTargetChooser()

    enum Choice: String {
        case area
        case window
        case screen
    }

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Choice?, Never>?
    private let escMonitor = EscapeCancelMonitor()
    private static let bottomInset: CGFloat = 24

    private init() {}

    /// Shows the pill and suspends until the user chooses or cancels.
    func choose() async -> Choice? {
        finish(nil) // A re-trigger while a chooser is up cancels the old one.
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first else {
            finish(.screen) // No screen to place UI on; just record.
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 10, height: 10)),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hosting = NSHostingView(rootView: RecordingTargetChooserView { [weak self] choice in
            self?.finish(choice)
        })
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.minY + Self.bottomInset))
        panel.orderFrontRegardless()
        self.panel = panel

        escMonitor.start { [weak self] in self?.finish(nil) }

        let env = ProcessInfo.processInfo.environment
        if let auto = env["WINTERSHOT_AUTORECORD"].flatMap(Choice.init(rawValue:)) {
            let delay = env["WINTERSHOT_AUTORECORD_DELAY"].flatMap(Double.init) ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish(auto)
            }
        }
    }

    private func finish(_ choice: Choice?) {
        guard let continuation else { return }
        self.continuation = nil
        escMonitor.stop()
        panel?.close()
        panel = nil
        continuation.resume(returning: choice)
    }
}

private struct RecordingTargetChooserView: View {
    let onChoose: (RecordingTargetChooser.Choice?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ChooserOption(icon: "crop", label: "Area") { onChoose(.area) }
            ChooserOption(icon: "macwindow", label: "Window") { onChoose(.window) }
            ChooserOption(icon: "display", label: "Screen") { onChoose(.screen) }

            Divider()
                .frame(height: 30)
                .overlay(.white.opacity(0.25))
                .padding(.horizontal, 6)

            Button(action: { onChoose(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .padding(8)
    }
}

private struct ChooserOption: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 48)
            .background(.white.opacity(hovering ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Record \(label.lowercased())")
    }
}
