import Foundation

/// State for the menu-bar dropdown: kicks off captures and reports errors.
@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var isCapturing = false
    @Published var lastError: String?

    private let captureScreenshotUseCase: CaptureScreenshotUseCase
    let capturesDirectory: URL

    init(container: DIContainer) {
        self.captureScreenshotUseCase = container.captureScreenshotUseCase
        self.capturesDirectory = container.screenshotRepository.storageDirectory
    }

    /// Returns the new screenshot, or nil when the user cancels.
    func capture(mode: CaptureMode) async -> Screenshot? {
        isCapturing = true
        defer { isCapturing = false }
        do {
            lastError = nil
            return try await captureScreenshotUseCase.execute(mode: mode)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
