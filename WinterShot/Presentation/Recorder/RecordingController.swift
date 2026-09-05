import AppKit
import AVFoundation

/// Coordinates the record/stop flow: drives the recorder use cases, tells the
/// status item to restyle while recording, and opens the studio editor when a
/// recording finishes — or again later from the library, with the edit that
/// was saved last time.
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
                openExportWindow(Loaded(recording: recording, events: events, edit: nil))
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

    /// A recording read back from disk: the raw video, its event log and the
    /// edit the studio editor saved for it (nil when it was never edited).
    struct Loaded {
        let recording: Recording
        let events: RecordingEventLog
        let edit: RecordingExportOptions?
    }

    enum LoadError: LocalizedError {
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The file has no video track."
            }
        }
    }

    /// Loads a raw recording, its `.wsrec.json` sidecar and its saved edit
    /// from disk. A video without an event log (dropped into the folder by
    /// hand) gets an empty log sized from the asset, so it still opens —
    /// just without cursor or auto-zoom.
    nonisolated static func load(videoURL: URL) async throws -> Loaded {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let events: RecordingEventLog
        if let data = try? Data(contentsOf: FileScreenshotStore.recordingSidecarURL(for: videoURL)) {
            events = try JSONDecoder().decode(RecordingEventLog.self, from: data)
        } else {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LoadError.noVideoTrack
            }
            let size = try await track.load(.naturalSize)
            let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
            events = RecordingEventLog(recordingID: FileScreenshotStore.stableID(for: videoURL),
                                       createdAt: attributes?[.creationDate] as? Date ?? Date(),
                                       firstFrameTime: 0,
                                       frameWidth: size.width,
                                       frameHeight: size.height,
                                       pixelScale: 1,
                                       duration: duration,
                                       cursorSamples: [],
                                       clicks: [])
        }
        let recording = Recording(id: events.recordingID,
                                  videoURL: videoURL,
                                  createdAt: events.createdAt,
                                  duration: duration,
                                  frameSize: CGSize(width: events.frameWidth, height: events.frameHeight))
        let loadEdit = await DIContainer.shared.loadRecordingEditUseCase
        let edit = try? loadEdit.execute(for: recording)
        return Loaded(recording: recording, events: events, edit: edit)
    }

    /// Opens the studio editor for a recording on disk, or brings its window
    /// forward when it is already open.
    func open(videoURL: URL) {
        if let existing = exportWindows.first(where: { $0.videoURL == videoURL }) {
            existing.show()
            return
        }
        Task { @MainActor in
            do {
                openExportWindow(try await Self.load(videoURL: videoURL))
            } catch {
                NSLog("WinterShot: could not open recording %@: %@", videoURL.path, error.localizedDescription)
                presentError(error)
            }
        }
    }

    /// Headless export — used by `--export-recording`. Without explicit
    /// options the recording's saved edit is rendered, or the defaults when
    /// it has none.
    nonisolated static func export(videoURL: URL, to destination: URL,
                                   options: RecordingExportOptions? = nil) async throws {
        let loaded = try await load(videoURL: videoURL)
        let options = options ?? loaded.edit ?? RecordingExportOptions()
        let useCase = await DIContainer.shared.exportRecordingUseCase
        try await useCase.execute(recording: loaded.recording, events: loaded.events,
                                  options: options, to: destination) { fraction in
            NSLog("WinterShot: export %3.0f%%", fraction * 100)
        }
    }

    private func openExportWindow(_ loaded: Loaded) {
        let controller = RecordingExportWindowController(recording: loaded.recording,
                                                         events: loaded.events,
                                                         edit: loaded.edit)
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
