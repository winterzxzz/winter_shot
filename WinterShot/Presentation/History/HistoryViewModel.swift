import Foundation

/// State for the screenshot library window.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var screenshots: [Screenshot] = []
    @Published var errorMessage: String?

    private let fetchHistoryUseCase: FetchHistoryUseCase
    private let deleteScreenshotUseCase: DeleteScreenshotUseCase

    init(container: DIContainer) {
        self.fetchHistoryUseCase = container.fetchHistoryUseCase
        self.deleteScreenshotUseCase = container.deleteScreenshotUseCase
    }

    func reload() {
        do {
            screenshots = try fetchHistoryUseCase.execute()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ screenshot: Screenshot) {
        do {
            try deleteScreenshotUseCase.execute(screenshot)
            screenshots.removeAll { $0.id == screenshot.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
