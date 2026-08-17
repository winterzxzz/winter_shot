import Foundation

/// A finished screen recording on disk. The video file is immutable; the
/// input-event log lives in a sidecar next to it (non-destructive by design —
/// zoom, cursor, and backdrop are applied only on export).
struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    let videoURL: URL
    let createdAt: Date
    /// Duration in seconds.
    let duration: Double
    /// Size of a video frame in pixels.
    let frameSize: CGSize

    var filename: String { videoURL.lastPathComponent }
}

/// One sampled cursor position. Times are in seconds on the host clock
/// (`CACurrentMediaTime`), the same clock stamped on the video frames, so the
/// exporter can align events to frames by subtracting `firstFrameTime`.
/// Positions are in video pixels with a bottom-left origin.
struct CursorSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

/// A mouse click (left button down) at a moment in time, in video pixels
/// with a bottom-left origin.
struct ClickEvent: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

/// Sidecar document recorded alongside the raw video: everything the export
/// renderer needs to synthesize a smooth cursor and auto-zoom camera.
struct RecordingEventLog: Codable {
    var recordingID: UUID
    var createdAt: Date
    /// Host-clock time of the first video frame; event times are absolute on
    /// the same clock.
    var firstFrameTime: Double
    /// Video frame size in pixels.
    var frameWidth: Double
    var frameHeight: Double
    /// Display backing scale at record time (points → pixels).
    var pixelScale: Double
    var cursorSamples: [CursorSample]
    var clicks: [ClickEvent]
}

/// sRGB color with alpha, 0…1 components — Codable so option presets and
/// `--export-options` JSON can carry colors.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
}

/// What is painted behind the recording.
enum RecordingBackgroundKind: String, Codable, CaseIterable, Identifiable {
    case wallpaper, gradient, color, image
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .color: return "Color"
        case .image: return "Image"
        }
    }
}

/// A named two-stop gradient for the Gradient background mode.
struct GradientPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let colors: [RGBAColor]

    static let all: [GradientPreset] = [
        GradientPreset(id: "midnight", name: "Midnight", colors: [.init(r: 0.13, g: 0.16, b: 0.35), .init(r: 0.05, g: 0.05, b: 0.15)]),
        GradientPreset(id: "graphite", name: "Graphite", colors: [.init(r: 0.22, g: 0.23, b: 0.27), .init(r: 0.09, g: 0.09, b: 0.12)]),
        GradientPreset(id: "ocean", name: "Ocean", colors: [.init(r: 0.15, g: 0.55, b: 0.85), .init(r: 0.10, g: 0.20, b: 0.55)]),
        GradientPreset(id: "sunset", name: "Sunset", colors: [.init(r: 0.98, g: 0.55, b: 0.35), .init(r: 0.75, g: 0.20, b: 0.55)]),
        GradientPreset(id: "forest", name: "Forest", colors: [.init(r: 0.20, g: 0.60, b: 0.40), .init(r: 0.05, g: 0.30, b: 0.25)]),
        GradientPreset(id: "candy", name: "Candy", colors: [.init(r: 0.95, g: 0.60, b: 0.85), .init(r: 0.45, g: 0.35, b: 0.90)]),
        GradientPreset(id: "snow", name: "Snow", colors: [.init(r: 0.96, g: 0.96, b: 0.98), .init(r: 0.82, g: 0.84, b: 0.90)]),
        GradientPreset(id: "violet", name: "Violet", colors: [.init(r: 0.30, g: 0.18, b: 0.96), .init(r: 0.62, g: 0.20, b: 0.85)]),
    ]
}

/// The canvas behind a recording: one of four kinds plus the shared
/// padding / corner / shadow / blur controls. Mirrors Screen Studio's
/// Background & Screen panel; the defaults are its defaults (10 % padding,
/// 0.75 shadow, wallpaper backdrop).
struct RecordingBackground: Codable, Equatable {
    var kind: RecordingBackgroundKind = .wallpaper
    /// Identifier in `WallpaperLibrary` (a system desktop picture or a
    /// generated design).
    var wallpaperID: String = "radial-blue"
    /// Two-stop gradient, top-left → bottom-right.
    var gradient: [RGBAColor] = GradientPreset.all[0].colors
    var color: RGBAColor = RGBAColor(r: 0.09, g: 0.10, b: 0.16)
    /// Absolute path of a custom image (kind == .image).
    var imagePath: String? = nil
    /// Blur applied to wallpaper / image backdrops, 0…1.
    var blur: Double = 0
    /// Padding as a ratio of the average content dimension (0.10 = 10 %).
    var padding: Double = 0.10
    /// Corner radius of the recording, in recording points (Screen Studio's
    /// default is 12).
    var cornerRadius: Double = 12
    /// Drop-shadow intensity, 0 (off) … 1.
    var shadow: Double = 0.75

    /// Whether anything of the backdrop can show around the content.
    var hasVisibleBackdrop: Bool { padding > 0.0001 || cornerRadius > 0.5 }
}

/// Output canvas shape — Screen Studio's list.
enum OutputAspect: String, Codable, CaseIterable, Identifiable {
    case auto, wide, square, classic, vertical, tall, portrait
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "Wide"
        case .square: return "Square"
        case .classic: return "Classic"
        case .vertical: return "Vertical"
        case .tall: return "Tall"
        case .portrait: return "Portrait"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Recording + padding"
        case .wide: return "16:9 — YouTube, X, LinkedIn"
        case .square: return "1:1"
        case .classic: return "4:3"
        case .vertical: return "9:16 — TikTok, Reels, Stories"
        case .tall: return "3:4"
        case .portrait: return "4:5 — Instagram and Facebook feeds"
        }
    }

    /// Width ÷ height, nil for auto.
    var ratio: Double? {
        switch self {
        case .auto: return nil
        case .wide: return 16.0 / 9.0
        case .square: return 1
        case .classic: return 4.0 / 3.0
        case .vertical: return 9.0 / 16.0
        case .tall: return 3.0 / 4.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

/// Options for a Screen Studio-style export render. Defaults mirror Screen
/// Studio's recovered defaults: 2× zoom, 1.5× cursor, 10% padding.
struct RecordingExportOptions: Codable, Equatable {
    /// Backdrop behind the shot.
    var background = RecordingBackground()
    /// Output canvas shape.
    var aspect: OutputAspect = .auto
    /// Automatic zoom-in around clicks.
    var autoZoom: Bool = true
    /// Zoom magnification when zoomed in.
    var zoomLevel: Double = 2.0
    /// Draw the synthetic smoothed cursor.
    var showCursor: Bool = true
    /// Cursor size multiplier (1 = natural).
    var cursorScale: Double = 1.5
    /// Show expanding ripple on clicks.
    var clickRipples: Bool = true
    /// Motion blur strength (0 = off, 1 = Screen Studio's default) applied
    /// to camera zooms/pans and cursor movement.
    var motionBlur: Double = 1
    /// Longest output edge in pixels; source is downscaled to fit.
    var maxOutputWidth: Double = 1920
}
