import Foundation

/// Abstraction over the non-destructive annotation sidecar storage.
/// Implemented in the Data layer.
protocol AnnotationRepository {
    func loadAnnotations(for screenshot: Screenshot) throws -> [Annotation]
    func saveAnnotations(_ annotations: [Annotation], for screenshot: Screenshot) throws
}
