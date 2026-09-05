import Foundation

/// One entry of the capture library: a screenshot or a screen recording.
/// Both live in the same folder and share the history views; only the
/// editor they open in differs.
enum CaptureItem: Identifiable, Hashable {
    case screenshot(Screenshot)
    case recording(Recording)

    var id: UUID {
        switch self {
        case .screenshot(let screenshot): return screenshot.id
        case .recording(let recording): return recording.id
        }
    }

    var createdAt: Date {
        switch self {
        case .screenshot(let screenshot): return screenshot.createdAt
        case .recording(let recording): return recording.createdAt
        }
    }

    /// The immutable media file: the PNG of a screenshot, the MP4 of a recording.
    var fileURL: URL {
        switch self {
        case .screenshot(let screenshot): return screenshot.imageURL
        case .recording(let recording): return recording.videoURL
        }
    }

    var filename: String { fileURL.lastPathComponent }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

extension Notification.Name {
    /// Posted after the library gains or loses an item — a capture, a
    /// finished recording, a delete — so open history views reload. May be
    /// posted from any thread.
    static let winterShotLibraryChanged = Notification.Name("winterShotLibraryChanged")
}
