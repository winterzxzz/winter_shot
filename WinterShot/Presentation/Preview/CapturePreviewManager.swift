import AppKit
import SwiftUI

/// After a capture succeeds, floats a thumbnail at the left edge of the
/// screen (like the system screenshot preview). Clicking it opens the editor;
/// it slides away on its own after a few seconds.
@MainActor
final class CapturePreviewManager {
    static let shared = CapturePreviewManager()

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private static let lifetime: TimeInterval = 6

    /// Shows the preview for a screenshot. `onOpen` runs when it is clicked.
    func show(screenshot: Screenshot, onOpen: @escaping (Screenshot) -> Void) {
        dismiss()

        guard let image = NSImage(contentsOf: screenshot.imageURL),
              let screen = NSScreen.main else {
            // No thumbnail to show — keep the old behavior and open directly.
            onOpen(screenshot)
            return
        }

        let maxThumb = CGSize(width: 240, height: 180)
        let scale = min(maxThumb.width / max(image.size.width, 1),
                        maxThumb.height / max(image.size.height, 1),
                        1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        panel.contentView = NSHostingView(rootView: CapturePreviewView(image: image) { [weak self] in
            self?.dismiss()
            onOpen(screenshot)
        })

        let origin = NSPoint(x: screen.visibleFrame.minX + 16,
                             y: screen.visibleFrame.minY + 24)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(hovering ? 0.9 : 0.5), lineWidth: 2)
            )
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: onClick)
            .help("Click to annotate")
    }
}
