import CoreGraphics
import Foundation

// The motion model behind recording exports — springs, the auto-zoom camera
// and the smoothed cursor — kept free of any rendering so it can be stepped
// deterministically at a fixed tick rate by the compositor and unit-tested
// in isolation. All positions are video pixels with a bottom-left origin.

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

    func step(_ value: inout Double, _ velocity: inout Double, toward target: Double, dt: Double) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 0.001)
            let a = (-(value - target) * stiffness - velocity * damping) / mass
            velocity += a * h
            value += velocity * h
            remaining -= h
        }
    }
}

// MARK: - Camera

/// Screen Studio's auto-zoom camera.
///
/// Every click opens a zoom range ([t−0.3 s, t+2.5 s], merged when less than
/// 2.5 s apart, clamped away from the end of the recording). Inside a range
/// the camera does not chase the raw cursor: all mouse events in the range
/// are grouped into spatial clusters — a cluster grows while its bounding box
/// still fits in 50 % × 70 % of the zoomed viewport — and the target is the
/// centre of the cluster the cursor is currently in. The camera therefore
/// holds still while you work in one area and glides once you leave it, and
/// because clusters are computed for the whole range it anticipates where
/// the cursor is going.
///
/// The zoom is a scale about an anchor: the target keeps its on-screen spot
/// while the content grows around it (`position = −anchor · frame · (scale − 1)`),
/// with targets near a screen edge snapped fully to that edge. Scale and
/// position each chase their target on the screen-movement spring.
struct CameraRig {
    /// Camera pose in "zoomer space": a source point `p` (video px) lands at
    /// `p · scale + position`, where the visible window is the frame rect.
    struct Pose: Equatable {
        var scale: Double
        var position: CGPoint

        static let rest = Pose(scale: 1, position: .zero)
    }

    private struct ZoomRange {
        let start: Double
        let end: Double
        /// Event clusters in time order: (time of first event, bbox centre).
        let clusters: [(firstTime: Double, center: CGPoint)]
    }

    let frame: CGSize
    let zoomLevel: Double

    private let ranges: [ZoomRange]
    private let spring = MotionSpring.screenMovement

    private(set) var pose = Pose.rest
    /// Pose at the previous tick — the per-frame displacement drives motion blur.
    private(set) var previousPose = Pose.rest
    private var scaleVelocity: Double = 0
    private var positionVelocity = CGVector.zero

    /// Screen Studio's follow-click-groups timing.
    private static let leadIn = 0.3
    private static let holdAfter = 2.5
    private static let mergeGap = 2.5
    private static let ignoreClicksInLast = 1.0
    private static let clampFromEnd = 0.8
    private static let snapToEdgesRatio = 0.25
    private static let clusterFraction = CGSize(width: 0.5, height: 0.7)

    init(frame: CGSize, events: RecordingEventLog, duration: Double, options: RecordingExportOptions) {
        self.frame = frame
        let zoom = options.autoZoom ? max(1, options.zoomLevel) : 1
        self.zoomLevel = zoom
        self.ranges = Self.buildRanges(frame: frame, events: events, duration: duration, zoom: zoom)
    }

    // MARK: Ranges

    /// Auto-zoom windows as (start, end) in seconds from the first frame —
    /// shared with the timeline UI, which draws them as segments.
    static func zoomWindows(events: RecordingEventLog, duration: Double) -> [(start: Double, end: Double)] {
        let times = events.clicks
            .map { $0.t - events.firstFrameTime }
            .filter { $0 < duration - ignoreClicksInLast }
            .sorted()
        var merged: [(Double, Double)] = []
        for t in times {
            let start = max(t - leadIn, 0.001)
            let end = min(t + holdAfter, duration - clampFromEnd)
            guard end > start else { continue }
            if var last = merged.last, start <= last.1 + mergeGap {
                last.1 = max(last.1, end)
                merged[merged.count - 1] = last
            } else {
                merged.append((start, end))
            }
        }
        return merged.map { (start: $0.0, end: $0.1) }
    }

    private static func buildRanges(frame: CGSize,
                                    events: RecordingEventLog,
                                    duration: Double,
                                    zoom: Double) -> [ZoomRange] {
        guard zoom > 1 else { return [] }
        let t0 = events.firstFrameTime
        // All mouse events (moves and clicks) in time order.
        var all: [(t: Double, p: CGPoint)] = events.cursorSamples.map { ($0.t - t0, CGPoint(x: $0.x, y: $0.y)) }
        all += events.clicks.map { ($0.t - t0, CGPoint(x: $0.x, y: $0.y)) }
        all.sort { $0.t < $1.t }
        let area = CGSize(width: frame.width / zoom * clusterFraction.width,
                          height: frame.height / zoom * clusterFraction.height)

        return zoomWindows(events: events, duration: duration).map { window in
            let inRange = all.filter { $0.t >= window.start && $0.t <= window.end }
            return ZoomRange(start: window.start, end: window.end,
                             clusters: cluster(inRange, area: area))
        }
    }

    /// Greedy spatial clustering: an event joins the current cluster while
    /// the cluster's bounding box (including it) still fits in `area`.
    private static func cluster(_ events: [(t: Double, p: CGPoint)],
                                area: CGSize) -> [(firstTime: Double, center: CGPoint)] {
        var result: [(firstTime: Double, center: CGPoint)] = []
        var firstTime = 0.0
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        var open = false
        func close() {
            if open {
                result.append((firstTime, CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)))
            }
        }
        let areaW = Double(area.width), areaH = Double(area.height)
        for e in events {
            let px = Double(e.p.x), py = Double(e.p.y)
            if open,
               max(maxX, px) - min(minX, px) <= areaW,
               max(maxY, py) - min(minY, py) <= areaH {
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
            } else {
                close()
                open = true
                firstTime = e.t
                minX = px; maxX = px
                minY = py; maxY = py
            }
        }
        close()
        return result
    }

    // MARK: Targets

    /// The pose the camera is chasing at time `t`.
    func target(at t: Double) -> Pose {
        guard zoomLevel > 1,
              let range = ranges.first(where: { t >= $0.start && t <= $0.end }),
              let cluster = range.clusters.last(where: { $0.firstTime <= t }) ?? range.clusters.first
        else { return .rest }

        // Normalised anchor, snapped fully to an edge when within
        // `snapToEdgesRatio` (never more than the visible fraction) of it.
        let r = min(Self.snapToEdgesRatio, 1 / zoomLevel)
        func snap(_ v: Double) -> Double {
            min(max((v - r) / (1 - 2 * r), 0), 1)
        }
        let ax = snap(cluster.center.x / frame.width)
        let ay = snap(cluster.center.y / frame.height)
        return Pose(scale: zoomLevel,
                    position: CGPoint(x: -ax * frame.width * (zoomLevel - 1),
                                      y: -ay * frame.height * (zoomLevel - 1)))
    }

    // MARK: Simulation

    /// Puts the camera at rest on its target for `t` (start of a re-simulation).
    mutating func snap(to t: Double) {
        pose = target(at: t)
        previousPose = pose
        scaleVelocity = 0
        positionVelocity = .zero
    }

    /// Advances one tick of `dt` toward the target for `t`.
    mutating func step(to t: Double, dt: Double) {
        previousPose = pose
        let goal = target(at: t)
        var scale = pose.scale
        var x = Double(pose.position.x)
        var y = Double(pose.position.y)
        var vx = Double(positionVelocity.dx)
        var vy = Double(positionVelocity.dy)
        spring.step(&scale, &scaleVelocity, toward: goal.scale, dt: dt)
        spring.step(&x, &vx, toward: Double(goal.position.x), dt: dt)
        spring.step(&y, &vy, toward: Double(goal.position.y), dt: dt)
        positionVelocity = CGVector(dx: vx, dy: vy)

        // Never expose the backdrop through the content: keep the zoomed
        // frame covering the viewport (springs are near-critically damped, so
        // this only trims sub-pixel overshoot).
        scale = max(scale, 1)
        x = min(max(x, -frame.width * (scale - 1)), 0)
        y = min(max(y, -frame.height * (scale - 1)), 0)
        pose = Pose(scale: scale, position: CGPoint(x: x, y: y))
    }
}

// MARK: - Cursor

/// Smoothed synthetic cursor, Screen Studio-style: the raw 120 Hz log is
/// interpolated at tick times, then the drawn cursor chases it on the
/// mouse-movement spring (snappier for 175 ms after a click), the sprite
/// pulses to 0.8× for 130 ms on every click, and it tilts with horizontal
/// velocity.
struct CursorTrack {
    struct Pose: Equatable {
        var position: CGPoint
        /// Click-pulse scale multiplier (1 at rest, dips toward 0.8 on click).
        var scale: Double
        /// Tilt in degrees, positive = clockwise on screen.
        var tilt: Double
    }

    private let samples: [(t: Double, point: CGPoint)]
    private let clickTimes: [Double]
    private let pixelScale: Double

    private(set) var pose: Pose?
    private(set) var previousPose: Pose?
    private var velocity = CGVector.zero
    private var pulseVelocity: Double = 0
    private var tiltVelocity: Double = 0

    /// Screen Studio: rotateZ = clamp((x(t) − x(t−400 ms)) · 0.03 · 0.5, ±20°)
    /// with positions in points.
    private static let tiltWindow = 0.4
    private static let tiltGain = 0.03 * 0.5
    private static let tiltLimit = 20.0

    var isEmpty: Bool { samples.isEmpty }

    init(events: RecordingEventLog) {
        samples = events.cursorSamples
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
        clickTimes = events.clicks.map { $0.t - events.firstFrameTime }.sorted()
        pixelScale = max(events.pixelScale, 1)
    }

    /// Raw (unsmoothed) cursor position at `t`, linearly interpolated.
    func rawPosition(at t: Double) -> CGPoint? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return first.point }
        // Binary search for the last sample at or before t.
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = samples[lo]
        guard lo + 1 < samples.count else { return a.point }
        let b = samples[lo + 1]
        let span = max(b.t - a.t, .ulpOfOne)
        let f = min(max((t - a.t) / span, 0), 1)
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                       y: a.point.y + (b.point.y - a.point.y) * f)
    }

    private func targetTilt(at t: Double, raw: CGPoint) -> Double {
        guard let past = rawPosition(at: t - Self.tiltWindow) else { return 0 }
        let dx = Double(raw.x - past.x) / pixelScale
        return min(max(dx * Self.tiltGain, -Self.tiltLimit), Self.tiltLimit)
    }

    private func sinceClick(_ t: Double) -> Double {
        // Last click at or before t.
        var lo = 0, hi = clickTimes.count - 1
        guard hi >= 0, clickTimes[0] <= t else { return .infinity }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if clickTimes[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return t - clickTimes[lo]
    }

    mutating func snap(to t: Double) {
        guard let raw = rawPosition(at: t) else { pose = nil; previousPose = nil; return }
        pose = Pose(position: raw, scale: 1, tilt: targetTilt(at: t, raw: raw))
        previousPose = pose
        velocity = .zero
        pulseVelocity = 0
        tiltVelocity = 0
    }

    mutating func step(to t: Double, dt: Double) {
        guard let raw = rawPosition(at: t) else { return }
        guard var current = pose else { snap(to: t); return }
        previousPose = current
        let since = sinceClick(t)

        let spring = since <= 0.175 ? MotionSpring.mouseAfterClick : MotionSpring.mouseMovement
        var x = Double(current.position.x), y = Double(current.position.y)
        var vx = Double(velocity.dx), vy = Double(velocity.dy)
        spring.step(&x, &vx, toward: Double(raw.x), dt: dt)
        spring.step(&y, &vy, toward: Double(raw.y), dt: dt)
        velocity = CGVector(dx: vx, dy: vy)
        current.position = CGPoint(x: x, y: y)

        // Click pulse: chase 0.8 for 130 ms after a mousedown, then recover.
        let pulseTarget = since <= 0.13 ? 0.8 : 1.0
        MotionSpring.mouseClick.step(&current.scale, &pulseVelocity, toward: pulseTarget, dt: dt)
        current.scale = min(max(current.scale, 0.6), 1.15)

        MotionSpring.mouseMovement.step(&current.tilt, &tiltVelocity,
                                        toward: targetTilt(at: t, raw: raw), dt: dt)
        pose = current
    }
}
