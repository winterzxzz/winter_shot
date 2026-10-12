import Foundation

/// Deletes a screenshot and its annotation sidecar.
struct DeleteScreenshotUseCase {
    let repository: ScreenshotRepository

    func execute(_ screenshot: Screenshot) throws {
        try repository.delete(screenshot)
    }
}
