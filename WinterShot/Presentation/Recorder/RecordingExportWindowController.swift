import AppKit
import SwiftUI

/// AppKit-managed window hosting the recording export view — like the pin
/// and notch panels, it must outlive SwiftUI scenes and open from anywhere.
@MainActor
final class RecordingExportWindowController: NSObject, NSWindowDelegate {
    var onClose: ((RecordingExportWindowController) -> Void)?

    private let window: NSWindow

    init(recording: Recording, events: RecordingEventLog) {
        let view = RecordingExportView(recording: recording, events: events)
        let hosting = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hosting)
        window.title = "Recording — \(recording.filename)"
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1)
        window.center()
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
