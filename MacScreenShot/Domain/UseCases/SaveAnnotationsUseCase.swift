import Foundation

/// Persists annotations to the screenshot's sidecar file.
/// The original image is never touched.
struct SaveAnnotationsUseCase {
    let repository: AnnotationRepository

    func execute(_ annotations: [Annotation], for screenshot: Screenshot) throws {
        try repository.saveAnnotations(annotations, for: screenshot)
    }
}
