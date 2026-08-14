import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted to trigger a capture programmatically (see AppDelegate launch hook).
    static let winterShotPerformCapture = Notification.Name("winterShotPerformCapture")
}

@main
struct WinterShotApp: App {
    var body: some Scene {
        // Menu-bar home base — the app has no Dock icon (LSUIElement).
        MenuBarExtra {
            MenuBarView(container: .shared)
        } label: {
            MenuBarIconView()
        }

        // One editor window per screenshot.
        WindowGroup("Editor", for: Screenshot.self) { $screenshot in
            if let screenshot {
                EditorView(screenshot: screenshot, container: .shared)
            }
        }
        .defaultSize(width: 1000, height: 700)

        // The capture library.
        WindowGroup("History", id: "history") {
            HistoryView(container: .shared)
        }
        .defaultSize(width: 760, height: 520)
    }
}

/// The menu-bar icon. Lives for the whole app lifetime (unlike the dropdown
/// content), so it also handles programmatic capture requests.
private struct MenuBarIconView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "camera.viewfinder")
            .onAppear {
                if let mode = Self.launchCaptureMode() {
                    NSLog("WinterShot: launch-argument capture requested (%@)", mode.rawValue)
                    perform(mode)
                }
                if let filename = Self.launchEditFilename() {
                    openEditor(filename: filename)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .winterShotPerformCapture)) { note in
                guard let raw = note.userInfo?["mode"] as? String,
                      let mode = CaptureMode(rawValue: raw) else { return }
                perform(mode)
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
        Task { @MainActor in
            guard let screenshot = try? DIContainer.shared.fetchHistoryUseCase.execute()
                .first(where: { $0.filename == filename }) else {
                NSLog("WinterShot: --edit found no capture named %@", filename)
                return
            }
            NSLog("WinterShot: opening editor for %@", filename)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(value: screenshot)
        }
    }

    private func perform(_ mode: CaptureMode) {
        Task { @MainActor in
            do {
                guard let screenshot = try await DIContainer.shared
                    .captureScreenshotUseCase.execute(mode: mode) else {
                    NSLog("WinterShot: capture cancelled or produced no file")
                    return
                }
                NSLog("WinterShot: captured %@", screenshot.imageURL.path)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(value: screenshot)
            } catch {
                NSLog("WinterShot: capture failed: %@", error.localizedDescription)
            }
        }
    }
}
