import Foundation
import CoreGraphics

/// Abstraction over the non-destructive annotation sidecar storage.
/// The crop and the rotation are stored the same way: a rect and a quarter
/// turn in the sidecar, never applied to the original pixels. Implemented
/// in the Data layer.
protocol AnnotationRepository {
    func loadAnnotations(for screenshot: Screenshot) throws -> [Annotation]
    func saveAnnotations(_ annotations: [Annotation], for screenshot: Screenshot) throws
    func loadCrop(for screenshot: Screenshot) throws -> CGRect?
    func saveCrop(_ crop: CGRect?, for screenshot: Screenshot) throws
    func loadBackground(for screenshot: Screenshot) throws -> BackdropStyle?
    func saveBackground(_ background: BackdropStyle?, for screenshot: Screenshot) throws
    func loadRotation(for screenshot: Screenshot) throws -> ImageRotation?
    func saveRotation(_ rotation: ImageRotation?, for screenshot: Screenshot) throws
}
