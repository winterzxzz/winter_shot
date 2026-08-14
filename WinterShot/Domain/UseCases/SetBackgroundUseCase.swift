import Foundation

/// Stores (or clears, with nil) the background-beautify style for a screenshot.
struct SetBackgroundUseCase {
    let repository: AnnotationRepository

    func execute(_ background: BackdropStyle?, for screenshot: Screenshot) throws {
        try repository.saveBackground(background, for: screenshot)
    }
}

/// Loads the background-beautify style for a screenshot, if any.
struct LoadBackgroundUseCase {
    let repository: AnnotationRepository

    func execute(for screenshot: Screenshot) throws -> BackdropStyle? {
        try repository.loadBackground(for: screenshot)
    }
}
