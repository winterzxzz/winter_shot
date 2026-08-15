import AppKit
import SwiftUI

/// Presents the first-launch onboarding window. Shown by the AppDelegate when
/// the onboarding flag is unset; closing the window (finish or the close
/// button) marks onboarding complete so it never reappears.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func showIfNeeded() {
        guard !AppPreferences.shared.hasCompletedOnboarding else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.finish()
        })
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        AppPreferences.shared.hasCompletedOnboarding = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as done — don't nag on every launch.
        AppPreferences.shared.hasCompletedOnboarding = true
        window = nil
    }
}
