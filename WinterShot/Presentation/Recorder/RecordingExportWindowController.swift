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
        window.setContentSize(NSSize(width: 960, height: 620))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
