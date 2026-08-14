import AppKit
import ScreenCaptureKit

/// A window the user can pick in the frozen-screen selector.
struct PickableWindow: Identifiable, Equatable {
    let id: CGWindowID
    let frame: CGRect      // global CoreGraphics coords (origin top-left, y down)
    let title: String
    let appName: String
}

/// A frozen snapshot of one display, shown behind the picker overlay.
struct DisplayBackdrop {
    let displayID: CGDirectDisplayID
    let frame: CGRect      // global CoreGraphics coords, in points
    let image: CGImage
}

/// UI that presents the frozen-screen picker and returns the chosen window.
/// Implemented in the Presentation layer; injected by the composition root.
@MainActor
protocol WindowPickerUI {
    func pickWindow(windows: [PickableWindow], backdrops: [DisplayBackdrop]) async -> PickableWindow?
}

/// BridgeShot-style window capture: freeze every display, let the user click
/// a window on the frozen frame, then capture that window independently via
/// ScreenCaptureKit — so it comes out clean even when partially covered.
@MainActor
final class WindowCaptureService {
    enum WindowCaptureError: Error {
        case screenCaptureUnavailable
    }

    private let picker: WindowPickerUI

    init(picker: WindowPickerUI) {
        self.picker = picker
    }

    /// Returns nil when the user cancels (Esc or click on empty space).
    func captureWindow() async throws -> CGImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw WindowCaptureError.screenCaptureUnavailable
        }

        let windows = orderedPickableWindows(in: content)
        let backdrops = try await freezeDisplays(in: content)

        guard let picked = await picker.pickWindow(windows: windows, backdrops: backdrops),
              let scWindow = content.windows.first(where: { $0.windowID == picked.id }) else {
            return nil
        }

        let scale = displayScale(forWindowAt: picked.frame)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(scWindow.frame.width * scale)
        configuration.height = Int(scWindow.frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: - Enumeration

    /// Pickable windows in front-to-back order (CGWindowList order), so hover
    /// hit-testing resolves the topmost window under the cursor.
    private func orderedPickableWindows(in content: SCShareableContent) -> [PickableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let orderedIDs = info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }

        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows {
            byID[window.windowID] = window
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [PickableWindow] = []
        for id in orderedIDs {
            guard let window = byID[id],
                  window.windowLayer == 0,
                  window.isOnScreen,
                  window.frame.width >= 60, window.frame.height >= 40,
                  window.owningApplication?.processID != myPID else { continue }
            result.append(PickableWindow(id: id,
                                         frame: window.frame,
                                         title: window.title ?? "",
                                         appName: window.owningApplication?.applicationName ?? ""))
        }
        return result
    }

    // MARK: - Freeze

    private func freezeDisplays(in content: SCShareableContent) async throws -> [DisplayBackdrop] {
        var backdrops: [DisplayBackdrop] = []
        for display in content.displays {
            let scale = displayScale(for: display.displayID)
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

    // MARK: - Display helpers

    private func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func displayScale(forWindowAt frame: CGRect) -> CGFloat {
        let displayID = CGMainDisplayID()
        var found = displayID
        var count: UInt32 = 0
        var candidate: CGDirectDisplayID = 0
        if CGGetDisplaysWithRect(frame, 1, &candidate, &count) == .success, count > 0 {
            found = candidate
        }
        return displayScale(for: found)
    }
}
