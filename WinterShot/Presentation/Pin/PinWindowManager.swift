import AppKit
import SwiftUI

/// Floats a flattened screenshot above every other window ("pin to screen").
/// Drag to move, double-click to dismiss.
@MainActor
final class PinWindowManager {
    static let shared = PinWindowManager()
    private var panels: [NSPanel] = []

    func pin(image: NSImage) {
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.contentView = NSHostingView(rootView: PinView(image: image) { [weak panel, weak self] in
            guard let panel else { return }
            panel.close()
            self?.panels.removeAll { $0 == panel }
        })

        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.maxY - size.height - 24
            )
            panel.setFrameOrigin(origin)
        }

        panels.append(panel)
        panel.orderFrontRegardless()
    }
}

private struct PinView: View {
    let image: NSImage
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.25), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.72), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Unpin")
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2, perform: onClose)
            .contextMenu {
                Button("Unpin", action: onClose)
            }
            .help("Double-click or hover for ✕ to unpin")
    }
}
