import AppKit
import SwiftUI

/// When several displays are connected, "Record Screen" needs to know which
/// one — the pointer is always on the chooser pill when it's clicked, so
/// "the screen under the cursor" could never reach the other display. Covers
/// every display with a dimmed veil; clicking one picks that display, Esc
/// cancels.
///
/// Set WINTERSHOT_AUTOSCREEN=<index into NSScreen.screens> (optionally
/// WINTERSHOT_AUTOPICK_DELAY=<seconds>) to auto-choose — used by smoke tests.
@MainActor
final class RecordingScreenPicker {
    static let shared = RecordingScreenPicker()

    private var panels: [NSPanel] = []
    private let escMonitor = EscapeCancelMonitor()
    private var continuation: CheckedContinuation<CGRect?, Never>?

    private init() {}

    /// The chosen display's bounds in global CoreGraphics coordinates
    /// (origin top-left), or nil when the user cancels.
    func pickScreenRegion() async -> CGRect? {
        finish(nil) // A re-trigger while a picker is up cancels the old one.
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            let bounds = CGDisplayBounds(id)

            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = NSHostingView(rootView: ScreenPickView(
                name: screen.localizedName,
                size: screen.frame.size,
                onPick: { [weak self] in self?.finish(bounds) }
            ))
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
        }
        guard !panels.isEmpty else {
            finish(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        escMonitor.start { [weak self] in self?.finish(nil) }

        let env = ProcessInfo.processInfo.environment
        if let index = env["WINTERSHOT_AUTOSCREEN"].flatMap(Int.init),
           NSScreen.screens.indices.contains(index),
           let id = Self.displayID(of: NSScreen.screens[index]) {
            let bounds = CGDisplayBounds(id)
            let delay = env["WINTERSHOT_AUTOPICK_DELAY"].flatMap(Double.init) ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish(bounds)
            }
        }
    }

    private func finish(_ bounds: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        escMonitor.stop()
        panels.forEach { $0.close() }
        panels.removeAll()
        continuation.resume(returning: bounds)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private struct ScreenPickView: View {
    let name: String
    let size: CGSize
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black.opacity(hovering ? 0.25 : 0.45)
            VStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 44, weight: .light))
                Text(name)
                    .font(.system(size: 20, weight: .semibold))
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.system(size: 13))
                    .opacity(0.7)
                Text("Click to record this screen")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.85)
                    .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(32)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(hovering ? 0.9 : 0.35), lineWidth: 2))
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .overlay(Rectangle().strokeBorder(.white.opacity(hovering ? 0.9 : 0), lineWidth: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPick)
        .ignoresSafeArea()
    }
}
