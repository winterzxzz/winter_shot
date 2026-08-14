import Foundation

/// Sidecar document stored next to each screenshot image.
/// Holds the screenshot metadata plus its editable annotations.
struct ScreenshotSidecar: Codable {
    var screenshotID: UUID
    var mode: CaptureMode
    var createdAt: Date
    var annotations: [Annotation]
}

/// Owns the on-disk layout of the screenshot library:
/// ~/Library/Application Support/WinterShot/Captures/
///   WinterShot-20260814-231502.png        <- immutable capture
///   WinterShot-20260814-231502.wshot.json <- sidecar (metadata + annotations)
final class FileScreenshotStore {
    let directory: URL
    private let fileManager = FileManager.default

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("WinterShot/Captures", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func newImageURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "WinterShot-\(formatter.string(from: date)).png"
        return directory.appendingPathComponent(name)
    }

    func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("wshot.json")
    }

    func imageURLs() throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        return contents.filter { $0.pathExtension.lowercased() == "png" }
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
        try data.write(to: sidecarURL(for: imageURL), options: .atomic)
    }

    func delete(imageURL: URL) throws {
        try? fileManager.removeItem(at: sidecarURL(for: imageURL))
        try fileManager.removeItem(at: imageURL)
    }

    func creationDate(of url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date).flatMap { $0 } ?? Date()
    }
}
