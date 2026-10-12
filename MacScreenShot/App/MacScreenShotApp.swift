import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted to trigger a capture programmatically (global hotkeys, launch hook).
    static let winterShotPerformCapture = Notification.Name("winterShotPerformCapture")
}

@main
struct MacScreenShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Hidden primary scene. It keeps SwiftUI from auto-presenting the main
        // window at launch; the visible status item is AppKit-managed (see
        // AppDelegate) so left-click can drop the notch history panel instead
        // of a menu.
        MenuBarExtra("MacScreenShot", isInserted: .constant(false)) {
            EmptyView()
        }

        // The main window: captures library + editor. Opened from AppKit via
        // the donated openWindow action (see WindowOpener).
        Window("MacScreenShot", id: "main") {
            MainWindowView(container: .shared)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
        }
    }
}
