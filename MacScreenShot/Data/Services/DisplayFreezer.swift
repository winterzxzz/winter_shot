import AppKit
import ScreenCaptureKit

/// Snapshots every display so selection UIs can run on a frozen frame.
@MainActor
struct DisplayFreezer {
    func freeze(content: SCShareableContent) async throws -> [DisplayBackdrop] {
        var backdrops: [DisplayBackdrop] = []
        for display in content.displays {
            let scale = Self.scale(for: display.displayID)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            backdrops.append(DisplayBackdrop(displayID: display.displayID,
                                             frame: display.frame,
                                             image: image))
        }
        return backdrops
    }

    static func scale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }
}
