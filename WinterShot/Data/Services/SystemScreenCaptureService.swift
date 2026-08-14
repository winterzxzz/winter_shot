import Foundation

/// Drives the system `screencapture` tool so we get the native selection UI
/// (crosshair, window picker, pixel-accurate Retina output) for free.
final class SystemScreenCaptureService {
    enum CaptureError: Error {
        case launchFailed
    }

    /// Captures into `url`. Returns false when the user cancels (no file written).
    func capture(mode: CaptureMode, to url: URL) async throws -> Bool {
        var arguments: [String]
        switch mode {
        case .area:
            arguments = ["-i"]                 // interactive area selection
        case .window:
            arguments = ["-i", "-W", "-o"]     // window picker, no shadow
        case .fullscreen:
            arguments = []
        }
        arguments.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            throw CaptureError.launchFailed
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        return FileManager.default.fileExists(atPath: url.path)
    }
}
