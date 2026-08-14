import SwiftUI
import AppKit

/// The menu-bar dropdown — the app's home base.
struct MenuBarView: View {
    @StateObject private var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    init(container: DIContainer) {
        _viewModel = StateObject(wrappedValue: MenuBarViewModel(container: container))
    }

    var body: some View {
        Group {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    capture(mode)
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
            }

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            } label: {
                Label("History…", systemImage: "photo.on.rectangle.angled")
            }

            Button {
                NSWorkspace.shared.open(viewModel.capturesDirectory)
            } label: {
                Label("Open Captures Folder", systemImage: "folder")
            }

            if let error = viewModel.lastError {
                Divider()
                Text(error)
            }

            Divider()

            Button("Quit WinterShot") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func capture(_ mode: CaptureMode) {
        Task {
            guard let screenshot = await viewModel.capture(mode: mode) else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(value: screenshot)
        }
    }
}
