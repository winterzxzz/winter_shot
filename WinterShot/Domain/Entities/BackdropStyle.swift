import Foundation

/// Backdrop presets for background beautify.
enum BackgroundPreset: String, Codable, CaseIterable, Identifiable {
    case none
    case graphite
    case midnight
    case ocean
    case sunset
    case forest
    case candy
    case snow

    var id: String { rawValue }
}

/// Non-destructive "background beautify" settings: pad the shot on a
/// backdrop with rounded corners and a soft shadow — for posts and docs.
/// Stored in the sidecar; never applied to the original pixels.
struct BackdropStyle: Codable, Equatable, Hashable {
    var preset: BackgroundPreset = .none
    /// Padding as a fraction of the smaller content dimension (0–0.2).
    var padding: Double = 0.07
    /// Corner radius of the shot, in image pixels.
    var cornerRadius: Double = 24
    var shadow: Bool = true

    var isEnabled: Bool { preset != .none }

    static let none = BackdropStyle()
}
