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
    /// The pointer the app was showing at that moment (`CursorKind` raw
    /// value); nil in logs recorded before types were sampled.
    var kind: String? = nil
}

/// The standard macOS pointers the synthetic cursor can take.
enum CursorKind: String, Codable, CaseIterable, Identifiable {
    case arrow, iBeam, pointingHand, crosshair, openHand, closedHand
    case resizeLeftRight, resizeUpDown, contextualMenu, operationNotAllowed, dragCopy, dragLink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .iBeam: return "Text"
        case .pointingHand: return "Hand"
        case .crosshair: return "Crosshair"
        case .openHand: return "Open hand"
        case .closedHand: return "Grab"
        case .resizeLeftRight: return "Resize ↔"
        case .resizeUpDown: return "Resize ↕"
        case .contextualMenu: return "Menu"
        case .operationNotAllowed: return "Not allowed"
        case .dragCopy: return "Copy"
        case .dragLink: return "Link"
        }
    }
}

/// Pointer coloring. macOS's own set mixes dark pointers (arrow, text…)
/// with light ones (the hands); `light` / `dark` make every pointer light or
/// dark by inverting only the kinds that need it.
enum CursorTint: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "macOS"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension CursorKind {
    /// Whether macOS draws this pointer light-on-dark (the hand cursors).
    var isNativelyLight: Bool {
        switch self {
        case .pointingHand, .openHand, .closedHand: return true
        default: return false
        }
    }

    /// Whether the pointer must be inverted to match `tint`.
    func needsInversion(for tint: CursorTint) -> Bool {
        switch tint {
        case .system: return false
        case .light: return !isNativelyLight
        case .dark: return isNativelyLight
        }
    }

    /// Whether the pointer ends up light under `tint`.
    func isLight(under tint: CursorTint) -> Bool {
        isNativelyLight != needsInversion(for: tint)
    }
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
    /// Length of the video in seconds, so the library can list the take
    /// without opening the file. Written since recordings joined the
    /// history; nil in older logs (the poster loader then reads the asset).
    var duration: Double? = nil
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
    case wallpaper, gradient, color, image, video
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .color: return "Color"
        case .image: return "Image"
        case .video: return "Video"
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
    /// Absolute path of a custom video (kind == .video). It is aspect-filled
    /// like an image, loops when shorter than the recording, and its audio
    /// is never used.
    var videoPath: String? = nil
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

/// A rectangle in unit coordinates of the recording (0…1, top-left origin,
/// as on screen). Used for the crop and for mask bounds.
struct UnitRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
    }

    /// Clamped so it stays inside the unit square with a minimum size.
    func clamped(minWidth: Double = 0.01, minHeight: Double = 0.01) -> UnitRect {
        var r = self
        r.width = min(max(r.width, minWidth), 1)
        r.height = min(max(r.height, minHeight), 1)
        r.x = min(max(r.x, 0), 1 - r.width)
        r.y = min(max(r.y, 0), 1 - r.height)
        return r
    }

    /// The rect in pixels of a frame with a bottom-left origin (video / Core
    /// Image convention).
    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width,
               y: (1 - y - height) * size.height,
               width: width * size.width,
               height: height * size.height)
    }
}

/// What a mask does to the region it covers — Screen Studio's two kinds.
enum RecordingMaskKind: String, Codable, CaseIterable, Identifiable {
    case sensitiveData, highlight
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sensitiveData: return "Sensitive Data"
        case .highlight: return "Highlight"
        }
    }
}

/// A timed region of the (cropped) recording that is blurred (sensitive
/// data) or spotlighted (highlight: everything else is dimmed).
struct RecordingMask: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var kind: RecordingMaskKind = .sensitiveData
    /// Bounds in unit coordinates of the cropped recording.
    var rect: UnitRect
    /// Seconds from the first frame.
    var start: Double
    var end: Double
    /// Blur radius in recording points (Screen Studio: 32).
    var blur: Double = 32
    /// Dim opacity outside a highlight mask (Screen Studio: 0.5).
    var highlightOpacity: Double = 0.5
    var isDisabled: Bool = false

    static let defaultDuration = 3.0
    static let minDuration = 1.0

    var duration: Double { end - start }
}

extension RecordingEventLog {
    /// The log re-expressed inside `rect` (frame pixels, bottom-left origin):
    /// positions shift by the crop origin and the frame becomes the crop.
    func cropped(to rect: CGRect) -> RecordingEventLog {
        let full = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        guard !rect.equalTo(full) else { return self }
        var log = self
        log.frameWidth = Double(rect.width)
        log.frameHeight = Double(rect.height)
        let dx = Double(rect.minX), dy = Double(rect.minY)
        log.cursorSamples = cursorSamples.map { CursorSample(t: $0.t, x: $0.x - dx, y: $0.y - dy) }
        log.clicks = clicks.map { ClickEvent(t: $0.t, x: $0.x - dx, y: $0.y - dy) }
        return log
    }
}

/// Output resolution ceiling. The compositor downscales the shot to fit but
/// never upscales it past its native pixels, so a Retina recording stays
/// sharp. `native` is capped at 4K only to keep exports from ballooning on
/// 5K/6K displays.
enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case native, uhd, qhd, fhd
    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native"
        case .uhd: return "4K"
        case .qhd: return "1440p"
        case .fhd: return "1080p"
        }
    }

    var detail: String {
        switch self {
        case .native: return "Up to 4K — sharpest"
        case .uhd: return "3840 px"
        case .qhd: return "2560 px"
        case .fhd: return "1920 px"
        }
    }

    /// Longest output edge, in pixels.
    var maxOutputWidth: Double {
        switch self {
        case .native, .uhd: return 3840
        case .qhd: return 2560
        case .fhd: return 1920
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
    /// Part of the recording that is shown (non-destructive crop).
    var crop: UnitRect = .full
    /// Blur / highlight regions.
    var masks: [RecordingMask] = []
    /// Automatic zoom-in around clicks.
    var autoZoom: Bool = true
    /// Zoom magnification when zoomed in.
    var zoomLevel: Double = 2.0
    /// Draw the synthetic smoothed cursor.
    var showCursor: Bool = true
    /// Cursor size multiplier (1 = natural).
    var cursorScale: Double = 1.5
    /// Pointer drawn when not following the recording (and the fallback for
    /// recordings without cursor types).
    var cursorType: CursorKind = .arrow
    /// Mirror the pointer the app was showing (I-beam over text, hand over
    /// links, resize arrows…) when the recording captured it.
    var followRecordedCursor: Bool = true
    var cursorTint: CursorTint = .system
    /// Show expanding ripple on clicks.
    var clickRipples: Bool = true
    /// Motion blur strength (0 = off, 1 = Screen Studio's default) applied
    /// to camera zooms/pans and cursor movement.
    var motionBlur: Double = 1
    /// Output resolution ceiling. Optional so exports saved before this
    /// setting existed still decode; nil resolves to `.native`.
    var resolution: ExportResolution? = nil

    /// Longest output edge in pixels; the source is downscaled to fit and
    /// never upscaled past its native size.
    var maxOutputWidth: Double { (resolution ?? .native).maxOutputWidth }
    /// Absolute path of a music track mixed under the export. It loops when
    /// shorter than the recording and is trimmed to length. Nil = no music.
    var backgroundAudioPath: String? = nil
    /// Volume of the background music, 0…1.
    var backgroundAudioVolume: Double = 0.7
}
