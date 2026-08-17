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
            button.toolTip = "WinterShot"
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
            button.toolTip = "WinterShot — recording, click to stop"
        } else {
            button.image = AppIcon.menuBar
            button.toolTip = "WinterShot"
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

        let open = NSMenuItem(title: "Open WinterShot…",
                              action: #selector(openMainFromMenu),
                              keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                             accessibilityDescription: "Open WinterShot")
        menu.addItem(open)

        let folder = NSMenuItem(title: "Open Captures Folder",
                                action: #selector(openCapturesFolder),
                                keyEquivalent: "")
        folder.target = self
        folder.image = NSImage(systemSymbolName: "folder",
                               accessibilityDescription: "Open Captures Folder")
        menu.addItem(folder)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WinterShot",
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
                    NSLog("WinterShot: capture cancelled or produced no file")
                    return
                }
                NSLog("WinterShot: captured %@", screenshot.imageURL.path)
                CapturePreviewManager.shared.show(screenshot: screenshot) { [weak self] shot in
                    self?.openMain(with: shot)
                }
            } catch {
                NSLog("WinterShot: capture failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Main window

    /// Opens (or focuses) the main window from AppKit. When the SwiftUI
    /// window doesn't exist yet, the donated openWindow action (see
    /// WindowOpener) creates it.
    func openMain(with screenshot: Screenshot? = nil) {
        if let screenshot {
            DIContainer.shared.selectionBus.pending = screenshot
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
            NSLog("WinterShot: launch-argument capture requested (%@)", mode.rawValue)
            capture(mode)
        }
        if let filename = Self.launchEditFilename() {
            openEditor(filename: filename)
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
                        .first(where: { $0.filename == filename }) else { NSLog("WinterShot: --ocr found no capture named %@", filename); exit(1) }
                    let text = try await DIContainer.shared.recognizeTextUseCase.execute(imageURL: shot.imageURL)
                    print(text)
                    exit(0)
                } catch {
                    NSLog("WinterShot: OCR failed: %@", error.localizedDescription)
                    exit(1)
                }
            }
        }
        if CommandLine.arguments.contains("--show-recording-hud") {
            // Shows the recording timer widget without capturing (testing).
            RecordingHUDController.shared.show()
            RecordingHUDController.shared.beginTimer()
        }
        // Shows the post-capture thumbnail card for each image; repeat the
        // flag to exercise the stacked column (testing).
        for path in Self.launchValues(after: "--preview-image") {
            let shot = Screenshot(id: UUID(), imageURL: URL(fileURLWithPath: path), createdAt: Date(), mode: .area)
            CapturePreviewManager.shared.show(screenshot: shot) { [weak self] s in self?.openMain(with: s) }
        }
        if let input = Self.launchValue(after: "--export-recording"),
           let output = Self.launchValue(after: "--export-recording", offset: 2) {
            // Headless render for scripted testing: export (with defaults, or
            // the RecordingExportOptions JSON given by --export-options), then quit.
            Task { @MainActor in
                do {
                    var options = RecordingExportOptions()
                    if let path = Self.launchValue(after: "--export-options") {
                        options = try JSONDecoder().decode(RecordingExportOptions.self,
                                                           from: Data(contentsOf: URL(fileURLWithPath: path)))
                    }
                    try await RecordingController.export(videoURL: URL(fileURLWithPath: input),
                                                         to: URL(fileURLWithPath: output),
                                                         options: options)
                    NSLog("WinterShot: exported %@", output)
                    exit(0)
                } catch {
                    NSLog("WinterShot: export failed: %@", error.localizedDescription)
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

    /// Opens the editor for an existing capture by filename (`--edit <name>.png`).
    private func openEditor(filename: String) {
        guard let screenshot = try? DIContainer.shared.fetchHistoryUseCase.execute()
            .first(where: { $0.filename == filename }) else {
            NSLog("WinterShot: --edit found no capture named %@", filename)
            return
        }
        NSLog("WinterShot: opening editor for %@", filename)
        openMain(with: screenshot)
    }
}
