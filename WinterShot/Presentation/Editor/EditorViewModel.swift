import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drives the annotation editor: tool state, drag lifecycle, undo/redo,
/// sidecar persistence, OCR, pinning, and flattened export.
@MainActor
final class EditorViewModel: ObservableObject {
    let screenshot: Screenshot

    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var selectedTool: AnnotationTool = .arrow
    @Published var currentColor: AnnotationColor = .red
    @Published var lineWidth: Double = 4
    @Published var selectedAnnotationID: Annotation.ID?
    @Published var statusMessage: String?

    let image: NSImage?
    let imagePixelSize: CGSize

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    private let loadAnnotationsUseCase: LoadAnnotationsUseCase
    private let saveAnnotationsUseCase: SaveAnnotationsUseCase
    private let recognizeTextUseCase: RecognizeTextUseCase

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedAnnotationIndex: Int? {
        annotations.firstIndex { $0.id == selectedAnnotationID }
    }

    init(screenshot: Screenshot, container: DIContainer) {
        self.screenshot = screenshot
        self.loadAnnotationsUseCase = container.loadAnnotationsUseCase
        self.saveAnnotationsUseCase = container.saveAnnotationsUseCase
        self.recognizeTextUseCase = container.recognizeTextUseCase

        let nsImage = NSImage(contentsOf: screenshot.imageURL)
        self.image = nsImage
        if let rep = nsImage?.representations.first {
            // Pixel dimensions, not point dimensions — Retina captures are 2x.
            self.imagePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            self.imagePixelSize = nsImage?.size ?? .zero
        }

        self.annotations = (try? loadAnnotationsUseCase.execute(for: screenshot)) ?? []
    }

    // MARK: - Drag lifecycle (all points in image pixel space)

    func dragBegan(at point: CGPoint) {
        guard !selectedTool.isPointTool else { return }
        draft = makeAnnotation(at: point)
    }

    func dragChanged(to point: CGPoint) {
        guard var current = draft else { return }
        if selectedTool.isPathTool {
            current.points.append(point)
        } else {
            current.points = [current.start, point]
        }
        draft = current
    }

    func dragEnded(at point: CGPoint) {
        if selectedTool.isPointTool {
            placePointAnnotation(at: point)
            return
        }
        guard let current = draft else { return }
        draft = nil
        // Ignore accidental micro-drags for shape tools.
        let span = hypot(current.end.x - current.start.x, current.end.y - current.start.y)
        if !selectedTool.isPathTool && span < 4 { return }
        commit(annotations + [current])
        selectedAnnotationID = current.id
    }

    private func makeAnnotation(at point: CGPoint) -> Annotation {
        Annotation(tool: selectedTool,
                   points: [point, point],
                   color: currentColor,
                   lineWidth: lineWidth,
                   fontSize: fontSizeForImage())
    }

    private func placePointAnnotation(at point: CGPoint) {
        var annotation = Annotation(tool: selectedTool,
                                    points: [point],
                                    color: currentColor,
                                    lineWidth: lineWidth,
                                    fontSize: fontSizeForImage())
        if selectedTool == .text {
            annotation.text = "Text"
        }
        if selectedTool == .counter {
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

    func delete(_ annotation: Annotation) {
        commit(annotations.filter { $0.id != annotation.id })
        if selectedAnnotationID == annotation.id { selectedAnnotationID = nil }
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
        let renderer = ImageRenderer(content: FlattenedImageView(
            image: image,
            imageSize: imagePixelSize,
            annotations: annotations
        ))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: imagePixelSize)
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
