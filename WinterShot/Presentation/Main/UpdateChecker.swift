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
        case updating(String)
    }

    @Published var state: State = .idle

    private let service: GitHubUpdateService
    private let installer = UpdateInstaller()
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

    /// Downloads and installs the update in place, then relaunches. Falls
    /// back to the release page when the release has no asset or the swap
    /// fails (e.g. no write permission to the app's folder).
    func update() {
        guard case .available(let release) = state else { return }
        guard let assetURL = release.assetURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .updating("Downloading…")
        Task {
            do {
                try await installer.installAndRelaunch(assetURL: assetURL) { status in
                    Task { @MainActor in self.state = .updating(status) }
                }
            } catch {
                NSLog("WinterShot: in-app update failed (%@) — opening release page",
                      error.localizedDescription)
                state = .available(release)
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }
}
