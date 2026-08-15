import Foundation

/// The three ways a screenshot can be taken.
enum CaptureMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case area
    case window
    case fullscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        }
    }

    var systemImage: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        }
    }

    /// Number key of the global hotkey (⌘⇧ + this key). Only area capture has
    /// one; the other features are triggered from the menu bar.
    var hotkeyNumber: Character? {
        self == .area ? "4" : nil
    }
}
