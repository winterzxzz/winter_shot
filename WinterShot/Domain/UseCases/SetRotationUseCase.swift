import Foundation

/// Stores (or clears, with nil) the non-destructive rotation for a screenshot.
struct SetRotationUseCase {
    let repository: AnnotationRepository

    func execute(_ rotation: ImageRotation?, for screenshot: Screenshot) throws {
        try repository.saveRotation(rotation, for: screenshot)
    }
}

/// Loads the non-destructive rotation for a screenshot, if any.
struct LoadRotationUseCase {
    let repository: AnnotationRepository

    func execute(for screenshot: Screenshot) throws -> ImageRotation? {
        try repository.loadRotation(for: screenshot)
    }
}
