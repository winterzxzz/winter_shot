import AppKit
import Combine
import SwiftUI

/// Cross-scene channel: capture flows hand a library item to the main window
/// (menu-bar capture, preview thumbnail click, --edit launch argument).
@MainActor
final class SelectionBus: ObservableObject {
    @Published var pending: CaptureItem?
}

/// Drives the main window: the capture library in the sidebar — screenshots
/// and recordings — and which item the detail pane is showing.
@MainActor
final class MainViewModel: ObservableObject {
    @Published var items: [CaptureItem] = []
    @Published var selected: CaptureItem?
    @Published var errorMessage: String?

    private let container: DIContainer
    private var cancellables = Set<AnyCancellable>()

    init(container: DIContainer) {
        self.container = container
        // A capture from the menu bar, a finished recording or a delete in
        // the notch panel lands here without a manual refresh.
        NotificationCenter.default.publisher(for: .winterShotLibraryChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        do {
            items = try container.fetchLibraryUseCase.execute()
            errorMessage = nil
            if let selected, !items.contains(where: { $0.id == selected.id }) {
                self.selected = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ item: CaptureItem) {
        if !items.contains(where: { $0.id == item.id }) {
            reload()
        }
        selected = item
    }

    func deselect() {
        selected = nil
    }

    func delete(_ item: CaptureItem) {
        do {
            switch item {
            case .screenshot(let screenshot):
                try container.deleteScreenshotUseCase.execute(screenshot)
            case .recording(let recording):
                try container.deleteRecordingUseCase.execute(recording)
            }
            items.removeAll { $0.id == item.id }
            if selected?.id == item.id { selected = nil }
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
                select(.screenshot(screenshot))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sidebar quick actions

    /// Opens a recording in the studio editor window, with its saved edit.
    func openInStudio(_ recording: Recording) {
        RecordingController.shared.open(videoURL: recording.videoURL)
    }

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

    func revealInFinder(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
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
