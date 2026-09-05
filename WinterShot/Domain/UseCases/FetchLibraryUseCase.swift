import Foundation

/// Lists every capture in the library — screenshots and recordings — newest first.
struct FetchLibraryUseCase {
    let screenshots: ScreenshotRepository
    let recordings: RecordingRepository

    func execute() throws -> [CaptureItem] {
        let shots = try screenshots.history().map(CaptureItem.screenshot)
        let takes = try recordings.history().map(CaptureItem.recording)
        return (shots + takes).sorted { $0.createdAt > $1.createdAt }
    }
}
