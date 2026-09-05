import AppKit
import ScreenCaptureKit

/// Test hook behind `--snapshot-windows <dir>`: writes a PNG of every window
/// the app has open, so scripted runs can check the UI without a Screen
/// Recording grant of their own. Captures through ScreenCaptureKit with the
/// app's permission — `WS_SNAPSHOT_METHOD=display` grabs the window's region
/// of the display as composited, the default captures the window alone —
/// and falls back to drawing the view hierarchy (`WS_SNAPSHOT_METHOD=view`).
@MainActor
enum WindowSnapshotter {
    static func writeAll(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 4 && $0.frame.height > 4 }
        let method = ProcessInfo.processInfo.environment["WS_SNAPSHOT_METHOD"] ?? "window"
        var content: SCShareableContent?
        if method != "view" {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                NSLog("WinterShot: shareable content unavailable: %@", error.localizedDescription)
            }
        }
        for (index, window) in windows.enumerated() {
            NSLog("WinterShot: window %d %@ appearance=%@ key=%d",
                  window.windowNumber, NSStringFromRect(window.frame),
                  window.effectiveAppearance.name.rawValue, window.isKeyWindow ? 1 : 0)
            var image: CGImage?
            if let content {
                image = await capture(window, in: content, region: method == "display")
            }
            if image == nil, let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                image = rep.cgImage
            }
            guard let image else {
                NSLog("WinterShot: could not snapshot window %d", window.windowNumber)
                continue
            }
            let name = String(format: "%02d-%dx%d.png", index, Int(window.frame.width), Int(window.frame.height))
            write(image, to: directory.appendingPathComponent(name))
            if method == "view" {
                // Drawing the whole hierarchy skips AppKit-hosted columns and the
                // toolbar; draw the window frame and every SwiftUI host on its own.
                if let frame = window.contentView?.superview {
                    write(drawn(frame), to: directory.appendingPathComponent(String(format: "%02d-frame.png", index)))
                }
                for (part, host) in hostingViews(in: window.contentView).enumerated() where host !== window.contentView {
                    write(drawn(host), to: directory.appendingPathComponent(
                        String(format: "%02d-part%d-%dx%d.png", index, part, Int(host.bounds.width), Int(host.bounds.height))))
                }
            }
        }
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        NSLog("WinterShot: snapshot %@", url.path)
    }

    private static func drawn(_ view: NSView) -> CGImage? {
        guard view.bounds.width > 4, view.bounds.height > 4,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func hostingViews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        var found: [NSView] = []
        if String(describing: type(of: view)).contains("HostingView") { found.append(view) }
        for subview in view.subviews { found += hostingViews(in: subview) }
        return found
    }

    private static func capture(_ window: NSWindow, in content: SCShareableContent, region: Bool) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let filter: SCContentFilter
        if region {
            // The window's rectangle of its display, as the user sees it.
            guard let screen = window.screen,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            // AppKit global (bottom-left origin) → display-local (top-left origin).
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let bounds = CGDisplayBounds(displayID)
            let frame = window.frame
            configuration.sourceRect = CGRect(x: frame.minX - bounds.minX,
                                              y: (primaryHeight - frame.maxY) - bounds.minY,
                                              width: frame.width, height: frame.height)
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                NSLog("WinterShot: window %d is not in the shareable content (%d windows)",
                      window.windowNumber, content.windows.count)
                return nil
            }
            configuration.ignoreShadowsSingleWindow = true
            filter = SCContentFilter(desktopIndependentWindow: target)
        }
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            NSLog("WinterShot: screenshot of window %d failed (%dx%d): %@", window.windowNumber,
                  configuration.width, configuration.height, error.localizedDescription)
            return nil
        }
    }
}
