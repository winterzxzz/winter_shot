import Foundation

/// A captured screenshot on disk. The image file is immutable; annotations
/// live in a sidecar file next to it (non-destructive by design).
struct Screenshot: Identifiable, Codable, Hashable {
    let id: UUID
    let imageURL: URL
    let createdAt: Date
    let mode: CaptureMode

    var filename: String { imageURL.lastPathComponent }
}
