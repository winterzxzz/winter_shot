import Foundation

/// Keeps the studio editor's options on disk as they change, so a recording
/// reopens where it was left. Writes are debounced (a slider drag is one
/// write) and flushed when the window closes. Nothing is written until the
/// options differ from what is saved, so a take that is only looked at gets
/// no sidecar.
@MainActor
final class RecordingEditAutosave: ObservableObject {
    /// The last write that failed, for the editor to show.
    @Published private(set) var lastError: String?

    private let recording: Recording
    private let save: SaveRecordingEditUseCase
    private var saved: RecordingExportOptions?
    private var pending: RecordingExportOptions?
    private var task: Task<Void, Never>?

    private static let delay: UInt64 = 500_000_000

    init(recording: Recording, saved: RecordingExportOptions?, useCase: SaveRecordingEditUseCase) {
        self.recording = recording
        self.saved = saved
        self.save = useCase
    }

    /// Records the latest options; they reach disk after a short pause.
    func schedule(_ options: RecordingExportOptions) {
        pending = options
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the pending options now.
    func flush() {
        task?.cancel()
        task = nil
        guard let pending else { return }
        self.pending = nil
        guard pending != (saved ?? RecordingExportOptions()) else { return }
        do {
            try save.execute(pending, for: recording)
            saved = pending
            lastError = nil
        } catch {
            lastError = "Could not save edits: \(error.localizedDescription)"
        }
    }

    /// Drops anything pending — after the recording was deleted.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
