import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drives the annotation editor: tool state, drag lifecycle (drawing, and
/// moving with the select cursor), zoom, undo/redo, sidecar persistence,
/// OCR, pinning, and flattened export.
@MainActor
final class EditorViewModel: ObservableObject {
    enum ZoomMode: Equatable {
        case fit
        case percent(CGFloat)
    }

    let screenshot: Screenshot

    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    /// nil means the select cursor is active.
    @Published var selectedTool: AnnotationTool? = .arrow
    @Published var currentColor: AnnotationColor = .red
    @Published var lineWidth: Double = 4
    @Published var selectedAnnotationID: Annotation.ID?
    @Published var statusMessage: String?
    @Published var zoomMode: ZoomMode = .fit
    /// The scale the canvas last rendered at; drives the zoom label in fit mode.
    @Published var renderedScale: CGFloat = 1

    /// Non-destructive crop in image pixel space; nil shows the full capture.
    @Published var crop: CGRect?
    @Published var isCropping = false
    @Published var cropDraft: CGRect?
    private var cropDragStart: CGPoint?

    let image: NSImage?
    let imagePixelSize: CGSize

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var moveOriginalPoints: [CGPoint]?

    private let loadAnnotationsUseCase: LoadAnnotationsUseCase
    private let saveAnnotationsUseCase: SaveAnnotationsUseCase
    private let recognizeTextUseCase: RecognizeTextUseCase
    private let setCropUseCase: SetCropUseCase
    private let loadCropUseCase: LoadCropUseCase

    private static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.25, 1.5, 2, 3, 4]

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedAnnotationIndex: Int? {
        annotations.firstIndex { $0.id == selectedAnnotationID }
    }

    var selectedAnnotation: Annotation? {
        selectedAnnotationIndex.map { annotations[$0] }
    }

    init(screenshot: Screenshot, container: DIContainer) {
        self.screenshot = screenshot
        self.loadAnnotationsUseCase = container.loadAnnotationsUseCase
        self.saveAnnotationsUseCase = container.saveAnnotationsUseCase
        self.recognizeTextUseCase = container.recognizeTextUseCase
        self.setCropUseCase = container.setCropUseCase
        self.loadCropUseCase = container.loadCropUseCase

        let nsImage = NSImage(contentsOf: screenshot.imageURL)
        self.image = nsImage
        if let rep = nsImage?.representations.first {
            // Pixel dimensions, not point dimensions — Retina captures are 2x.
            self.imagePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            self.imagePixelSize = nsImage?.size ?? .zero
        }

        self.annotations = (try? loadAnnotationsUseCase.execute(for: screenshot)) ?? []
        self.crop = (try? loadCropUseCase.execute(for: screenshot)) ?? nil
    }

    // MARK: - Crop

    var fullImageRect: CGRect {
        CGRect(origin: .zero, size: imagePixelSize)
    }

    /// What the canvas shows: the full image while cropping, otherwise the crop.
    var visibleRect: CGRect {
        isCropping ? fullImageRect : (crop ?? fullImageRect)
    }

    func enterCropMode() {
        selectedAnnotationID = nil
        cropDraft = crop
        isCropping = true
        zoomMode = .fit
    }

    func cancelCrop() {
        isCropping = false
        cropDraft = nil
        cropDragStart = nil
    }

    func applyCrop() {
        defer { isCropping = false; cropDraft = nil; cropDragStart = nil }
        guard let draft = cropDraft, draft.width >= 20, draft.height >= 20 else { return }
        crop = draft
        persistCrop()
        zoomMode = .fit
        statusMessage = "Cropped to \(Int(draft.width)) × \(Int(draft.height)) px (non-destructive)."
    }

    func resetCrop() {
        guard crop != nil else { return }
        crop = nil
        persistCrop()
        zoomMode = .fit
        statusMessage = "Crop reset."
    }

    private func persistCrop() {
        do {
            try setCropUseCase.execute(crop, for: screenshot)
        } catch {
            statusMessage = "Could not save crop: \(error.localizedDescription)"
        }
    }

    private func cropDragBegan(at point: CGPoint) {
        cropDragStart = point
        cropDraft = nil
    }

    private func cropDragChanged(to point: CGPoint) {
        guard let start = cropDragStart else { return }
        let rect = CGRect(x: min(start.x, point.x),
                          y: min(start.y, point.y),
                          width: abs(point.x - start.x),
                          height: abs(point.y - start.y))
        cropDraft = rect.intersection(fullImageRect)
    }

    // MARK: - Zoom

    func effectiveScale(fitting available: CGSize) -> CGFloat {
        let content = visibleRect.size
        switch zoomMode {
        case .percent(let value):
            return value
        case .fit:
            guard content.width > 0, content.height > 0,
                  available.width > 0, available.height > 0 else { return 1 }
            let padding: CGFloat = 48
            return max(min((available.width - padding) / content.width,
                           (available.height - padding) / content.height,
                           1), 0.02)
        }
    }

    var zoomLabel: String {
        "\(Int((renderedScale * 100).rounded()))%"
    }

    func zoomIn() {
        let current = renderedScale
        let next = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!
        zoomMode = .percent(next)
    }

    func zoomOut() {
        let current = renderedScale
        let next = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!
        zoomMode = .percent(next)
    }

    func zoomToFit() { zoomMode = .fit }
    func zoomToActual() { zoomMode = .percent(1) }

    // MARK: - Drag lifecycle (all points in image pixel space)

    func dragBegan(at point: CGPoint) {
        if isCropping {
            cropDragBegan(at: point)
            return
        }
        guard let tool = selectedTool else {
            beginMove(at: point)
            return
        }
        guard !tool.isPointTool else { return }
        draft = makeAnnotation(tool: tool, at: point)
    }

    func dragChanged(to point: CGPoint, translation: CGSize) {
        if isCropping {
            cropDragChanged(to: point)
            return
        }
        guard let tool = selectedTool else {
            continueMove(translation: translation)
            return
        }
        guard var current = draft else { return }
        if tool.isPathTool {
            current.points.append(point)
        } else {
            current.points = [current.start, point]
        }
        draft = current
    }

    func dragEnded(at point: CGPoint, translation: CGSize) {
        if isCropping {
            cropDragChanged(to: point)
            cropDragStart = nil
            return
        }
        guard let tool = selectedTool else {
            endMove(translation: translation, at: point)
            return
        }
        if tool.isPointTool {
            placePointAnnotation(tool: tool, at: point)
            return
        }
        guard let current = draft else { return }
        draft = nil
        // Ignore accidental micro-drags for shape tools.
        let span = hypot(current.end.x - current.start.x, current.end.y - current.start.y)
        if !tool.isPathTool && span < 4 { return }
        commit(annotations + [current])
        selectedAnnotationID = current.id
    }

    // MARK: - Select cursor: hit-test and move

    private func beginMove(at point: CGPoint) {
        guard let hit = hitTest(point) else {
            selectedAnnotationID = nil
            moveOriginalPoints = nil
            return
        }
        selectedAnnotationID = hit.id
        moveOriginalPoints = hit.points
    }

    private func continueMove(translation: CGSize) {
        guard let original = moveOriginalPoints, let index = selectedAnnotationIndex else { return }
        annotations[index].points = original.map {
            CGPoint(x: $0.x + translation.width, y: $0.y + translation.height)
        }
    }

    private func endMove(translation: CGSize, at point: CGPoint) {
        defer { moveOriginalPoints = nil }
        guard let original = moveOriginalPoints, let index = selectedAnnotationIndex else { return }
        let distance = hypot(translation.width, translation.height)
        if distance < 2 {
            annotations[index].points = original
            return
        }
        // Register the move as one undoable step.
        var moved = annotations
        moved[index].points = original.map {
            CGPoint(x: $0.x + translation.width, y: $0.y + translation.height)
        }
        annotations[index].points = original
        commit(moved)
    }

    private func hitTest(_ point: CGPoint) -> Annotation? {
        let slop = max(12, imagePixelSize.width / 150)
        return annotations.reversed().first {
            $0.bounds.insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    private func makeAnnotation(tool: AnnotationTool, at point: CGPoint) -> Annotation {
        Annotation(tool: tool,
                   points: [point, point],
                   color: currentColor,
                   lineWidth: lineWidth,
                   fontSize: fontSizeForImage())
    }

    private func placePointAnnotation(tool: AnnotationTool, at point: CGPoint) {
        var annotation = Annotation(tool: tool,
                                    points: [point],
                                    color: currentColor,
                                    lineWidth: lineWidth,
                                    fontSize: fontSizeForImage())
        if tool == .text {
            annotation.text = "Text"
        }
        if tool == .counter {
            annotation.number = (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
        }
        commit(annotations + [annotation])
        selectedAnnotationID = annotation.id
    }

    /// Scale text with image resolution so it stays readable on Retina captures.
    private func fontSizeForImage() -> Double {
        max(24, imagePixelSize.width / 50)
    }

    // MARK: - Mutations, undo, persistence

    private func commit(_ newValue: [Annotation]) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations = newValue
        persist()
    }

    func updateSelectedText(_ text: String) {
        guard let index = selectedAnnotationIndex else { return }
        annotations[index].text = text
        persist()
    }

    func deleteSelected() {
        guard let index = selectedAnnotationIndex else { return }
        var next = annotations
        next.remove(at: index)
        selectedAnnotationID = nil
        commit(next)
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        selectedAnnotationID = nil
        commit([])
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedAnnotationID = nil
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedAnnotationID = nil
        persist()
    }

    private func persist() {
        do {
            try saveAnnotationsUseCase.execute(annotations, for: screenshot)
        } catch {
            statusMessage = "Could not save annotations: \(error.localizedDescription)"
        }
    }

    // MARK: - OCR

    func copyRecognizedText() async {
        statusMessage = "Recognizing text…"
        do {
            let text = try await recognizeTextUseCase.execute(imageURL: screenshot.imageURL)
            if text.isEmpty {
                statusMessage = "No text found in this screenshot."
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                statusMessage = "Copied \(text.count) characters of recognized text."
            }
        } catch {
            statusMessage = "OCR failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Flatten, export, share

    /// Burns annotations into pixels. This is the only destructive moment,
    /// and it only ever touches the exported copy.
    func flattenedImage() -> NSImage? {
        guard let image else { return nil }
        let visible = crop ?? fullImageRect
        let renderer = ImageRenderer(content: FlattenedImageView(
            image: image,
            imageSize: imagePixelSize,
            annotations: annotations,
            crop: crop
        ))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: visible.size)
    }

    func copyFlattenedToPasteboard() {
        guard let flattened = flattenedImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([flattened])
        statusMessage = "Copied to clipboard."
    }

    func pinToScreen() {
        guard let flattened = flattenedImage() else { return }
        PinWindowManager.shared.pin(image: flattened)
        statusMessage = "Pinned to screen."
    }

    func exportPNG() {
        guard let flattened = flattenedImage(),
              let tiff = flattened.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            statusMessage = "Export failed."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = screenshot.imageURL
            .deletingPathExtension().lastPathComponent + "-annotated.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
