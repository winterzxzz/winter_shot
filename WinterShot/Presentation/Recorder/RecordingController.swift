import AppKit

/// Coordinates the record/stop flow: drives the recorder use cases, tells the
/// status item to restyle while recording, and opens the export window when a
/// recording finishes.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    /// Fired whenever recording starts or stops, so the status item can swap
    /// its icon.
    var onStateChange: ((Bool) -> Void)?

    private(set) var isRecording = false
    private var exportWindows: [RecordingExportWindowController] = []

    private init() {}

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording else { return }
        Task { @MainActor in
            do {
                try await DIContainer.shared.startRecordingUseCase.execute()
                isRecording = true
                onStateChange?(true)
            } catch {
                NSLog("WinterShot: recording start failed: %@", error.localizedDescription)
                presentError(error)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        onStateChange?(false)
        Task { @MainActor in
            do {
                let (recording, events) = try await DIContainer.shared.stopRecordingUseCase.execute()
                openExportWindow(recording: recording, events: events)
            } catch {
                NSLog("WinterShot: recording stop failed: %@", error.localizedDescription)
                presentError(error)
            }
        }
    }

    private func openExportWindow(recording: Recording, events: RecordingEventLog) {
        let controller = RecordingExportWindowController(recording: recording, events: events)
        controller.onClose = { [weak self] closed in
            self?.exportWindows.removeAll { $0 === closed }
        }
        exportWindows.append(controller)
        controller.show()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
