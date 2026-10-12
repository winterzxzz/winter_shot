import Foundation
import CoreGraphics

/// Stores (or clears, with nil) the non-destructive crop for a screenshot.
struct SetCropUseCase {
    let repository: AnnotationRepository

    func execute(_ crop: CGRect?, for screenshot: Screenshot) throws {
        try repository.saveCrop(crop, for: screenshot)
    }
}

/// Loads the non-destructive crop for a screenshot, if any.
struct LoadCropUseCase {
    let repository: AnnotationRepository

    func execute(for screenshot: Screenshot) throws -> CGRect? {
        try repository.loadCrop(for: screenshot)
    }
}
