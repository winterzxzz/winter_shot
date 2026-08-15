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

/// Options for a Screen Studio-style export render. Defaults mirror Screen
/// Studio's recovered defaults: 2× zoom, 1.5× cursor, 10% padding.
struct RecordingExportOptions: Codable, Equatable {
    /// Backdrop behind the shot — same presets as screenshot beautify.
    var background: BackdropStyle = .init(preset: .midnight, padding: 0.10)
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
    /// Longest output edge in pixels; source is downscaled to fit.
    var maxOutputWidth: Double = 1920
}
