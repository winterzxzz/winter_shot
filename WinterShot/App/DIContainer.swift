import Foundation

/// Composition root. Wires Data-layer implementations to Domain-layer
/// protocols and hands ready-made use cases to the Presentation layer.
@MainActor
final class DIContainer {
    static let shared = DIContainer()

    // Data layer
    private let store: FileScreenshotStore
    private let captureService: SystemScreenCaptureService

    // Domain protocols (exposed as abstractions, not implementations)
    let screenshotRepository: ScreenshotRepository
    let annotationRepository: AnnotationRepository
    let ocrService: OCRService

    private init() {
        store = FileScreenshotStore()
        captureService = SystemScreenCaptureService()
        screenshotRepository = ScreenshotRepositoryImpl(captureService: captureService, store: store)
        annotationRepository = AnnotationRepositoryImpl(store: store)
        ocrService = VisionOCRService()
    }

    // Use cases
    var captureScreenshotUseCase: CaptureScreenshotUseCase {
        CaptureScreenshotUseCase(repository: screenshotRepository)
    }
    var fetchHistoryUseCase: FetchHistoryUseCase {
        FetchHistoryUseCase(repository: screenshotRepository)
    }
    var deleteScreenshotUseCase: DeleteScreenshotUseCase {
        DeleteScreenshotUseCase(repository: screenshotRepository)
    }
    var loadAnnotationsUseCase: LoadAnnotationsUseCase {
        LoadAnnotationsUseCase(repository: annotationRepository)
    }
    var saveAnnotationsUseCase: SaveAnnotationsUseCase {
        SaveAnnotationsUseCase(repository: annotationRepository)
    }
    var recognizeTextUseCase: RecognizeTextUseCase {
        RecognizeTextUseCase(ocrService: ocrService)
    }
}
