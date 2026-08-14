import AppKit
import Foundation

/// Default ScreenshotRepository backed by the file-based library store.
/// Window capture uses the ScreenCaptureKit frozen-screen picker; area and
/// fullscreen use the system capture tool.
final class ScreenshotRepositoryImpl: ScreenshotRepository {
    private let captureService: SystemScreenCaptureService
    private let windowCaptureService: WindowCaptureService
    private let store: FileScreenshotStore

    var storageDirectory: URL { store.directory }

    init(captureService: SystemScreenCaptureService,
         windowCaptureService: WindowCaptureService,
         store: FileScreenshotStore) {
        self.captureService = captureService
        self.windowCaptureService = windowCaptureService
        self.store = store
    }

    func capture(mode: CaptureMode) async throws -> Screenshot? {
        let createdAt = Date()
        let imageURL = store.newImageURL(date: createdAt)

        let captured: Bool
        if mode == .window {
            captured = try await captureWindow(to: imageURL)
        } else {
            captured = try await captureService.capture(mode: mode, to: imageURL)
        }
        guard captured else {
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

    /// Frozen-screen picker capture; falls back to the system window picker
    /// when ScreenCaptureKit is unavailable. Returns false on cancel.
    private func captureWindow(to url: URL) async throws -> Bool {
        do {
            guard let cgImage = try await windowCaptureService.captureWindow() else {
                return false
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                return false
            }
            try data.write(to: url)
            return true
        } catch WindowCaptureService.WindowCaptureError.screenCaptureUnavailable {
            return try await captureService.capture(mode: .window, to: url)
        }
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
