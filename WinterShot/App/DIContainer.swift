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
    let screenRecorder: ScreenRecorder
    let recordingRenderer: RecordingRenderer

    // Cross-scene selection channel for the main window
    let selectionBus = SelectionBus()

    private let hotkeyService = GlobalHotkeyService()
    let updateService = GitHubUpdateService()

    /// Registers ⌘⇧4/⌘⇧8/⌘⇧9 captures and ⌘⇧6 record toggle.
    /// Safe to call repeatedly.
    func startGlobalHotkeys() {
        hotkeyService.onTrigger = { mode in
            NotificationCenter.default.post(name: .winterShotPerformCapture,
                                            object: nil,
                                            userInfo: ["mode": mode.rawValue])
        }
        hotkeyService.onRecordToggle = {
            RecordingController.shared.toggle()
        }
        hotkeyService.register()
    }

    private init() {
        store = FileScreenshotStore()
        captureService = SystemScreenCaptureService()
        let windowCaptureService = WindowCaptureService(picker: WindowPickerOverlayPresenter())
        let areaCaptureService = AreaCaptureService(picker: AreaPickerOverlayPresenter())
        screenshotRepository = ScreenshotRepositoryImpl(captureService: captureService,
                                                        windowCaptureService: windowCaptureService,
                                                        areaCaptureService: areaCaptureService,
                                                        store: store)
        annotationRepository = AnnotationRepositoryImpl(store: store)
        ocrService = VisionOCRService()
        screenRecorder = ScreenRecordingService(store: store)
        recordingRenderer = RecordingExporterService()
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
    var setCropUseCase: SetCropUseCase {
        SetCropUseCase(repository: annotationRepository)
    }
    var loadCropUseCase: LoadCropUseCase {
        LoadCropUseCase(repository: annotationRepository)
    }
    var setBackgroundUseCase: SetBackgroundUseCase {
        SetBackgroundUseCase(repository: annotationRepository)
    }
    var loadBackgroundUseCase: LoadBackgroundUseCase {
        LoadBackgroundUseCase(repository: annotationRepository)
    }
    var startRecordingUseCase: StartRecordingUseCase {
        StartRecordingUseCase(recorder: screenRecorder)
    }
    var stopRecordingUseCase: StopRecordingUseCase {
        StopRecordingUseCase(recorder: screenRecorder)
    }
    var exportRecordingUseCase: ExportRecordingUseCase {
        ExportRecordingUseCase(renderer: recordingRenderer)
    }
}
