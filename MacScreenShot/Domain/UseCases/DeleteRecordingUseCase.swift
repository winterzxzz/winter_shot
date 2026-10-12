import Foundation

/// Moves a recording, its event log and its saved edit to the Trash.
struct DeleteRecordingUseCase {
    let repository: RecordingRepository

    func execute(_ recording: Recording) throws {
        try repository.delete(recording)
    }
}
