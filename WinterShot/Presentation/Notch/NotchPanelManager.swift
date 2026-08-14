import AppKit
import SwiftUI

/// Observable state shared between the panel manager and the SwiftUI content
/// so show/hide can drive the expand/collapse spring from AppKit.
@MainActor
final class NotchPanelState: ObservableObject {
    @Published var expanded = false
    /// Height of the hardware notch / menu bar zone the content must clear.
    @Published var topInset: CGFloat = 12
    @Published var hasNotch = false
}

/// Drives the notch history panel: a borderless panel hanging from the top
/// center of the screen (visually merging with the notch) that springs open
/// on status-item click and collapses back into the notch on dismiss.
@MainActor
final class NotchPanelManager {
    static let shared = NotchPanelManager()

    private var panel: NotchPanel?
    private let state = NotchPanelState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hiddenAt: Date = .distantPast

    private static let panelSize = NSSize(width: 920, height: 350)
    private static let collapseDuration: TimeInterval = 0.30

    func toggle(on screen: NSScreen?) {
        if panel != nil {
            hide()
        } else {
            // The mouse-down monitor may have just hidden the panel for this
            // same click; don't instantly reopen it on the mouse-up.
            guard Date().timeIntervalSince(hiddenAt) > 0.4 else { return }
            show(on: screen)
        }
    }

    func show(on screen: NSScreen?) {
        guard panel == nil, let screen = screen ?? NSScreen.main else { return }

        let size = Self.panelSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: screen.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar so the shape reads as part of the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        state.expanded = false
        state.hasNotch = screen.safeAreaInsets.top > 0
        state.topInset = state.hasNotch ? screen.safeAreaInsets.top : 12

        let view = NotchHistoryView(
            state: state,
            viewModel: NotchHistoryViewModel(container: .shared),
            onOpen: { [weak self] screenshot in
                self?.hide()
                (NSApp.delegate as? AppDelegate)?.openMain(with: screenshot)
            },
            onOpenLibrary: { [weak self] in
                self?.hide()
                (NSApp.delegate as? AppDelegate)?.openMain()
            },
            onCapture: { [weak self] mode in
                self?.hide()
                // Give the panel a beat to collapse before the overlay appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDuration) {
                    (NSApp.delegate as? AppDelegate)?.capture(mode)
                }
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(frame, display: true)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        installMonitors()

        // Land collapsed first, then spring open from the notch.
        DispatchQueue.main.async { [state] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                state.expanded = true
            }
        }
    }

    func hide() {
        guard let panel else { return }
        removeMonitors()
        hiddenAt = Date()
        self.panel = nil
        withAnimation(.spring(response: Self.collapseDuration, dampingFraction: 0.9)) {
            state.expanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDuration + 0.05) {
            panel.orderOut(nil)
        }
    }

    // MARK: - Dismissal monitors

    private func installMonitors() {
        // Clicks anywhere in another app.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // Clicks in our own app outside the panel, plus Esc.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.hide()
                    return nil
                }
                return event
            }
            // Ignore clicks inside the panel; the status item button gets a
            // pass too so its own toggle handling stays in charge.
            if let window = event.window,
               window === panel || window.className.contains("StatusBar") {
                return event
            }
            self.hide()
            return event
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

/// Borderless panels refuse key status by default; the notch panel wants it
/// so Esc dismisses without activating the app (.nonactivatingPanel).
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
