import AppKit
import SwiftUI

/// Drives the version badge and update button in the main window header.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubUpdateService.ReleaseInfo)
    }

    @Published var state: State = .idle

    private let service: GitHubUpdateService
    private var hasChecked = false

    init(service: GitHubUpdateService) {
        self.service = service
    }

    var currentVersion: String { service.currentVersion }

    func checkOnce() async {
        guard !hasChecked else { return }
        hasChecked = true
        state = .checking
        guard let release = await service.fetchLatestRelease() else {
            state = .idle // offline or no releases — stay quiet
            return
        }
        state = GitHubUpdateService.isNewer(release.version, than: currentVersion)
            ? .available(release)
            : .upToDate
    }

    /// Opens the release page, where the download lives.
    func update() {
        guard case .available(let release) = state else { return }
        NSWorkspace.shared.open(release.pageURL)
    }
}
