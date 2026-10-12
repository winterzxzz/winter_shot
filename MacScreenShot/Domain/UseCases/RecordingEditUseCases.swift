import Foundation

/// Loads the studio editor's saved options for a recording, if it was edited.
struct LoadRecordingEditUseCase {
    let repository: RecordingRepository

    func execute(for recording: Recording) throws -> RecordingExportOptions? {
        try repository.loadEdit(for: recording)
    }
}

/// Persists the studio editor's options next to the recording.
/// The raw video and its event log are never touched.
struct SaveRecordingEditUseCase {
    let repository: RecordingRepository

    func execute(_ options: RecordingExportOptions?, for recording: Recording) throws {
        try repository.saveEdit(options, for: recording)
    }
}
