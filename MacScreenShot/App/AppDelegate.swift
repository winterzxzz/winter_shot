import AppKit
import SwiftUI

/// AppKit home base for everything that outlives SwiftUI scenes: the status
/// item (click shows the features menu; its "Show History" item drops the
/// notch panel), global hotkeys, launch arguments, and opening the main
/// window from outside a SwiftUI scene.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyTheme()
        WindowOpener.install()
        setUpStatusItem()
        DIContainer.shared.startGlobalHotkeys()
        OnboardingWindowController.shared.showIfNeeded()
        RecordingController.shared.onStateChange = { [weak self] recording in
            self?.updateStatusIcon(recording: recording)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureNotification(_:)),
            name: .winterShotPerformCapture,
            object: nil
        )
        handleLaunchArguments()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = AppIcon.menuBar
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MacScreenShot"
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if RecordingController.shared.isRecording, NSApp.currentEvent?.type == .leftMouseUp {
            // While recording the icon is a stop button.
            RecordingController.shared.stop()
        } else {
            // Both clicks show the features menu; the notch history panel
            // opens from its "Show History" item so shots are easy to drag.
            showStatusMenu()
        }
    }

    /// Swaps the status icon to a red stop symbol while recording.
    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            let icon = NSImage(systemSymbolName: "stop.circle.fill",
                               accessibilityDescription: "Stop Recording")?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            button.image = icon
            button.toolTip = "MacScreenShot — recording, click to stop"
        } else {
            button.image = AppIcon.menuBar
            button.toolTip = "MacScreenShot"
        }
    }

    /// The features dropdown, shown on any click. Assigning the menu and
    /// clicking programmatically shows it on demand while keeping the button
    /// action free to act as a stop button during recording.
    private func showStatusMenu() {
        let menu = NSMenu()
        let hotkey = AppPreferences.shared.captureHotkey
        for mode in CaptureMode.allCases {
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(captureFromMenu(_:)),
                                  keyEquivalent: mode == .area ? hotkey.keyEquivalent : "")
            if mode == .area {
                item.keyEquivalentModifierMask = hotkey.menuModifierMask
            }
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.systemImage,
                                 accessibilityDescription: mode.label)
            menu.addItem(item)
        }

        let isRecording = RecordingController.shared.isRecording
        let record = NSMenuItem(title: isRecording ? "Stop Recording" : "Start Recording…",
                                action: #selector(toggleRecordingFromMenu),
                                keyEquivalent: "")
        record.target = self
        record.image = NSImage(systemSymbolName: isRecording ? "stop.circle" : "record.circle",
                               accessibilityDescription: record.title)
        menu.addItem(record)
        menu.addItem(.separator())

        let history = NSMenuItem(title: "Show History",
                                 action: #selector(showHistoryFromMenu),
                                 keyEquivalent: "")
        history.target = self
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                accessibilityDescription: "Show History")
        menu.addItem(history)

        let open = NSMenuItem(title: "Open MacScreenShot…",
                              action: #selector(openMainFromMenu),
                              keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                             accessibilityDescription: "Open MacScreenShot")
        menu.addItem(open)

        let folder = NSMenuItem(title: "Open Captures Folder",
                                action: #selector(openCapturesFolder),
                                keyEquivalent: "")
        folder.target = self
        folder.image = NSImage(systemSymbolName: "folder",
                               accessibilityDescription: "Open Captures Folder")
        menu.addItem(folder)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettingsFromMenu),
                                  keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape",
                                 accessibilityDescription: "Settings")
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacScreenShot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CaptureMode(rawValue: raw) else { return }
        capture(mode)
    }

    @objc private func toggleRecordingFromMenu() {
        RecordingController.shared.toggle()
    }

    @objc private func showHistoryFromMenu() {
        NotchPanelManager.shared.toggle(on: statusItem?.button?.window?.screen)
    }

    @objc private func openMainFromMenu() {
        openMain()
    }

    @objc private func openCapturesFolder() {
        NSWorkspace.shared.open(DIContainer.shared.screenshotRepository.storageDirectory)
    }

    /// Opens the SwiftUI `Settings` scene. As an agent app (LSUIElement) the
    /// app must be activated first so the window comes to the front. The
    /// AppKit `showSettingsWindow:` selector no longer opens the scene
    /// reliably on macOS 14, so prefer SwiftUI's donated `openSettings`
    /// action (see WindowOpener), falling back to the selector.
    @objc private func openSettingsFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettings = WindowOpener.openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Capture

    @objc private func handleCaptureNotification(_ note: Notification) {
        guard let raw = note.userInfo?["mode"] as? String,
              let mode = CaptureMode(rawValue: raw) else { return }
        capture(mode)
    }

    func capture(_ mode: CaptureMode) {
        Task { @MainActor in
            do {
                guard let screenshot = try await DIContainer.shared
                    .captureScreenshotUseCase.execute(mode: mode) else {
                    NSLog("MacScreenShot: capture cancelled or produced no file")
                    return
                }
                NSLog("MacScreenShot: captured %@", screenshot.imageURL.path)
                if AppPreferences.shared.copyToClipboardAfterCapture,
                   let image = NSImage(contentsOf: screenshot.imageURL) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                CapturePreviewManager.shared.show(screenshot: screenshot) { [weak self] shot in
                    self?.openMain(with: .screenshot(shot))
                }
            } catch {
                NSLog("MacScreenShot: capture failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Main window

    /// Opens a library item where it is edited: a screenshot in the main
    /// window's editor, a recording in the studio editor window.
    func open(_ item: CaptureItem) {
        switch item {
        case .screenshot:
            openMain(with: item)
        case .recording(let recording):
            RecordingController.shared.open(videoURL: recording.videoURL)
        }
    }

    /// Opens (or focuses) the main window from AppKit, optionally selecting a
    /// library item. When the SwiftUI window doesn't exist yet, the donated
    /// openWindow action (see WindowOpener) creates it.
    func openMain(with item: CaptureItem? = nil) {
        if let item {
            DIContainer.shared.selectionBus.pending = item
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else if let opener = WindowOpener.openMainWindow {
            opener()
        } else {
            // The bridge hasn't donated openWindow yet (early launch, e.g.
            // --edit) — retry until it has. Any pending selection is already
            // parked on the selection bus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.openMain()
            }
        }
    }

    // MARK: - Launch arguments

    private func handleLaunchArguments() {
        if let mode = Self.launchCaptureMode() {
            NSLog("MacScreenShot: launch-argument capture requested (%@)", mode.rawValue)
            capture(mode)
        }
        if let filename = Self.launchEditFilename() {
            openEditor(filename: filename)
        }
        if let filename = Self.launchValue(after: "--show") {
            // Opens the main window with that capture selected — a recording
            // shows its detail pane rather than the studio editor (testing).
            if let item = try? DIContainer.shared.fetchLibraryUseCase.execute()
                .first(where: { $0.filename == filename }) {
                openMain(with: item)
            } else {
                NSLog("MacScreenShot: --show found no capture named %@", filename)
            }
        }
        if CommandLine.arguments.contains("--history") {
            NotchPanelManager.shared.show(on: NSScreen.main)
        }
        if CommandLine.arguments.contains("--open-main") {
            // Next runloop turn so the WindowOpener bridge has appeared.
            DispatchQueue.main.async { [weak self] in self?.openMain() }
        }
        if let path = Self.launchValue(after: "--open-recording") {
            RecordingController.shared.open(videoURL: URL(fileURLWithPath: path))
        }
        if let filename = Self.launchValue(after: "--ocr") {
            // Runs OCR on a library capture through the app's own pipeline and quits (testing).
            Task { @MainActor in
                do {
                    guard let shot = try DIContainer.shared.fetchHistoryUseCase.execute()
                        .first(where: { $0.filename == filename }) else { NSLog("MacScreenShot: --ocr found no capture named %@", filename); exit(1) }
                    let text = try await DIContainer.shared.recognizeTextUseCase.execute(imageURL: shot.imageURL)
                    print(text)
                    exit(0)
                } catch {
                    NSLog("MacScreenShot: OCR failed: %@", error.localizedDescription)
                    exit(1)
                }
            }
        }
        if let directory = Self.launchValue(after: "--snapshot-windows") {
            // Writes a PNG of every open window once the UI has settled, then
            // quits (testing) — see WindowSnapshotter.
            Task { @MainActor in
                // WS_SNAPSHOT_SCREEN=<index into NSScreen.screens> moves the
                // windows there first — e.g. onto the Retina display, so the
                // snapshots come out at 2x whichever screen is the main one.
                var settle: UInt64 = 5_000_000_000
                if let index = ProcessInfo.processInfo.environment["WS_SNAPSHOT_SCREEN"].flatMap(Int.init),
                   NSScreen.screens.indices.contains(index) {
                    // Inside the same five seconds, so short-lived panels
                    // (the preview cards) are still up when the shot is taken.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    settle -= 1_000_000_000
                    let area = NSScreen.screens[index].visibleFrame
                    for window in NSApp.windows where window.isVisible && window.screen != NSScreen.screens[index] {
                        var frame = window.frame
                        frame.size.width = min(frame.width, area.width)
                        frame.size.height = min(frame.height, area.height)
                        frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
                        window.setFrame(frame, display: true)
                    }
                }
                try? await Task.sleep(nanoseconds: settle)
                await WindowSnapshotter.writeAll(to: URL(fileURLWithPath: directory))
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--show-recording-hud") {
            // Shows the recording timer widget without capturing (testing).
            RecordingHUDController.shared.show()
            RecordingHUDController.shared.beginTimer()
        }
        if CommandLine.arguments.contains("--open-settings") {
            // Opens the Settings window without going through the status
            // menu, so the menu action can be exercised headlessly (testing).
            DispatchQueue.main.async { [weak self] in self?.openSettingsFromMenu() }
        }
        if let value = Self.launchValue(after: "--login-item") {
            // Reads or flips "Open at login" without the Settings window, so
            // the registration can be scripted and checked (testing).
            let service = LoginItemService.shared
            switch value {
            case "on": service.setEnabled(true)
            case "off": service.setEnabled(false)
            case "status": service.refresh()
            default:
                NSLog("MacScreenShot: --login-item expects on, off or status")
                exit(1)
            }
            if let error = service.errorMessage {
                NSLog("MacScreenShot: login item failed: %@", error)
                print("error: \(error)")
                exit(1)
            }
            print(service.isEnabled ? "enabled" : service.needsApproval ? "requiresApproval" : "notRegistered")
            exit(0)
        }
        // Shows the post-capture thumbnail card for each image; repeat the
        // flag to exercise the stacked column (testing).
        for path in Self.launchValues(after: "--preview-image") {
            let shot = Screenshot(id: UUID(), imageURL: URL(fileURLWithPath: path), createdAt: Date(), mode: .area)
            CapturePreviewManager.shared.show(screenshot: shot) { [weak self] s in self?.openMain(with: .screenshot(s)) }
        }
        if let input = Self.launchValue(after: "--export-recording"),
           let output = Self.launchValue(after: "--export-recording", offset: 2) {
            // Headless render for scripted testing: export with the
            // RecordingExportOptions JSON given by --export-options, else the
            // recording's saved edit, else the defaults — then quit.
            Task { @MainActor in
                do {
                    var options: RecordingExportOptions?
                    if let path = Self.launchValue(after: "--export-options") {
                        options = try JSONDecoder().decode(RecordingExportOptions.self,
                                                           from: Data(contentsOf: URL(fileURLWithPath: path)))
                    }
                    try await RecordingController.export(videoURL: URL(fileURLWithPath: input),
                                                         to: URL(fileURLWithPath: output),
                                                         options: options)
                    NSLog("MacScreenShot: exported %@", output)
                    exit(0)
                } catch {
                    NSLog("MacScreenShot: export failed: %@", error.localizedDescription)
                    exit(1)
                }
            }
        }
    }

    private static func launchValue(after flag: String, offset: Int = 1) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + offset) else { return nil }
        return CommandLine.arguments[index + offset]
    }

    /// The value after every occurrence of a repeatable flag.
    private static func launchValues(after flag: String) -> [String] {
        let arguments = CommandLine.arguments
        return arguments.indices.compactMap { index in
            guard arguments[index] == flag, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    private static func launchCaptureMode() -> CaptureMode? {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CaptureMode(rawValue: CommandLine.arguments[index + 1])
    }

    private static func launchEditFilename() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--edit"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Opens the editor for an existing capture by filename — the main
    /// window for `--edit <name>.png`, the studio editor for `--edit <name>.mp4`.
    private func openEditor(filename: String) {
        guard let item = try? DIContainer.shared.fetchLibraryUseCase.execute()
            .first(where: { $0.filename == filename }) else {
            NSLog("MacScreenShot: --edit found no capture named %@", filename)
            return
        }
        NSLog("MacScreenShot: opening editor for %@", filename)
        open(item)
    }
}
