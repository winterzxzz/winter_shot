import Foundation

/// Lists every screenshot in the library, newest first.
struct FetchHistoryUseCase {
    let repository: ScreenshotRepository

    func execute() throws -> [Screenshot] {
        try repository.history()
    }
}
