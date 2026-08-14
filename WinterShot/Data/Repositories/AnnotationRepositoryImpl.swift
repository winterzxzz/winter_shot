import Foundation

/// Default AnnotationRepository storing annotations in the JSON sidecar
/// next to the image — the capture itself is never modified.
final class AnnotationRepositoryImpl: AnnotationRepository {
    private let store: FileScreenshotStore

    init(store: FileScreenshotStore) {
        self.store = store
    }

    func loadAnnotations(for screenshot: Screenshot) throws -> [Annotation] {
        store.readSidecar(for: screenshot.imageURL)?.annotations ?? []
    }

    func saveAnnotations(_ annotations: [Annotation], for screenshot: Screenshot) throws {
        var sidecar = sidecar(for: screenshot)
        sidecar.annotations = annotations
        try store.writeSidecar(sidecar, for: screenshot.imageURL)
    }

    func loadCrop(for screenshot: Screenshot) throws -> CGRect? {
        store.readSidecar(for: screenshot.imageURL)?.crop
    }

    func saveCrop(_ crop: CGRect?, for screenshot: Screenshot) throws {
        var sidecar = sidecar(for: screenshot)
        sidecar.crop = crop
        try store.writeSidecar(sidecar, for: screenshot.imageURL)
    }

    func loadBackground(for screenshot: Screenshot) throws -> BackdropStyle? {
        store.readSidecar(for: screenshot.imageURL)?.background
    }

    func saveBackground(_ background: BackdropStyle?, for screenshot: Screenshot) throws {
        var sidecar = sidecar(for: screenshot)
        sidecar.background = background
        try store.writeSidecar(sidecar, for: screenshot.imageURL)
    }

    private func sidecar(for screenshot: Screenshot) -> ScreenshotSidecar {
        store.readSidecar(for: screenshot.imageURL) ?? ScreenshotSidecar(
            screenshotID: screenshot.id,
            mode: screenshot.mode,
            createdAt: screenshot.createdAt,
            annotations: [],
            crop: nil,
            background: nil
        )
    }
}
