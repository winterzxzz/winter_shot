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

/// Owns the on-disk layout of the screenshot library:
/// ~/Library/Application Support/WinterShot/Captures/
///   WinterShot-20260814-231502.png        <- immutable capture
///   WinterShot-20260814-231502.wshot.json <- sidecar (metadata + annotations)
///
/// Sidecars live next to their capture so the pair can never drift apart,
/// but they are flagged hidden so the folder shows only pictures and movies
/// in Finder (⌘⇧. reveals them).
final class FileScreenshotStore {
    let directory: URL
    private let fileManager = FileManager.default

    /// Sidecar suffixes this app writes next to captures and recordings.
    static let sidecarSuffixes = [".wshot.json", ".wsrec.json"]

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("WinterShot/Captures", isDirectory: true)
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
        let url = sidecarURL(for: imageURL)
        try data.write(to: url, options: .atomic)
        Self.hide(url)
    }

    func delete(imageURL: URL) throws {
        try? fileManager.removeItem(at: sidecarURL(for: imageURL))
        try fileManager.removeItem(at: imageURL)
    }

    func creationDate(of url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date).flatMap { $0 } ?? Date()
    }
}
