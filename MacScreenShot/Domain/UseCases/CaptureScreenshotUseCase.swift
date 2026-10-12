import Foundation

/// Captures a screenshot in the requested mode.
struct CaptureScreenshotUseCase {
    let repository: ScreenshotRepository

    func execute(mode: CaptureMode) async throws -> Screenshot? {
        try await repository.capture(mode: mode)
    }
}
