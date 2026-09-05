import CryptoKit
import Foundation

/// Sidecar document stored next to each screenshot image.
/// Holds the screenshot metadata plus its editable annotations.
struct ScreenshotSidecar: Codable {
    var screenshotID: UUID
    var mode: CaptureMode
    var createdAt: Date
    var annotations: [Annotation]
    /// Non-destructive crop in image pixel space; nil shows the full capture.
    var crop: CGRect?
    /// Non-destructive background beautify; nil renders the bare capture.
    var background: BackdropStyle?
}

/// Sidecar document written next to a recording once the studio editor has
/// changed something: the export options as last seen there, so the take
/// reopens where it was left. The raw video and its event log stay untouched.
struct RecordingEditSidecar: Codable {
    var recordingID: UUID
    var savedAt: Date
    var options: RecordingExportOptions
}

/// The fields of a recording's event log the library needs to list it,
/// decoded without the (large) cursor-sample array.
struct RecordingSummary: Decodable {
    var recordingID: UUID
    var createdAt: Date
    var frameWidth: Double
    var frameHeight: Double
    /// Written since the library listed recordings; nil in older logs.
    var duration: Double?
}

/// Owns the on-disk layout of the capture library:
/// ~/Library/Application Support/WinterShot/Captures/
///   WinterShot-20260814-231502.png         <- immutable capture
///   WinterShot-20260814-231502.wshot.json  <- sidecar (metadata + annotations)
///   WinterShot-20260814-233015.mp4         <- immutable recording
///   WinterShot-20260814-233015.wsrec.json  <- sidecar (cursor samples, clicks, timing)
///   WinterShot-20260814-233015.wsedit.json <- sidecar (studio editor options), once edited
///
/// Sidecars live next to their capture so the set can never drift apart,
/// but they are flagged hidden so the folder shows only pictures and movies
/// in Finder (⌘⇧. reveals them).
final class FileScreenshotStore {
    let directory: URL
    private let fileManager = FileManager.default

    /// Sidecar suffixes this app writes next to captures and recordings.
    static let sidecarSuffixes = [".wshot.json", ".wsrec.json", ".wsedit.json"]

    init() {
        if let override = ProcessInfo.processInfo.environment["WS_CAPTURES_DIR"], !override.isEmpty {
            // Test hook: point the library somewhere else, so scripted runs
            // and documentation shoots never touch the real captures.
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("WinterShot/Captures", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        hideExistingSidecars()
    }

    /// Flags a sidecar as hidden in Finder.
    static func hide(_ url: URL) {
        var values = URLResourceValues()
        values.isHidden = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// One-off migration for libraries written before sidecars were hidden.
    private func hideExistingSidecars() {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isHiddenKey],
                                                                  options: []) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard Self.sidecarSuffixes.contains(where: { name.hasSuffix($0) }) else { continue }
            if (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true {
                Self.hide(url)
            }
        }
    }

    /// A library identity for a file that has no sidecar to carry one:
    /// derived from the path, so it survives a reload.
    static func stableID(for url: URL) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(url.lastPathComponent.utf8))
        return digest.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    private func newCaptureName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "WinterShot-\(formatter.string(from: date))"
    }

    func creationDate(of url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date).flatMap { $0 } ?? Date()
    }

    private func contents() throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory,
                                            includingPropertiesForKeys: [.creationDateKey],
                                            options: .skipsHiddenFiles)
    }

    // MARK: - Screenshots

    func newImageURL(date: Date = Date()) -> URL {
        directory.appendingPathComponent(newCaptureName(date: date) + ".png")
    }

    func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("wshot.json")
    }

    func imageURLs() throws -> [URL] {
        try contents().filter { $0.pathExtension.lowercased() == "png" }
    }

    func readSidecar(for imageURL: URL) -> ScreenshotSidecar? {
        let url = sidecarURL(for: imageURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScreenshotSidecar.self, from: data)
    }

    func writeSidecar(_ sidecar: ScreenshotSidecar, for imageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let url = sidecarURL(for: imageURL)
        try data.write(to: url, options: .atomic)
        Self.hide(url)
    }

    func delete(imageURL: URL) throws {
        try? fileManager.removeItem(at: sidecarURL(for: imageURL))
        try fileManager.removeItem(at: imageURL)
    }

    // MARK: - Recordings

    private static let videoExtensions: Set<String> = ["mp4", "mov"]

    func newVideoURL(date: Date = Date()) -> URL {
        directory.appendingPathComponent(newCaptureName(date: date) + ".mp4")
    }

    /// The event log recorded alongside the raw video.
    static func recordingSidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("wsrec.json")
    }

    /// The studio editor's saved options for the video.
    static func editSidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("wsedit.json")
    }

    func videoURLs() throws -> [URL] {
        try contents().filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    func readRecordingSummary(for videoURL: URL) -> RecordingSummary? {
        guard let data = try? Data(contentsOf: Self.recordingSidecarURL(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingSummary.self, from: data)
    }

    func readRecordingEdit(for videoURL: URL) -> RecordingEditSidecar? {
        guard let data = try? Data(contentsOf: Self.editSidecarURL(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingEditSidecar.self, from: data)
    }

    func writeRecordingEdit(_ sidecar: RecordingEditSidecar, for videoURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let url = Self.editSidecarURL(for: videoURL)
        try data.write(to: url, options: .atomic)
        Self.hide(url)
    }

    func removeRecordingEdit(for videoURL: URL) {
        try? fileManager.removeItem(at: Self.editSidecarURL(for: videoURL))
    }

    /// Moves the video and its sidecars to the Trash. A take is slow to redo,
    /// so unlike a screenshot it is never removed outright unless the volume
    /// has no Trash.
    func trashRecording(videoURL: URL) throws {
        try trashOrRemove(videoURL)
        for url in [Self.recordingSidecarURL(for: videoURL), Self.editSidecarURL(for: videoURL)]
        where fileManager.fileExists(atPath: url.path) {
            try? trashOrRemove(url)
        }
    }

    private func trashOrRemove(_ url: URL) throws {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try fileManager.removeItem(at: url)
        }
    }
}
