import AppKit
import SwiftUI

/// AppKit home base for everything that outlives SwiftUI scenes: the status
/// item (left-click drops the notch history panel, right-click shows the
/// classic menu), global hotkeys, launch arguments, and opening the main
/// window from outside a SwiftUI scene.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowOpener.install()
        setUpStatusItem()
        DIContainer.shared.startGlobalHotkeys()
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
            button.toolTip = "WinterShot — click for history"
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if RecordingController.shared.isRecording {
            // While recording the icon is a stop button.
            RecordingController.shared.stop()
        } else {
            NotchPanelManager.shared.toggle(on: sender.window?.screen)
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
            button.toolTip = "WinterShot — recording, click to stop (⌘⇧6)"
        } else {
            button.image = AppIcon.menuBar
            button.toolTip = "WinterShot — click for history"
        }
    }

    /// The classic dropdown, kept on right-click. Assigning the menu and
    /// clicking programmatically is the standard way to show it on demand
    /// while leaving left-click free for the panel.
    private func showStatusMenu() {
        let menu = NSMenu()
        for mode in CaptureMode.allCases {
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(captureFromMenu(_:)),
                                  keyEquivalent: String(mode.hotkeyNumber))
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.systemImage,
                                 accessibilityDescription: mode.label)
            menu.addItem(item)
        }

        let isRecording = RecordingController.shared.isRecording
        let record = NSMenuItem(title: isRecording ? "Stop Recording" : "Record Screen",
                                action: #selector(toggleRecordingFromMenu),
                                keyEquivalent: "6")
        record.keyEquivalentModifierMask = [.command, .shift]
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
