import Foundation

/// Abstraction over screenshot capture and library management.
/// Implemented in the Data layer.
protocol ScreenshotRepository {
    /// Runs an interactive (or fullscreen) capture.
    /// Returns nil when the user cancels the capture.
    func capture(mode: CaptureMode) async throws -> Screenshot?

    /// All screenshots in the library, newest first.
    func history() throws -> [Screenshot]

    /// Removes the screenshot image and its annotation sidecar.
    func delete(_ screenshot: Screenshot) throws

    /// Folder where captures are stored.
    var storageDirectory: URL { get }
}
