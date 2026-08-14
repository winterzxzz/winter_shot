import Foundation
import CoreGraphics

/// Abstraction over the non-destructive annotation sidecar storage.
/// The crop is stored the same way: a rect in the sidecar, never applied
/// to the original pixels. Implemented in the Data layer.
protocol AnnotationRepository {
    func loadAnnotations(for screenshot: Screenshot) throws -> [Annotation]
    func saveAnnotations(_ annotations: [Annotation], for screenshot: Screenshot) throws
    func loadCrop(for screenshot: Screenshot) throws -> CGRect?
    func saveCrop(_ crop: CGRect?, for screenshot: Screenshot) throws
}
