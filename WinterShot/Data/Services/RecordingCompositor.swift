import AppKit
import CoreGraphics
import QuartzCore

/// Shared frame compositor for recordings: gradient backdrop, rounded
/// corners, shadow, auto-zoom camera, smoothed synthetic cursor, and click
/// ripples. Used by both the live preview and the exporter so the preview is
/// exactly what ships.
///
/// Coordinates are video pixels with a bottom-left origin — the native
/// orientation of a CGBitmapContext — matching the event log.
final class RecordingCompositor {
    struct Geometry {
        let outputSize: CGSize
        let contentRect: CGRect
        let pad: CGFloat
        let cornerRadius: CGFloat
    }

    let events: RecordingEventLog
    let options: RecordingExportOptions
    let geometry: Geometry

    private let cursorSprite: CursorSprite
    private var camera: CameraRig
    private var cursorTrack: CursorTrack
    private var lastT: Double = -1

    /// `maxWidth` bounds the longest output edge — pass
    /// `options.maxOutputWidth` for export, something smaller for preview.
    @MainActor
    init(events: RecordingEventLog, options: RecordingExportOptions, maxWidth: CGFloat) {
        self.events = events
        self.options = options
        self.geometry = Self.geometry(events: events, options: options, maxWidth: maxWidth)
        self.cursorSprite = CursorSprite.arrow()
        self.camera = CameraRig(frame: CGSize(width: events.frameWidth, height: events.frameHeight),
                                events: events, options: options)
        self.cursorTrack = CursorTrack(events: events)
    }

    static func geometry(events: RecordingEventLog,
                         options: RecordingExportOptions,
                         maxWidth: CGFloat) -> Geometry {
        let frame = CGSize(width: events.frameWidth, height: events.frameHeight)
        let fit = min(1, maxWidth / max(frame.width, 1))
        let content = CGSize(width: (frame.width * fit).rounded(.down),
                             height: (frame.height * fit).rounded(.down))
        let style = options.background
        let pad = style.isEnabled ? (style.padding * min(content.width, content.height)).rounded() : 0
        let outputSize = CGSize(width: even(content.width + pad * 2),
                                height: even(content.height + pad * 2))
        let radius = style.isEnabled
            ? min(style.cornerRadius * fit, min(content.width, content.height) / 2)
            : 0
        return Geometry(outputSize: outputSize,
                        contentRect: CGRect(x: pad, y: pad, width: content.width, height: content.height),
                        pad: pad,
                        cornerRadius: radius)
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    /// Renders the composed frame for time `t` into `context`, whose pixel
    /// size must equal `geometry.outputSize`. Call with monotonically
    /// increasing `t` for playback; a backward jump (scrub) re-simulates the
    /// camera from the start so the pose is deterministic.
    func render(frame frameImage: CGImage, at t: Double, into context: CGContext) {
        if t < lastT {
            camera.reset()
            cursorTrack.reset()
            var sim = 0.0
            let step = 1.0 / 60.0
            while sim < t {
                _ = camera.step(to: sim, dt: step)
                _ = cursorTrack.step(to: sim, dt: step)
                sim += step
            }
            lastT = max(0, t - step)
        }
        let dt = lastT < 0 ? 1.0 / 60.0 : min(max(t - lastT, 1.0 / 240.0), 0.5)
        lastT = t

        let visible = camera.step(to: t, dt: dt)
        let cursorPos = options.showCursor ? cursorTrack.step(to: t, dt: dt) : nil
        draw(frameImage: frameImage, at: t, visible: visible, cursor: cursorPos, into: context)
    }

    // MARK: - Drawing

    private func draw(frameImage: CGImage,
                      at t: Double,
                      visible: CGRect,
                      cursor: CGPoint?,
                      into context: CGContext) {
        let outputSize = geometry.outputSize
        let contentRect = geometry.contentRect
        let style = options.background
        let pad = geometry.pad

        let colors = style.isEnabled ? style.preset.cgGradientColors : [CGColor(gray: 0, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: (colors.count > 1 ? colors : [colors[0], colors[0]]) as CFArray,
                                     locations: nil) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: outputSize.height),
                                       end: CGPoint(x: outputSize.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        let contentPath = CGPath(roundedRect: contentRect,
                                 cornerWidth: geometry.cornerRadius,
                                 cornerHeight: geometry.cornerRadius,
                                 transform: nil)

        if style.isEnabled, style.shadow, pad > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -pad * 0.12),
                              blur: pad * 0.35,
                              color: CGColor(gray: 0, alpha: 0.45))
            context.addPath(contentPath)
            context.setFillColor(CGColor(gray: 0, alpha: 0.6))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(contentPath)
        context.clip()

        // Map the camera's visible rect onto the content rect.
        let s = contentRect.width / visible.width
        let drawRect = CGRect(x: contentRect.minX - visible.minX * s,
                              y: contentRect.minY - visible.minY * s,
                              width: CGFloat(frameImage.width) * s,
                              height: CGFloat(frameImage.height) * s)
        context.interpolationQuality = .high
        context.draw(frameImage, in: drawRect)

        if options.clickRipples {
            for ripple in activeRipples(at: t) {
                let p = CGPoint(x: contentRect.minX + (ripple.center.x - visible.minX) * s,
                                y: contentRect.minY + (ripple.center.y - visible.minY) * s)
                let progress = CGFloat(ripple.age / 0.45)
                let radius = (10 + 45 * easeOut(progress)) * events.pixelScale * s
                context.setFillColor(CGColor(gray: 1, alpha: 0.35 * (1 - progress)))
                context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                               width: radius * 2, height: radius * 2))
            }
        }

        if let cursor {
            let p = CGPoint(x: contentRect.minX + (cursor.x - visible.minX) * s,
                            y: contentRect.minY + (cursor.y - visible.minY) * s)
            let k = events.pixelScale * options.cursorScale * s
            let w = cursorSprite.size.width * k
            let h = cursorSprite.size.height * k
            // Anchor the hotspot (given from the image's top-left) at p.
            let origin = CGPoint(x: p.x - cursorSprite.hotSpot.x * k,
                                 y: p.y - h + cursorSprite.hotSpot.y * k)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2 * k),
                              blur: 4 * k,
                              color: CGColor(gray: 0, alpha: 0.35))
            context.draw(cursorSprite.image, in: CGRect(origin: origin, size: CGSize(width: w, height: h)))
            context.restoreGState()
        }

        context.restoreGState()
    }

    private struct Ripple {
        let center: CGPoint
        let age: Double
    }

    private func activeRipples(at t: Double) -> [Ripple] {
        events.clicks.compactMap { click in
            let age = t - (click.t - events.firstFrameTime)
            guard age >= 0, age <= 0.45 else { return nil }
            return Ripple(center: CGPoint(x: click.x, y: click.y), age: age)
        }
    }

    private func easeOut(_ x: CGFloat) -> CGFloat {
        1 - (1 - x) * (1 - x)
    }
}

// MARK: - Camera

/// Auto-zoom camera: click bursts open a zoom window; scale and center chase
/// their targets with a critically damped spring — the Screen Studio ease.
/// Stepped frame by frame in presentation order.
struct CameraRig {
    private let frame: CGSize
    private let zoomLevel: CGFloat
    private let windows: [(start: Double, end: Double)]
    private let clicks: [(t: Double, point: CGPoint)]

    private var scale: CGFloat = 1
    private var scaleVelocity: CGFloat = 0
    private var center: CGPoint
    private var centerVelocity: CGVector = .zero

    /// Spring stiffness (k); damping is critical: 2√k.
    private let scaleStiffness: CGFloat = 120
    private let centerStiffness: CGFloat = 80

    init(frame: CGSize, events: RecordingEventLog, options: RecordingExportOptions) {
        self.frame = frame
        self.zoomLevel = max(1, options.autoZoom ? options.zoomLevel : 1)
        self.center = CGPoint(x: frame.width / 2, y: frame.height / 2)

        let relClicks = events.clicks
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
        self.clicks = relClicks

        // Merge clicks less than 1.8 s apart into one zoom window.
        var merged: [(Double, Double)] = []
        for click in relClicks {
            let start = click.t - 0.4
            let end = click.t + 1.6
            if var last = merged.last, start <= last.1 + 0.01 {
                last.1 = max(last.1, end)
                merged[merged.count - 1] = last
            } else {
                merged.append((start, end))
            }
        }
        self.windows = merged.map { (start: $0.0, end: $0.1) }
    }

    mutating func reset() {
        scale = 1
        scaleVelocity = 0
        center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        centerVelocity = .zero
    }

    /// Advances the smoothed camera and returns the visible rect in video pixels.
    mutating func step(to t: Double, dt: Double) -> CGRect {
        var targetScale: CGFloat = 1
        var targetCenter = CGPoint(x: frame.width / 2, y: frame.height / 2)

        if zoomLevel > 1, windows.contains(where: { t >= $0.start && t <= $0.end }) {
            targetScale = zoomLevel
            // Chase the most recent click, looking slightly ahead so the zoom
            // arrives with the click instead of after it.
            if let click = clicks.last(where: { $0.t <= t + 0.4 }) {
                targetCenter = click.point
            }
        }

        // Critically damped spring, integrated in small steps for stability.
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 120.0)
            spring(&scale, &scaleVelocity, toward: targetScale, stiffness: scaleStiffness, dt: h)
            spring(&center.x, &centerVelocity.dx, toward: targetCenter.x, stiffness: centerStiffness, dt: h)
            spring(&center.y, &centerVelocity.dy, toward: targetCenter.y, stiffness: centerStiffness, dt: h)
            remaining -= h
        }
        scale = min(max(scale, 1), zoomLevel == 1 ? 1 : zoomLevel)

        let w = frame.width / scale
        let h = frame.height / scale
        let x = min(max(center.x, w / 2), frame.width - w / 2) - w / 2
        let y = min(max(center.y, h / 2), frame.height - h / 2) - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func spring(_ value: inout CGFloat,
                        _ velocity: inout CGFloat,
                        toward target: CGFloat,
                        stiffness: CGFloat,
                        dt: Double) {
        let damping = 2 * sqrt(stiffness)
        let acceleration = stiffness * (target - value) - damping * velocity
        velocity += acceleration * CGFloat(dt)
        value += velocity * CGFloat(dt)
    }
}

// MARK: - Cursor

/// Interpolates the raw 120 Hz cursor log at frame times, then applies a
/// light exponential smoothing — jitter dies, intent stays.
struct CursorTrack {
    private let samples: [(t: Double, point: CGPoint)]
    private var smoothed: CGPoint?
    private var index = 0

    init(events: RecordingEventLog) {
        samples = events.cursorSamples
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
    }

    mutating func reset() {
        smoothed = nil
        index = 0
    }

    mutating func step(to t: Double, dt: Double) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        while index < samples.count - 1, samples[index + 1].t <= t { index += 1 }
        let raw: CGPoint
        if index < samples.count - 1 {
            let a = samples[index], b = samples[index + 1]
            let span = max(b.t - a.t, .ulpOfOne)
            let f = CGFloat(min(max((t - a.t) / span, 0), 1))
            raw = CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                          y: a.point.y + (b.point.y - a.point.y) * f)
        } else {
            raw = samples[index].point
        }
        guard var current = smoothed else {
            smoothed = raw
            return raw
        }
        let alpha = CGFloat(1 - exp(-dt / 0.05))
        current.x += (raw.x - current.x) * alpha
        current.y += (raw.y - current.y) * alpha
        smoothed = current
        return current
    }
}

/// The synthetic cursor artwork, captured from AppKit on the main actor.
struct CursorSprite {
    let image: CGImage
    /// Size in points and the hotspot measured from the image's top-left.
    let size: CGSize
    let hotSpot: CGPoint

    @MainActor
    static func arrow() -> CursorSprite {
        let cursor = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: cursor.image.size)
        let cgImage = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        return CursorSprite(image: cgImage ?? Self.fallback(),
                            size: cursor.image.size,
                            hotSpot: cursor.hotSpot)
    }

    private static func fallback() -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 24, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 24))
        context.addLine(to: CGPoint(x: 0, y: 4))
        context.addLine(to: CGPoint(x: 14, y: 12))
        context.closePath()
        context.fillPath()
        return context.makeImage()!
    }
}

// MARK: - Preset colors

extension BackgroundPreset {
    /// CGColor mirror of `gradientColors` (Presentation) — keep the RGB values
    /// in sync with BeautifyRenderer.swift.
    var cgGradientColors: [CGColor] {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        switch self {
        case .none: return [CGColor(gray: 0, alpha: 0)]
        case .graphite: return [rgb(0.22, 0.23, 0.27), rgb(0.09, 0.09, 0.12)]
        case .midnight: return [rgb(0.13, 0.16, 0.35), rgb(0.05, 0.05, 0.15)]
        case .ocean: return [rgb(0.15, 0.55, 0.85), rgb(0.10, 0.20, 0.55)]
        case .sunset: return [rgb(0.98, 0.55, 0.35), rgb(0.75, 0.20, 0.55)]
        case .forest: return [rgb(0.20, 0.60, 0.40), rgb(0.05, 0.30, 0.25)]
        case .candy: return [rgb(0.95, 0.60, 0.85), rgb(0.45, 0.35, 0.90)]
        case .snow: return [rgb(0.96, 0.96, 0.98), rgb(0.82, 0.84, 0.90)]
        }
    }
}
