import Foundation

/// Checks the GitHub repository's releases for a newer version.
final class GitHubUpdateService {
    static let owner = "winterzxzz"
    static let repo = "winter_shot"

    struct ReleaseInfo: Equatable {
        let version: String   // "0.2.0"
        let tagName: String   // "v0.2.0"
        let pageURL: URL
        let assetURL: URL?    // downloadable .zip, when the release has one
    }

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    /// The running app's version. WINTERSHOT_FAKE_VERSION overrides it for
    /// testing the update flow.
    var currentVersion: String {
        if let fake = ProcessInfo.processInfo.environment["WINTERSHOT_FAKE_VERSION"] {
            return fake
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Latest published release, or nil when none exist / the request fails.
    func fetchLatestRelease() async -> ReleaseInfo? {
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(ReleaseResponse.self, from: data) else {
            return nil
        }

        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        let asset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return ReleaseInfo(version: version,
                           tagName: release.tag_name,
                           pageURL: release.html_url,
                           assetURL: asset?.browser_download_url)
    }

    /// True when `candidate` is a strictly newer semantic version than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        let b = current.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
