import AppKit
import SwiftUI

/// Cross-scene channel: capture flows hand a screenshot to the main window
/// (menu-bar capture, preview thumbnail click, --edit launch argument).
@MainActor
final class SelectionBus: ObservableObject {
    @Published var pending: Screenshot?
}

/// Drives the main window: the captures library in the sidebar and which
/// screenshot the editor is showing.
@MainActor
final class MainViewModel: ObservableObject {
    @Published var screenshots: [Screenshot] = []
    @Published var selected: Screenshot?
    @Published var errorMessage: String?

    private let container: DIContainer

    init(container: DIContainer) {
        self.container = container
    }

    func reload() {
        do {
            screenshots = try container.fetchHistoryUseCase.execute()
            errorMessage = nil
            if let selected, !screenshots.contains(where: { $0.id == selected.id }) {
                self.selected = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ screenshot: Screenshot) {
        if !screenshots.contains(where: { $0.id == screenshot.id }) {
            reload()
        }
        selected = screenshot
    }

    func deselect() {
        selected = nil
    }

    func delete(_ screenshot: Screenshot) {
        do {
            try container.deleteScreenshotUseCase.execute(screenshot)
            screenshots.removeAll { $0.id == screenshot.id }
            if selected?.id == screenshot.id { selected = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capture(mode: CaptureMode) {
        Task {
            do {
                guard let screenshot = try await container.captureScreenshotUseCase.execute(mode: mode) else {
                    return
                }
                reload()
                select(screenshot)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sidebar quick actions

    /// Flattens a capture with its annotations and puts it on the pasteboard.
    func copyFlattened(_ screenshot: Screenshot) {
        guard let image = flattened(screenshot) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func pin(_ screenshot: Screenshot) {
        guard let image = flattened(screenshot) else { return }
        PinWindowManager.shared.pin(image: image)
    }

    func revealInFinder(_ screenshot: Screenshot) {
        NSWorkspace.shared.activateFileViewerSelecting([screenshot.imageURL])
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(container.screenshotRepository.storageDirectory)
    }

    private func flattened(_ screenshot: Screenshot) -> NSImage? {
        guard let image = NSImage(contentsOf: screenshot.imageURL) else { return nil }
        let pixelSize: CGSize
        if let rep = image.representations.first {
            pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            pixelSize = image.size
        }
        let annotations = (try? container.loadAnnotationsUseCase.execute(for: screenshot)) ?? []
        let crop = (try? container.loadCropUseCase.execute(for: screenshot)) ?? nil
        let backdrop = (try? container.loadBackgroundUseCase.execute(for: screenshot)) ?? nil
        let content = FlattenedImageView(
            image: image, imageSize: pixelSize, annotations: annotations,
            crop: crop, background: backdrop ?? .none
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: content.outputSize)
    }
}
