import SwiftUI

@main
struct WinterShotApp: App {
    var body: some Scene {
        // Menu-bar home base — the app has no Dock icon (LSUIElement).
        MenuBarExtra("WinterShot", systemImage: "camera.viewfinder") {
            MenuBarView(container: .shared)
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
