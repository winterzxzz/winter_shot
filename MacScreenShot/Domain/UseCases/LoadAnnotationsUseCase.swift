import Foundation

/// Loads the non-destructive annotations for a screenshot.
struct LoadAnnotationsUseCase {
    let repository: AnnotationRepository

    func execute(for screenshot: Screenshot) throws -> [Annotation] {
        try repository.loadAnnotations(for: screenshot)
    }
}
