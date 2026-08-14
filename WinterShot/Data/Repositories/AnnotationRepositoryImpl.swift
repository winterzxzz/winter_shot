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
        var sidecar = store.readSidecar(for: screenshot.imageURL) ?? ScreenshotSidecar(
            screenshotID: screenshot.id,
            mode: screenshot.mode,
            createdAt: screenshot.createdAt,
            annotations: []
        )
        sidecar.annotations = annotations
        try store.writeSidecar(sidecar, for: screenshot.imageURL)
    }
}
