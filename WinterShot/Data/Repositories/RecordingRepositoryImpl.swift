import Foundation

/// Default RecordingRepository backed by the file-based library store. The
/// studio editor's options live in a `.wsedit.json` sidecar next to the raw
/// video; the video and its event log are never modified.
final class RecordingRepositoryImpl: RecordingRepository {
    private let store: FileScreenshotStore

    init(store: FileScreenshotStore) {
        self.store = store
    }

    func history() throws -> [Recording] {
        let recordings = try store.videoURLs().map { url -> Recording in
            if let summary = store.readRecordingSummary(for: url) {
                return Recording(id: summary.recordingID,
                                 videoURL: url,
                                 createdAt: summary.createdAt,
                                 duration: summary.duration ?? 0,
                                 frameSize: CGSize(width: summary.frameWidth, height: summary.frameHeight))
            }
            // Video dropped into the folder without an event log — still
            // listed; the editor synthesizes an empty log for it.
            return Recording(id: FileScreenshotStore.stableID(for: url),
                             videoURL: url,
                             createdAt: store.creationDate(of: url),
                             duration: 0,
                             frameSize: .zero)
        }
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ recording: Recording) throws {
        try store.trashRecording(videoURL: recording.videoURL)
        NotificationCenter.default.post(name: .winterShotLibraryChanged, object: nil)
    }

    func loadEdit(for recording: Recording) throws -> RecordingExportOptions? {
        store.readRecordingEdit(for: recording.videoURL)?.options
    }

    func saveEdit(_ options: RecordingExportOptions?, for recording: Recording) throws {
        guard let options else {
            store.removeRecordingEdit(for: recording.videoURL)
            return
        }
        let sidecar = RecordingEditSidecar(recordingID: recording.id, savedAt: Date(), options: options)
        try store.writeRecordingEdit(sidecar, for: recording.videoURL)
    }
}
