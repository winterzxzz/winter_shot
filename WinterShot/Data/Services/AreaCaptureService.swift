import AppKit
import ScreenCaptureKit

/// The user's area selection: a rect in display-local points on one backdrop.
struct AreaSelection {
    let backdrop: DisplayBackdrop
    let rect: CGRect
}

/// UI that presents the frozen-screen area selector.
/// Implemented in the Presentation layer; injected by the composition root.
@MainActor
protocol AreaPickerUI {
    func pickArea(backdrops: [DisplayBackdrop]) async -> AreaSelection?
}

/// BridgeShot-style area capture: freeze every display, let the user drag a
/// rect on the frozen frame (with loupe and live coordinates), then crop the
/// selection out of the frozen image — pixel-perfect and immune to the screen
/// changing mid-selection.
@MainActor
final class AreaCaptureService {
    enum AreaCaptureError: Error {
        case screenCaptureUnavailable
    }

    private let picker: AreaPickerUI

    init(picker: AreaPickerUI) {
        self.picker = picker
    }

    /// Returns nil when the user cancels (Esc).
    func captureArea() async throws -> CGImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AreaCaptureError.screenCaptureUnavailable
        }

        let backdrops = try await DisplayFreezer().freeze(content: content)
        guard let selection = await picker.pickArea(backdrops: backdrops) else { return nil }

        let scale = CGFloat(selection.backdrop.image.width) / max(selection.backdrop.frame.width, 1)
        let pixelRect = CGRect(x: selection.rect.origin.x * scale,
                               y: selection.rect.origin.y * scale,
                               width: selection.rect.width * scale,
                               height: selection.rect.height * scale).integral
        return selection.backdrop.image.cropping(to: pixelRect)
    }
}
