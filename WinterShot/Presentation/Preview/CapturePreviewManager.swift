import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// After a capture succeeds, floats a thumbnail card at the bottom-left of
/// the screen the pointer is on (like the system screenshot preview). Rapid
/// captures don't replace each other: each new card appears at the bottom
/// and pushes the earlier ones up into a column. Every card carries the same
/// quick actions as a library card: close, annotate, copy, pin, delete. Cards
/// can be dragged into other apps, follow the pointer to another display
/// while showing, and slide away on their own after the delay chosen in
/// Settings (paused while the pointer is over that card). Card size also
/// comes from Settings.
@MainActor
final class CapturePreviewManager {
    static let shared = CapturePreviewManager()

    private final class Entry {
        let id = UUID()
        let panel: NSPanel
        var dismissTimer: Timer?
        init(panel: NSPanel) { self.panel = panel }
    }

    /// Newest first; index 0 sits at the bottom of the column.
    private var entries: [Entry] = []
    private var screenTracker: Timer?
    private var currentScreen: NSScreen?
    private static let edgeInset = NSPoint(x: 16, y: 24)
    private static let stackSpacing: CGFloat = 12

    /// Shows a preview card for a screenshot. `onOpen` runs when it is clicked.
    func show(screenshot: Screenshot, onOpen: @escaping (Screenshot) -> Void) {
        guard let image = NSImage(contentsOf: screenshot.imageURL),
              let screen = Self.screenUnderPointer() else {
            // No thumbnail to show — keep the old behavior and open directly.
            onOpen(screenshot)
            return
        }

        let size = AppPreferences.shared.previewSize.cardSize

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
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let entry = Entry(panel: panel)

        let view = CapturePreviewView(
            image: image,
            fileURL: screenshot.imageURL,
            cardSize: size,
            onOpen: { [weak self, weak entry] in
                self?.close(entry)
                onOpen(screenshot)
            },
            onCopy: { [weak self, weak entry] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                self?.close(entry)
            },
            onPin: { [weak self, weak entry] in
                PinWindowManager.shared.pin(image: image)
                self?.close(entry)
            },
            onDelete: { [weak self, weak entry] in
                try? DIContainer.shared.deleteScreenshotUseCase.execute(screenshot)
                self?.close(entry)
            },
            onClose: { [weak self, weak entry] in
                self?.close(entry)
            },
            onHoverChange: { [weak self, weak entry] hovering in
                guard let entry else { return }
                if hovering {
                    entry.dismissTimer?.invalidate()
                    entry.dismissTimer = nil
                } else {
                    self?.scheduleDismiss(of: entry)
                }
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        // The new card takes the bottom slot; the ones already up slide out
        // of its way. Seat it there before the layout pass so it doesn't
        // animate in from the panel's default origin.
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + Self.edgeInset.x,
                                     y: screen.visibleFrame.minY + Self.edgeInset.y))
        entries.insert(entry, at: 0)
        currentScreen = screen
        trimToFit(on: screen)
        layout(on: screen, animated: true)
        panel.orderFrontRegardless()

        scheduleDismiss(of: entry)
        startFollowingPointer()
    }

    /// The screen containing the mouse pointer — where the user actually is,
    /// which on a multi-display setup is not always `NSScreen.main`.
    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Stacks the column up from the bottom-left corner. The bottom card is
    /// pinned to the corner; each card above it starts past the previous
    /// card's top edge.
    private func layout(on screen: NSScreen, animated: Bool) {
        let x = screen.visibleFrame.minX + Self.edgeInset.x
        var y = screen.visibleFrame.minY + Self.edgeInset.y
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.22 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for entry in entries {
                let target = NSRect(origin: NSPoint(x: x, y: y), size: entry.panel.frame.size)
                if entry.panel.frame.origin == target.origin || context.duration == 0 {
                    entry.panel.setFrame(target, display: true)
                } else {
                    entry.panel.animator().setFrame(target, display: true)
                }
                y = target.maxY + Self.stackSpacing
            }
        }
    }

    /// Drops the oldest cards (top of the column) when the stack would run
    /// off the screen.
    private func trimToFit(on screen: NSScreen) {
        let available = screen.visibleFrame.height - Self.edgeInset.y * 2
        func columnHeight() -> CGFloat {
            entries.reduce(0) { $0 + $1.panel.frame.height }
                + CGFloat(max(0, entries.count - 1)) * Self.stackSpacing
        }
        while entries.count > 1, columnHeight() > available {
            close(entries.last)
        }
    }

    /// While cards are up, hop to whichever display the pointer moves to,
    /// so they're never left behind on a screen the user has walked away from.
    private func startFollowingPointer() {
        guard screenTracker == nil else { return }
        screenTracker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followPointer() }
        }
    }

    private func followPointer() {
        guard !entries.isEmpty, let screen = Self.screenUnderPointer(),
              screen.frame != currentScreen?.frame else { return }
        currentScreen = screen
        trimToFit(on: screen)
        layout(on: screen, animated: false)
        for entry in entries {
            entry.panel.orderFrontRegardless()
        }
    }

    private func scheduleDismiss(of entry: Entry) {
        entry.dismissTimer?.invalidate()
        let lifetime = AppPreferences.shared.previewAutoHideSeconds
        let id = entry.id
        entry.dismissTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.close(self.entries.first { $0.id == id })
            }
        }
    }

    /// Removes one card; the ones above it settle down into the gap.
    private func close(_ entry: Entry?) {
        guard let entry, let index = entries.firstIndex(where: { $0 === entry }) else { return }
        entry.dismissTimer?.invalidate()
        entry.dismissTimer = nil
        entry.panel.close()
        entries.remove(at: index)
        if entries.isEmpty {
            screenTracker?.invalidate()
            screenTracker = nil
            currentScreen = nil
        } else if let screen = currentScreen {
            layout(on: screen, animated: true)
        }
    }

    func dismissAll() {
        while let entry = entries.first {
            close(entry)
        }
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    let fileURL: URL
    let cardSize: NSSize
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            // Fixed card filled edge to edge by the capture (aspect fill), so
            // every thumbnail — a tall sliver or a wide banner — has the same
            // footprint. Only this base image zooms on hover, clipped by the
            // card's corners; the border and controls stay put.
            Color.black
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardSize.width, height: cardSize.height)
                .scaleEffect(hovering ? 1.06 : 1)
                .animation(.easeOut(duration: 0.2), value: hovering)
            // A soft scrim behind the action bar keeps it readable on bright captures.
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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
