import AppKit
import SwiftUI

/// While a recording runs, floats a small pill at the bottom-center of the
/// recorded screen: a pulsing record dot, the elapsed time, and a stop
/// button. It must be ordered on screen *before* the capture stream is
/// created — ScreenRecordingService excludes the app's own windows from the
/// recorded pixels, but only the ones that exist when the filter is built.
/// The pill can be dragged aside if it covers something.
@MainActor
final class RecordingHUDController {
    static let shared = RecordingHUDController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?
    private let model = RecordingHUDModel()
    private static let bottomInset: CGFloat = 24

    private init() {}

    /// Puts the widget up in its 00:00 state on the given screen — the one
    /// about to be recorded — or the screen under the pointer when nil. Call
    /// before the capture stream starts so the panel stays out of the
    /// recording.
    func show(on preferredScreen: NSScreen? = nil) {
        dismiss()
        let mouse = NSEvent.mouseLocation
        guard let screen = preferredScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        model.elapsedText = "00:00"

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

        let hosting = NSHostingView(rootView: RecordingHUDView(model: model) {
            RecordingController.shared.stop()
        })
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                     y: screen.visibleFrame.minY + Self.bottomInset))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Starts the clock — call once the recording has actually begun, so the
    /// pill doesn't count the capture stream's spin-up.
    func beginTimer() {
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let startedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let (hours, minutes, seconds) = (elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
        model.elapsedText = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        panel?.close()
        panel = nil
    }
}

@MainActor
private final class RecordingHUDModel: ObservableObject {
    @Published var elapsedText = "00:00"
}

private struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    let onStop: () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            Text(model.elapsedText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.red.opacity(0.85), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .padding(8)
    }
}
