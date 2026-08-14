import Foundation

/// Default ScreenshotRepository backed by the system capture tool
/// and the file-based library store.
final class ScreenshotRepositoryImpl: ScreenshotRepository {
    private let captureService: SystemScreenCaptureService
    private let store: FileScreenshotStore

    var storageDirectory: URL { store.directory }

    init(captureService: SystemScreenCaptureService, store: FileScreenshotStore) {
        self.captureService = captureService
        self.store = store
    }

    func capture(mode: CaptureMode) async throws -> Screenshot? {
        let createdAt = Date()
        let imageURL = store.newImageURL(date: createdAt)

        guard try await captureService.capture(mode: mode, to: imageURL) else {
            return nil // user cancelled
        }

        let screenshot = Screenshot(id: UUID(), imageURL: imageURL, createdAt: createdAt, mode: mode)
        let sidecar = ScreenshotSidecar(
            screenshotID: screenshot.id,
            mode: mode,
            createdAt: createdAt,
            annotations: []
        )
        try store.writeSidecar(sidecar, for: imageURL)
        return screenshot
    }

    func history() throws -> [Screenshot] {
        let urls = try store.imageURLs()
        let screenshots = urls.map { url -> Screenshot in
            if let sidecar = store.readSidecar(for: url) {
                return Screenshot(id: sidecar.screenshotID,
                                  imageURL: url,
                                  createdAt: sidecar.createdAt,
                                  mode: sidecar.mode)
            }
            // Image dropped into the folder without a sidecar — still usable.
            return Screenshot(id: UUID(),
                              imageURL: url,
                              createdAt: store.creationDate(of: url),
                              mode: .area)
        }
        return screenshots.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ screenshot: Screenshot) throws {
        try store.delete(imageURL: screenshot.imageURL)
    }
}
