import Foundation

/// Composition root. Wires Data-layer implementations to Domain-layer
/// protocols and hands ready-made use cases to the Presentation layer.
@MainActor
final class DIContainer {
    static let shared = DIContainer()

    // Data layer
    private let store: FileScreenshotStore
    private let captureService: SystemScreenCaptureService
    // Also drive the record-target pickers (area rect / window frame).
    let windowCaptureService: WindowCaptureService
    let areaCaptureService: AreaCaptureService

    // Domain protocols (exposed as abstractions, not implementations)
    let screenshotRepository: ScreenshotRepository
    let annotationRepository: AnnotationRepository
    let recordingRepository: RecordingRepository
    let ocrService: OCRService
    let screenRecorder: ScreenRecorder
    let recordingRenderer: RecordingRenderer

    // Cross-scene selection channel for the main window
    let selectionBus = SelectionBus()

    private let hotkeyService = GlobalHotkeyService()
    let updateService = GitHubUpdateService()

    /// Registers the user's capture hotkey (default ⌘⇧4) and keeps the
    /// registration in sync when the preference changes. Safe to call
    /// repeatedly.
    func startGlobalHotkeys() {
        hotkeyService.onTrigger = { mode in
            NotificationCenter.default.post(name: .winterShotPerformCapture,
                                            object: nil,
                                            userInfo: ["mode": mode.rawValue])
        }
        hotkeyService.register(AppPreferences.shared.captureHotkey)
        NotificationCenter.default.addObserver(forName: .winterShotHotkeyChanged,
                                               object: nil,
                                               queue: .main) { [hotkeyService] _ in
            MainActor.assumeIsolated {
                hotkeyService.register(AppPreferences.shared.captureHotkey)
            }
        }
    }

    /// Temporarily releases the capture hotkey so the Settings recorder can
    /// see every keypress — otherwise pressing the current combo would fire a
    /// capture instead of re-recording it.
    func pauseGlobalHotkey() {
        hotkeyService.unregister()
    }

    func resumeGlobalHotkey() {
        hotkeyService.register(AppPreferences.shared.captureHotkey)
    }

    private init() {
        store = FileScreenshotStore()
        captureService = SystemScreenCaptureService()
        windowCaptureService = WindowCaptureService(picker: WindowPickerOverlayPresenter())
        areaCaptureService = AreaCaptureService(picker: AreaPickerOverlayPresenter())
        screenshotRepository = ScreenshotRepositoryImpl(captureService: captureService,
                                                        windowCaptureService: windowCaptureService,
                                                        areaCaptureService: areaCaptureService,
                                                        store: store)
        annotationRepository = AnnotationRepositoryImpl(store: store)
        recordingRepository = RecordingRepositoryImpl(store: store)
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
    var fetchLibraryUseCase: FetchLibraryUseCase {
        FetchLibraryUseCase(screenshots: screenshotRepository, recordings: recordingRepository)
    }
    var deleteScreenshotUseCase: DeleteScreenshotUseCase {
        DeleteScreenshotUseCase(repository: screenshotRepository)
    }
    var deleteRecordingUseCase: DeleteRecordingUseCase {
        DeleteRecordingUseCase(repository: recordingRepository)
    }
    var loadRecordingEditUseCase: LoadRecordingEditUseCase {
        LoadRecordingEditUseCase(repository: recordingRepository)
    }
    var saveRecordingEditUseCase: SaveRecordingEditUseCase {
        SaveRecordingEditUseCase(repository: recordingRepository)
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
