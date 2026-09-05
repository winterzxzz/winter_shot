import Foundation

/// Abstraction over the recording side of the library: listing, deleting,
/// and the per-recording edit — the studio editor's options — kept
/// non-destructively next to the raw video. Implemented in the Data layer.
protocol RecordingRepository {
    /// All recordings in the library, newest first.
    func history() throws -> [Recording]

    /// Moves the raw video, its event log and its saved edit to the Trash.
    func delete(_ recording: Recording) throws

    /// The edit last saved for the recording; nil when it was never edited.
    func loadEdit(for recording: Recording) throws -> RecordingExportOptions?

    /// Persists the studio editor's options; nil removes the saved edit.
    func saveEdit(_ options: RecordingExportOptions?, for recording: Recording) throws
}
