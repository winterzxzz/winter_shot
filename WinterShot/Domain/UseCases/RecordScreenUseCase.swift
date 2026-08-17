import Foundation

/// Starts a screen recording.
@MainActor
struct StartRecordingUseCase {
    let recorder: ScreenRecorder

    func execute(target: RecordingTarget) async throws {
        try await recorder.start(target: target)
    }
}

/// Stops the active recording and returns it with its event log.
@MainActor
struct StopRecordingUseCase {
    let recorder: ScreenRecorder

    func execute() async throws -> (Recording, RecordingEventLog) {
        try await recorder.stop()
    }
}

/// Exports a raw recording with Screen Studio-style polish applied.
struct ExportRecordingUseCase {
    let renderer: RecordingRenderer

    func execute(recording: Recording,
                 events: RecordingEventLog,
                 options: RecordingExportOptions,
                 to destination: URL,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        try await renderer.export(recording: recording,
                                  events: events,
                                  options: options,
                                  to: destination,
                                  progress: progress)
    }
}
