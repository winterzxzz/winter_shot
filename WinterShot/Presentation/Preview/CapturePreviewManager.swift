import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// After a capture succeeds, floats a thumbnail at the left edge of the
/// screen (like the system screenshot preview). It carries the same quick
/// actions as a library card: close, annotate, copy, pin, delete. It can be
/// dragged into other apps, and slides away on its own after a few seconds
/// (paused while the pointer is over it).
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

        let maxThumb = CGSize(width: 260, height: 200)
        let scale = min(maxThumb.width / max(image.size.width, 1),
                        maxThumb.height / max(image.size.height, 1),
                        1)
        let size = NSSize(width: max(image.size.width * scale, 180),
                          height: image.size.height * scale)

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

        let view = CapturePreviewView(
            image: image,
            fileURL: screenshot.imageURL,
            onOpen: { [weak self] in
                self?.dismiss()
                onOpen(screenshot)
            },
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                self?.dismiss()
            },
            onPin: { [weak self] in
                PinWindowManager.shared.pin(image: image)
                self?.dismiss()
            },
            onDelete: { [weak self] in
                try? DIContainer.shared.deleteScreenshotUseCase.execute(screenshot)
                self?.dismiss()
            },
            onClose: { [weak self] in
                self?.dismiss()
            },
            onHoverChange: { [weak self] hovering in
                if hovering {
                    self?.dismissTimer?.invalidate()
                    self?.dismissTimer = nil
                } else {
                    self?.scheduleDismiss()
                }
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        let origin = NSPoint(x: screen.visibleFrame.minX + 16,
                             y: screen.visibleFrame.minY + 24)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
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
    let fileURL: URL
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onHoverChange: (Bool) -> Void

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
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .padding(6)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 14) {
                    quickAction(icon: "rectangle.and.pencil.and.ellipsis", help: "Annotate", action: onOpen)
                    quickAction(icon: "doc.on.doc", help: "Copy", action: onCopy)
                    quickAction(icon: "pin", help: "Pin to screen", action: onPin)
                    quickAction(icon: "trash", help: "Delete", action: onDelete)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .padding(.bottom, 8)
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { value in
                hovering = value
                onHoverChange(value)
            }
            .onTapGesture(perform: onOpen)
            .onDrag { NSItemProvider(contentsOf: fileURL) ?? NSItemProvider() }
            .help("Click to annotate, or drag into another app")
    }

    private func quickAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
