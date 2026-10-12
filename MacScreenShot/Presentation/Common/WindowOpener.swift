import AppKit
import SwiftUI

/// AppKit-side handle to SwiftUI's `openWindow` action. The action can only
/// be read from a live view environment, so an invisible one-pixel window
/// hosts BridgeView for the whole app lifetime and donates the action here
/// (the status item, notch panel, and capture preview all live outside
/// SwiftUI scenes but need to open the main window).
@MainActor
enum WindowOpener {
    static var openMainWindow: (() -> Void)?
    /// SwiftUI's `openSettings` action. The AppKit `showSettingsWindow:`
    /// selector stopped opening the Settings scene reliably on macOS 14, so
    /// the status-item menu calls this donated action instead.
    static var openSettings: (() -> Void)?

    private static var bridgeWindow: NSWindow?

    static func install() {
        guard bridgeWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: BridgeView())
        window.orderFrontRegardless()
        bridgeWindow = window
    }
}

private struct BridgeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onAppear {
                WindowOpener.openMainWindow = { openWindow(id: "main") }
                WindowOpener.openSettings = { openSettings() }
            }
    }
}
