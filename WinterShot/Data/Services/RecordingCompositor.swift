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
        // Screen Studio pads by a ratio of the average dimension.
        let pad = style.isEnabled ? (style.padding * (content.width + content.height) / 2).rounded() : 0
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
        let cursorPose = options.showCursor ? cursorTrack.step(to: t, dt: dt) : nil
        draw(frameImage: frameImage, at: t, visible: visible, cursor: cursorPose, into: context)
    }

    // MARK: - Drawing

    private func draw(frameImage: CGImage,
                      at t: Double,
                      visible: CGRect,
                      cursor: CursorTrack.Pose?,
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
            // Screen Studio shadow: distance 25, angle 90° (down), blur 20,
            // alpha 0.75 — scaled from recording points to output pixels.
            let k = contentRect.width / (events.frameWidth / events.pixelScale)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -25 * k),
                              blur: 30 * k,
                              color: CGColor(gray: 0, alpha: 0.75))
            context.addPath(contentPath)
            context.setFillColor(CGColor(gray: 0, alpha: 0.6))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(contentPath)
        context.clip()

        // Map the camera's visible rect onto the content rect. The decoded
        // image may be a downscaled proxy (preview), so stretch it to the
        // logical frame size the event log speaks in.
        let s = contentRect.width / visible.width
        let drawRect = CGRect(x: contentRect.minX - visible.minX * s,
                              y: contentRect.minY - visible.minY * s,
                              width: events.frameWidth * s,
                              height: events.frameHeight * s)
        context.interpolationQuality = .high
        context.draw(frameImage, in: drawRect)

        if options.clickRipples {
            // Screen Studio circle effect: 150 ms, scale 0.2 → 3.5, alpha
            // keyframed [0, 0.05, 0.8, 1] → [0, 1, 0, 0] at 0.6 strength,
            // light-gray fill, base radius 16 × cursor size.
            for ripple in activeRipples(at: t) {
                let p = CGPoint(x: contentRect.minX + (ripple.center.x - visible.minX) * s,
                                y: contentRect.minY + (ripple.center.y - visible.minY) * s)
                let progress = CGFloat(ripple.age / 0.15)
                let alphaKey: CGFloat
                if progress < 0.05 {
                    alphaKey = progress / 0.05
                } else if progress < 0.8 {
                    alphaKey = 1 - (progress - 0.05) / 0.75
                } else {
                    alphaKey = 0
                }
                let scaleKey = 0.2 + 3.3 * progress
                let radius = 16 * options.cursorScale * events.pixelScale * s * scaleKey
                context.setFillColor(CGColor(srgbRed: 0.867, green: 0.867, blue: 0.867,
                                             alpha: 0.6 * alphaKey))
                context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                               width: radius * 2, height: radius * 2))
            }
        }

        if let cursor {
            let p = CGPoint(x: contentRect.minX + (cursor.position.x - visible.minX) * s,
                            y: contentRect.minY + (cursor.position.y - visible.minY) * s)
            let k = events.pixelScale * options.cursorScale * s * cursor.scale
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
            guard age >= 0, age <= 0.15 else { return nil }
            return Ripple(center: CGPoint(x: click.x, y: click.y), age: age)
        }
    }
}

// MARK: - Springs

/// Damped spring (stiffness/damping/mass), integrated with semi-implicit
/// Euler in 1 ms substeps — the exact integrator Screen Studio uses, with its
/// recovered constants.
struct MotionSpring {
    let stiffness: Double
    let damping: Double
    let mass: Double

    /// Screen zoom/pan.
    static let screenMovement = MotionSpring(stiffness: 200, damping: 40, mass: 2.25)
    /// Cursor movement (default).
    static let mouseMovement = MotionSpring(stiffness: 470, damping: 70, mass: 3)
    /// Cursor movement right after a click (snappier).
    static let mouseAfterClick = MotionSpring(stiffness: 530, damping: 40, mass: 1)
    /// Cursor scale pulse on click.
    static let mouseClick = MotionSpring(stiffness: 700, damping: 30, mass: 1)

    func step(_ value: inout CGFloat, _ velocity: inout CGFloat, toward target: CGFloat, dt: Double) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 0.001)
            let a = (-(Double(value) - Double(target)) * stiffness - Double(velocity) * damping) / mass
            velocity += CGFloat(a * h)
            value += velocity * CGFloat(h)
            remaining -= h
        }
    }
}

// MARK: - Camera

/// Auto-zoom camera: each click opens a zoom window ([t−0.3 s, t+2.5 s],
/// merged when less than 2.5 s apart — Screen Studio's follow-click-groups
/// timing); scale and center chase their targets on the screen-movement
/// spring. Stepped frame by frame in presentation order.
struct CameraRig {
    private let frame: CGSize
    private let zoomLevel: CGFloat
    private let windows: [(start: Double, end: Double)]
    private let clicks: [(t: Double, point: CGPoint)]

    private var scale: CGFloat = 1
    private var scaleVelocity: CGFloat = 0
    private var center: CGPoint
    private var centerVelocity: CGVector = .zero

    private let spring = MotionSpring.screenMovement

    init(frame: CGSize, events: RecordingEventLog, options: RecordingExportOptions) {
        self.frame = frame
        self.zoomLevel = max(1, options.autoZoom ? options.zoomLevel : 1)
        self.center = CGPoint(x: frame.width / 2, y: frame.height / 2)

        let relClicks = events.clicks
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
        self.clicks = relClicks
        self.windows = Self.zoomWindows(events: events)
    }

    /// Screen Studio's auto-zoom timing: a window per click of
    /// [t−0.3 s, t+2.5 s], windows less than 2.5 s apart merged into one — so
    /// pauses while typing or reading don't pump the camera in and out.
    /// Shared with the timeline UI, which draws these as segments.
    static func zoomWindows(events: RecordingEventLog) -> [(start: Double, end: Double)] {
        let times = events.clicks.map { $0.t - events.firstFrameTime }.sorted()
        var merged: [(Double, Double)] = []
        for t in times {
            let start = t - 0.3
            let end = t + 2.5
            if var last = merged.last, start <= last.1 + 2.5 {
                last.1 = max(last.1, end)
                merged[merged.count - 1] = last
            } else {
                merged.append((start, end))
            }
        }
        return merged.map { (start: max(0, $0.0), end: $0.1) }
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

        spring.step(&scale, &scaleVelocity, toward: targetScale, dt: dt)
        spring.step(&center.x, &centerVelocity.dx, toward: targetCenter.x, dt: dt)
        spring.step(&center.y, &centerVelocity.dy, toward: targetCenter.y, dt: dt)
        scale = min(max(scale, 1), zoomLevel == 1 ? 1 : zoomLevel)

        let w = frame.width / scale
        let h = frame.height / scale
        let x = min(max(center.x, w / 2), frame.width - w / 2) - w / 2
        let y = min(max(center.y, h / 2), frame.height - h / 2) - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Cursor

/// Smoothed synthetic cursor, Screen Studio-style: the raw 120 Hz log is
/// interpolated at frame times, then the drawn cursor chases it on the
/// mouse-movement spring (snappier for 175 ms after a click), and the sprite
/// pulses to 0.8× scale for 130 ms on every click.
struct CursorTrack {
    struct Pose {
        var position: CGPoint
        /// Click-pulse scale multiplier (1 at rest, dips toward 0.8 on click).
        var scale: CGFloat
    }

    private let samples: [(t: Double, point: CGPoint)]
    private let clickTimes: [Double]
    private var position: CGPoint?
    private var velocity: CGVector = .zero
    private var pulseScale: CGFloat = 1
    private var pulseVelocity: CGFloat = 0
    private var index = 0

    init(events: RecordingEventLog) {
        samples = events.cursorSamples
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
        clickTimes = events.clicks.map { $0.t - events.firstFrameTime }.sorted()
    }

    mutating func reset() {
        position = nil
        velocity = .zero
        pulseScale = 1
        pulseVelocity = 0
        index = 0
    }

    mutating func step(to t: Double, dt: Double) -> Pose? {
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

        let sinceClick = t - (clickTimes.last(where: { $0 <= t }) ?? -.infinity)

        guard var current = position else {
            position = raw
            return Pose(position: raw, scale: 1)
        }
        let spring = sinceClick <= 0.175 ? MotionSpring.mouseAfterClick : MotionSpring.mouseMovement
        spring.step(&current.x, &velocity.dx, toward: raw.x, dt: dt)
        spring.step(&current.y, &velocity.dy, toward: raw.y, dt: dt)
        position = current

        // Click pulse: chase 0.8 for 130 ms after a mousedown, then recover.
        let pulseTarget: CGFloat = sinceClick <= 0.13 ? 0.8 : 1
        MotionSpring.mouseClick.step(&pulseScale, &pulseVelocity, toward: pulseTarget, dt: dt)

        return Pose(position: current, scale: min(max(pulseScale, 0.6), 1.15))
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
