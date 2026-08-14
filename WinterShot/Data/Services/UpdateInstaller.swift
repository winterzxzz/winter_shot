import AppKit
import Foundation

/// Installs an update in place: downloads the release asset (.dmg or .zip),
/// extracts the new .app, swaps it over the running bundle, and relaunches.
/// Callers should fall back to the release page when this throws.
final class UpdateInstaller {
    enum InstallError: LocalizedError {
        case downloadFailed
        case extractFailed
        case appNotFoundInArchive
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "The update could not be downloaded."
            case .extractFailed: return "The update archive could not be opened."
            case .appNotFoundInArchive: return "No app was found inside the update."
            case .replaceFailed: return "The app could not be replaced."
            }
        }
    }

    /// Downloads and installs the update, reporting coarse status along the
    /// way, then relaunches the app (this call never returns on success).
    func installAndRelaunch(assetURL: URL, status: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("WinterShotUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        status("Downloading…")
        let (tmp, response) = try await URLSession.shared.download(from: assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: work)
            throw InstallError.downloadFailed
        }
        let archive = work.appendingPathComponent("asset.\(assetURL.pathExtension.lowercased())")
        try fm.moveItem(at: tmp, to: archive)

        status("Installing…")
        let newApp: URL
        do {
            newApp = archive.pathExtension == "dmg"
                ? try await extractFromDMG(archive, into: work)
                : try await extractFromZip(archive, into: work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }

        let currentApp = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app")
        do {
            try fm.moveItem(at: currentApp, to: backup)
        } catch {
            try? fm.removeItem(at: work)
            throw InstallError.replaceFailed
        }
        do {
            try await run("/usr/bin/ditto", [newApp.path, currentApp.path])
        } catch {
            // Put the old app back so the user is never left with nothing.
            try? fm.moveItem(at: backup, to: currentApp)
            try? fm.removeItem(at: work)
            throw InstallError.replaceFailed
        }
        // Downloaded bundles can carry quarantine, which would trigger
        // Gatekeeper translocation on relaunch — strip it from our own app.
        try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", currentApp.path])
        try? fm.removeItem(at: work)

        status("Restarting…")
        await relaunch(currentApp)
    }

    // MARK: - Extraction

    private func extractFromZip(_ archive: URL, into work: URL) async throws -> URL {
        let out = work.appendingPathComponent("unzipped", isDirectory: true)
        do {
            try await run("/usr/bin/ditto", ["-xk", archive.path, out.path])
        } catch {
            throw InstallError.extractFailed
        }
        guard let app = try findApp(in: out) else { throw InstallError.appNotFoundInArchive }
        return app
    }

    private func extractFromDMG(_ archive: URL, into work: URL) async throws -> URL {
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        do {
            try await run("/usr/bin/hdiutil",
                          ["attach", archive.path, "-nobrowse", "-readonly", "-noautoopen",
                           "-mountpoint", mount.path])
        } catch {
            throw InstallError.extractFailed
        }
        defer {
            Task.detached { [mount] in
                try? await self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            }
        }
        guard let mounted = try findApp(in: mount) else { throw InstallError.appNotFoundInArchive }
        // Copy out before detaching so the source stays valid.
        let staged = work.appendingPathComponent("staged.app")
        do {
            try await run("/usr/bin/ditto", [mounted.path, staged.path])
        } catch {
            throw InstallError.extractFailed
        }
        return staged
    }

    private func findApp(in directory: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // One level deep covers zips that wrap the app in a folder.
        for item in items where item.hasDirectoryPath {
            let nested = try FileManager.default.contentsOfDirectory(
                at: item, includingPropertiesForKeys: nil)
            if let app = nested.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    // MARK: - Helpers

    private func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: InstallError.extractFailed)
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    @MainActor
    private func relaunch(_ appURL: URL) {
        // Detached shell survives our exit and reopens the swapped bundle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(appURL.path)\""]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
}
