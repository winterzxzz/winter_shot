import AppKit
import AVFoundation

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
    private var isStarting = false
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
        guard !isRecording, !isStarting else { return }
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            do {
                guard let target = try await pickTarget() else { return }
                // The timer widget goes up first: the recorder excludes the
                // app's windows from the capture, but only those already on
                // screen when the stream's filter is built. The short pause
                // lets the window server register the panel before
                // ScreenCaptureKit enumerates.
                RecordingHUDController.shared.show(on: Self.screen(for: target))
                try? await Task.sleep(nanoseconds: 150_000_000)
                do {
                    try await DIContainer.shared.startRecordingUseCase.execute(target: target)
                    isRecording = true
                    RecordingHUDController.shared.beginTimer()
                    onStateChange?(true)
                } catch {
                    RecordingHUDController.shared.dismiss()
                    throw error
                }
            } catch {
                NSLog("WinterShot: recording start failed: %@", error.localizedDescription)
                presentError(error)
            }
        }
    }

    /// Asks what to record (area / window / screen) and runs the matching
    /// picker. Nil when the user cancels at either step.
    private func pickTarget() async throws -> RecordingTarget? {
        switch await RecordingTargetChooser.shared.choose() {
        case nil:
            return nil
        case .screen:
            // With several displays "under the cursor" can only ever mean the
            // display holding the chooser pill, so ask which one to record. A
            // single display needs no ask.
            guard NSScreen.screens.count > 1 else { return .screen }
            guard let bounds = await RecordingScreenPicker.shared.pickScreenRegion() else { return nil }
            return .region(bounds)
        case .area:
            guard let rect = try await DIContainer.shared.areaCaptureService.pickRegion() else { return nil }
            return .region(rect)
        case .window:
            guard let rect = try await DIContainer.shared.windowCaptureService.pickWindowRegion() else { return nil }
            return .region(rect)
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        RecordingHUDController.shared.dismiss()
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

    /// The display a region target records on — the timer widget belongs
    /// there, not on whichever screen the pointer ended up on.
    private static func screen(for target: RecordingTarget) -> NSScreen? {
        guard case .region(let rect) = target else { return nil }
        return NSScreen.screens.first { screen in
            guard let id = RecordingScreenPicker.displayID(of: screen) else { return false }
            return CGDisplayBounds(id).contains(CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    // MARK: - Existing recordings

    /// Loads a raw recording and its `.wsrec.json` sidecar from disk.
    nonisolated static func load(videoURL: URL) async throws -> (Recording, RecordingEventLog) {
        let sidecar = ScreenRecordingService.sidecarURL(for: videoURL)
        let events = try JSONDecoder().decode(RecordingEventLog.self, from: Data(contentsOf: sidecar))
        let duration = try await AVURLAsset(url: videoURL).load(.duration).seconds
        let recording = Recording(id: events.recordingID,
                                  videoURL: videoURL,
                                  createdAt: events.createdAt,
                                  duration: duration,
                                  frameSize: CGSize(width: events.frameWidth, height: events.frameHeight))
        return (recording, events)
    }

    /// Reopens the export window for a recording on disk.
    func open(videoURL: URL) {
        Task { @MainActor in
            do {
                let (recording, events) = try await Self.load(videoURL: videoURL)
                openExportWindow(recording: recording, events: events)
            } catch {
                NSLog("WinterShot: could not open recording %@: %@", videoURL.path, error.localizedDescription)
                presentError(error)
            }
        }
    }

    /// Headless export with default options — used by `--export-recording`.
    nonisolated static func export(videoURL: URL, to destination: URL,
                                   options: RecordingExportOptions = RecordingExportOptions()) async throws {
        let (recording, events) = try await load(videoURL: videoURL)
        let useCase = await DIContainer.shared.exportRecordingUseCase
        try await useCase.execute(recording: recording, events: events, options: options, to: destination) { fraction in
            NSLog("WinterShot: export %3.0f%%", fraction * 100)
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
