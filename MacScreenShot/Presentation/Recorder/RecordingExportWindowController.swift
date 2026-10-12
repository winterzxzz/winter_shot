import AppKit
import SwiftUI

/// AppKit-managed window hosting the recording export view — like the pin
/// and notch panels, it must outlive SwiftUI scenes and open from anywhere.
@MainActor
final class RecordingExportWindowController: NSObject, NSWindowDelegate {
    var onClose: ((RecordingExportWindowController) -> Void)?

    /// The raw recording this window edits, so a second open focuses it.
    let videoURL: URL

    private let window: NSWindow
    private let autosave: RecordingEditAutosave

    init(recording: Recording, events: RecordingEventLog, edit: RecordingExportOptions?) {
        videoURL = recording.videoURL
        autosave = RecordingEditAutosave(recording: recording,
                                         saved: edit,
                                         useCase: DIContainer.shared.saveRecordingEditUseCase)
        let view = RecordingExportView(recording: recording, events: events, edit: edit, autosave: autosave)
        let hosting = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hosting)
        window.title = "Recording — \(recording.filename)"
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.minSize = NSSize(width: 980, height: 640)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The view draws its own 60 pt top bar, and that is the title bar as
        // far as the user is concerned — so make AppKit agree. An empty
        // unified toolbar draws nothing (the title bar is transparent and it
        // has no items) but stretches the title-bar hit region from 32 pt to
        // 66 pt: the whole top bar drags the window and double-click runs
        // the system title-bar action (zoom by default), and the traffic
        // lights drop to the bar's midline. The view ignores the top safe
        // area so the bar sits in that region instead of below it.
        let toolbar = NSToolbar(identifier: "com.winterzxzz.WinterShot.editor-titlebar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        // Screen Studio's window color (#08090D).
        window.backgroundColor = NSColor(srgbRed: 0x08 / 255, green: 0x09 / 255, blue: 0x0D / 255, alpha: 1)
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
        // The last edits may still be waiting out the autosave delay.
        autosave.flush()
        onClose?(self)
    }
}
