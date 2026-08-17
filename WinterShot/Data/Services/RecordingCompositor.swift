import AppKit
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Shared frame compositor for recordings: gradient backdrop, rounded
/// corners, shadow, auto-zoom camera, smoothed synthetic cursor, click
/// ripples and motion blur. Used by both the live preview and the exporter
/// so the preview is exactly what ships.
///
/// Rendering is a Core Image graph evaluated on the GPU; the camera and
/// cursor are simulated at a fixed 60 Hz tick that is independent of when
/// source frames arrive — ScreenCaptureKit only delivers frames when the
/// screen changes, so a zoom over a static screen must not wait for pixels.
///
/// Coordinates are video pixels with a bottom-left origin — Core Image's
/// native orientation — matching the event log.
final class RecordingCompositor {
    struct Geometry {
        let outputSize: CGSize
        let contentRect: CGRect
        let pad: CGFloat
        let cornerRadius: CGFloat
    }

    let events: RecordingEventLog
    let options: RecordingExportOptions
    let duration: Double
    let geometry: Geometry

    /// Simulation tick — the export frame rate. The preview steps the same
    /// clock so it shows exactly what the exporter renders.
    static let tickRate = 60.0
    private static let tick = 1.0 / tickRate
    /// How far back a scrub re-simulates from (Screen Studio's influence time).
    private static let influenceTime = 3.5

    private var camera: CameraRig
    private var cursor: CursorTrack
    private var simTime: Double = -1

    private let backdrop: CIImage
    private let mask: CIImage
    private let cursorSprite: CursorSprite
    private let rippleDisc: CIImage
    private static let rippleDiscSize: CGFloat = 128

    /// One Metal-backed context for every compositor; CIContext is
    /// thread-safe and expensive to create.
    static let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "WinterShot.RecordingCompositor",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        options[.useSoftwareRenderer] = false
        return CIContext(options: options)
    }()
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `maxWidth` bounds the longest output edge — pass
    /// `options.maxOutputWidth` for export, something smaller for preview.
    /// Frame size of the raw recording (before the crop).
    private let fullFrame: CGSize
    /// The crop in raw-recording pixels, bottom-left origin.
    private let cropRect: CGRect

    @MainActor
    init(events rawEvents: RecordingEventLog, options: RecordingExportOptions, duration: Double, maxWidth: CGFloat) {
        // Everything downstream — camera, cursor, geometry — works in the
        // cropped frame, so re-express the log there once.
        self.fullFrame = CGSize(width: rawEvents.frameWidth, height: rawEvents.frameHeight)
        self.cropRect = Self.cropRect(for: options, fullFrame: fullFrame)
        let events = rawEvents.cropped(to: cropRect)
        self.events = events
        self.options = options
        self.duration = duration
        self.geometry = Self.geometry(events: rawEvents, options: options, maxWidth: maxWidth)
        let frame = CGSize(width: events.frameWidth, height: events.frameHeight)
        self.camera = CameraRig(frame: frame, events: events, duration: duration, options: options)
        self.cursor = CursorTrack(events: events)
        self.cursorSprite = CursorSprite.arrow()
        self.backdrop = Self.gpuResident(Self.makeBackdrop(geometry: geometry, events: events, options: options))
        self.mask = Self.gpuResident(Self.makeMask(geometry: geometry))
        self.rippleDisc = Self.gpuResident(Self.makeRippleDisc())
    }

    /// Output canvas: the recording fitted into `maxWidth`, padded by a
    /// ratio of its average dimension (Screen Studio's rule), optionally
    /// forced to an aspect ratio by growing the canvas around the content —
    /// then the whole thing is scaled so no edge exceeds `maxWidth`.
    /// The crop of `options` in raw-recording pixels (bottom-left origin),
    /// never smaller than Screen Studio's 200 × 200 pt minimum.
    static func cropRect(for options: RecordingExportOptions, fullFrame: CGSize) -> CGRect {
        var rect = options.crop.pixelRect(in: fullFrame).integral
        let minSide: CGFloat = 200
        if rect.width < minSide { rect.size.width = min(minSide, fullFrame.width) }
        if rect.height < minSide { rect.size.height = min(minSide, fullFrame.height) }
        rect.origin.x = min(max(rect.minX, 0), fullFrame.width - rect.width)
        rect.origin.y = min(max(rect.minY, 0), fullFrame.height - rect.height)
        return rect
    }

    static func geometry(events: RecordingEventLog,
                         options: RecordingExportOptions,
                         maxWidth: CGFloat) -> Geometry {
        let fullFrame = CGSize(width: events.frameWidth, height: events.frameHeight)
        let frame = cropRect(for: options, fullFrame: fullFrame).size
        let bg = options.background
        // Work in recording pixels first.
        var pad = CGFloat(bg.padding) * (frame.width + frame.height) / 2
        var canvas = CGSize(width: frame.width + pad * 2, height: frame.height + pad * 2)
        if let ratio = options.aspect.ratio {
            let current = canvas.width / max(canvas.height, 1)
            if current < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        // Scale everything so the longer edge fits maxWidth (never upscale).
        let scale = min(1, maxWidth / max(max(canvas.width, canvas.height), 1))
        pad *= scale
        let content = CGSize(width: (frame.width * scale).rounded(.down),
                             height: (frame.height * scale).rounded(.down))
        let outputSize = CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
        let origin = CGPoint(x: ((outputSize.width - content.width) / 2).rounded(),
                             y: ((outputSize.height - content.height) / 2).rounded())
        let radius = min(CGFloat(bg.cornerRadius) * scale * CGFloat(events.pixelScale),
                         min(content.width, content.height) / 2)
        return Geometry(outputSize: outputSize,
                        contentRect: CGRect(origin: origin, size: content),
                        pad: pad.rounded(),
                        cornerRadius: max(0, radius))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    // MARK: - Simulation

    /// Steps the camera and cursor up to `t` on the fixed tick. A backward
    /// jump (scrub) or a jump further ahead than the influence window resets
    /// the springs at `t − 3.5 s` and re-simulates from there, so the pose at
    /// any time is deterministic no matter how playback got there.
    private func advance(to t: Double) {
        let t = max(0, t)
        if simTime < 0 || t < simTime - 1e-6 || t - simTime > Self.influenceTime + 1 {
            simTime = max(0, t - Self.influenceTime)
            camera.snap(to: simTime)
            cursor.snap(to: simTime)
        }
        while simTime + Self.tick <= t + 1e-9 {
            simTime += Self.tick
            camera.step(to: simTime, dt: Self.tick)
            cursor.step(to: simTime, dt: Self.tick)
        }
    }

    // MARK: - Rendering

    /// Renders the composed frame for time `t` into `output`, whose pixel
    /// size must equal `geometry.outputSize`.
    func render(frame: CVPixelBuffer, at t: Double, into output: CVPixelBuffer) {
        let image = compose(frame: CIImage(cvPixelBuffer: frame), at: t)
        Self.context.render(image, to: output,
                            bounds: CGRect(origin: .zero, size: geometry.outputSize),
                            colorSpace: Self.colorSpace)
    }

    /// Builds the composed frame for time `t` as a Core Image graph. The
    /// source may be a downscaled proxy (preview): it is stretched to the
    /// logical frame size the event log speaks in.
    func compose(frame source: CIImage, at t: Double) -> CIImage {
        advance(to: t)

        let contentRect = geometry.contentRect
        let frameW = events.frameWidth
        let frameH = events.frameHeight
        let fit = Double(contentRect.width) / frameW
        let cam = camera.pose
        let prev = camera.previousPose
        // Output px per video px, and video px → output px.
        let k = cam.scale * fit
        func out(_ p: CGPoint, pose: CameraRig.Pose = cam) -> CGPoint {
            CGPoint(x: Double(contentRect.minX) + (Double(p.x) * pose.scale + Double(pose.position.x)) * fit,
                    y: Double(contentRect.minY) + (Double(p.y) * pose.scale + Double(pose.position.y)) * fit)
        }

        // Screen: cut the crop out of the (possibly proxy-sized) source so
        // its origin is the crop's origin, apply masks in that space, clamp
        // so blur never samples outside it, then map to output px.
        let proxy = Double(fullFrame.width) / max(Double(source.extent.width), 1)
        let cropProxy = CGRect(x: cropRect.minX / proxy, y: cropRect.minY / proxy,
                               width: cropRect.width / proxy, height: cropRect.height / proxy)
        var screen = source
            .cropped(to: cropProxy)
            .transformed(by: CGAffineTransform(translationX: -cropProxy.minX, y: -cropProxy.minY))
        screen = applyMasks(to: screen, at: t, proxy: proxy)
        let srcScale = frameW / max(Double(cropProxy.width), 1)
        let a = srcScale * k
        let screenTransform = CGAffineTransform(a: a, b: 0, c: 0, d: a,
                                                tx: Double(contentRect.minX) + Double(cam.position.x) * fit,
                                                ty: Double(contentRect.minY) + Double(cam.position.y) * fit)
        var zoomer = screen.clampedToExtent().transformed(by: screenTransform)

        // Camera motion blur from the travel since the last tick — Screen
        // Studio's rule: zoom blur about the anchor when the size change
        // dominates, directional blur along the pan otherwise.
        if options.motionBlur > 0, prev != cam {
            let diag = (frameW * frameW + frameH * frameH).squareRoot() * fit
            let sizeDelta = abs(cam.scale - prev.scale) * diag
            let center = CGPoint(x: frameW / 2, y: frameH / 2)
            let c1 = out(center, pose: prev)
            let c2 = out(center, pose: cam)
            let move = CGVector(dx: c2.x - c1.x, dy: c2.y - c1.y)
            let moveLength = Double(hypot(move.dx, move.dy))
            if sizeDelta > moveLength, sizeDelta >= 1, prev.scale > 0 {
                // The fixed point of the scale between the two poses.
                let ds = prev.scale - cam.scale
                let anchor = abs(ds) > 1e-6
                    ? out(CGPoint(x: Double(cam.position.x - prev.position.x) / ds,
                                  y: Double(cam.position.y - prev.position.y) / ds))
                    : out(center)
                let strength = abs(1 - cam.scale / prev.scale) * options.motionBlur
                // CIZoomBlur streaks ≈ 0.021 × distance × amount, so this
                // amount reproduces each pixel's actual per-frame travel.
                let amount = min(strength * 48, 4)
                if amount > 0.05 {
                    zoomer = zoomer.applyingFilter("CIZoomBlur", parameters: [
                        kCIInputCenterKey: CIVector(x: anchor.x, y: anchor.y),
                        kCIInputAmountKey: amount,
                    ])
                }
            } else if moveLength >= 1 {
                let v = moveLength * options.motionBlur
                if v >= 1 {
                    zoomer = zoomer.applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: min(v / 2, 24),
                        kCIInputAngleKey: atan2(Double(move.dy), Double(move.dx)),
                    ])
                }
            }
        }

        // Click ripples — Screen Studio circle effect: 150 ms, scale
        // 0.2 → 3.5, alpha keyframed [0, 0.05, 0.8, 1] → [0, 1, 0, 0] at 0.6
        // strength, light-gray fill, base radius 16 × cursor size.
        if options.clickRipples {
            for ripple in activeRipples(at: t) {
                let progress = ripple.age / 0.15
                let alphaKey: Double
                if progress < 0.05 {
                    alphaKey = progress / 0.05
                } else if progress < 0.8 {
                    alphaKey = 1 - (progress - 0.05) / 0.75
                } else {
                    alphaKey = 0
                }
                guard alphaKey > 0.001 else { continue }
                let scaleKey = 0.2 + 3.3 * progress
                let radius = 16 * options.cursorScale * events.pixelScale * k * scaleKey
                let c = out(ripple.center)
                let s = radius * 2 / Double(Self.rippleDiscSize)
                let transform = CGAffineTransform(translationX: -Self.rippleDiscSize / 2, y: -Self.rippleDiscSize / 2)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
                let disc = rippleDisc
                    .transformed(by: transform)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6 * alphaKey),
                    ])
                zoomer = disc.composited(over: zoomer)
            }
        }

        // Cursor: sprite anchored at its hotspot, scaled with the zoom,
        // pulsed and tilted, blurred along its on-screen travel (its own
        // movement plus the camera's).
        if options.showCursor, let pose = cursor.pose {
            let c = out(pose.position)
            let sprite = cursorSprite
            let kc = events.pixelScale * options.cursorScale * k * pose.scale / Double(sprite.pixelsPerPoint)
            let transform = CGAffineTransform(translationX: -sprite.hotSpotPixels.x, y: -sprite.hotSpotPixels.y)
                .concatenating(CGAffineTransform(scaleX: kc, y: kc))
                .concatenating(CGAffineTransform(rotationAngle: -pose.tilt * .pi / 180))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            var image = sprite.image.transformed(by: transform)
            if options.motionBlur > 0, let previous = cursor.previousPose {
                let before = out(previous.position, pose: prev)
                let dx = Double(c.x - before.x), dy = Double(c.y - before.y)
                let d = (dx * dx + dy * dy).squareRoot() * options.motionBlur
                if d > 1.5 {
                    image = image.applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: min(d / 2, 24),
                        kCIInputAngleKey: atan2(dy, dx),
                    ])
                }
            }
            zoomer = image.composited(over: zoomer)
        }

        return zoomer
            .cropped(to: contentRect)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop,
                kCIInputMaskImageKey: mask,
            ])
    }

    // MARK: - Masks

    /// Screen Studio's masks, in cropped-screen space (proxy pixels): a
    /// sensitive-data mask blurs its rounded region (radius 32 pt, corners
    /// 12 pt, active from 200 ms before its start); a highlight mask dims
    /// everything except its region. Both fade over 120 ms.
    private func applyMasks(to screen: CIImage, at t: Double, proxy: Double) -> CIImage {
        let active = options.masks.filter { mask in
            !mask.isDisabled && mask.end > mask.start
                && t >= mask.start - (mask.kind == .sensitiveData ? 0.2 : 0) - 0.12
                && t <= mask.end + 0.12
        }
        guard !active.isEmpty else { return screen }
        let extent = screen.extent
        let pointScale = events.pixelScale / proxy // proxy px per recording point
        var result = screen
        var highlightShapes: [(shape: CIImage, alpha: Double)] = []

        for mask in active {
            let lead = mask.kind == .sensitiveData ? 0.2 : 0
            let fadeIn = min(max((t - (mask.start - lead)) / 0.12 + 1, 0), 1)
            let fadeOut = min(max((mask.end - t) / 0.12 + 1, 0), 1)
            let alpha = min(fadeIn, fadeOut)
            guard alpha > 0.001 else { continue }

            var rect = mask.rect.clamped(minWidth: 0.005, minHeight: 0.005).pixelRect(in: extent.size)
            rect = rect.offsetBy(dx: extent.minX, dy: extent.minY).integral
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let radius = min(12 * pointScale, min(rect.width, rect.height) / 2)
            guard let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])?.outputImage else { continue }

            switch mask.kind {
            case .sensitiveData:
                let blurRadius = max(1, mask.blur * pointScale)
                let blurred = screen.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                    .cropped(to: rect)
                let region = blurred
                    .applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: shape,
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                    ])
                result = region.composited(over: result)
            case .highlight:
                highlightShapes.append((shape, alpha * mask.highlightOpacity))
            }
        }

        if !highlightShapes.isEmpty {
            // One dim layer with a hole per highlight mask.
            var holes = highlightShapes[0].shape
            for extra in highlightShapes.dropFirst() {
                holes = extra.shape.applyingFilter("CIMaximumCompositing", parameters: [
                    kCIInputBackgroundImageKey: holes,
                ])
            }
            let opacity = highlightShapes.map(\.alpha).max() ?? 0
            let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: opacity)).cropped(to: extent)
            // Source-out keeps the dim only where the hole shapes are transparent.
            let dimWithHoles = dim.applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: holes,
            ])
            result = dimWithHoles.composited(over: result)
        }
        return result
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

    // MARK: - Static layers

    /// Bakes an image into an IOSurface-backed pixel buffer once, so Core
    /// Image binds it as a GPU texture on every frame instead of re-uploading
    /// CGImage bytes each time (which dominated the per-frame cost).
    static func gpuResident(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard !extent.isEmpty, extent.width < 16384, extent.height < 16384 else { return image }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height),
                            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return image }
        context.render(image, to: buffer, bounds: extent, colorSpace: colorSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// The backdrop — wallpaper, gradient, solid color or custom image, with
    /// optional blur — plus the content's drop shadow, drawn once per
    /// geometry: nothing behind the content ever moves.
    private static func makeBackdrop(geometry: Geometry,
                                     events: RecordingEventLog,
                                     options: RecordingExportOptions) -> CIImage {
        let size = geometry.outputSize
        let bg = options.background
        let contentRect = geometry.contentRect
        let bounds = CGRect(origin: .zero, size: size)
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        }

        // Base layer.
        var picture: CGImage?
        switch bg.kind {
        case .wallpaper:
            if let wallpaper = WallpaperLibrary.shared.wallpaper(id: bg.wallpaperID) {
                picture = WallpaperLibrary.shared.image(for: wallpaper, maxPixelSize: max(size.width, size.height))
            }
        case .image:
            if let path = bg.imagePath {
                picture = WallpaperLibrary.decode(URL(fileURLWithPath: path), maxPixelSize: max(size.width, size.height))
            }
        case .gradient, .color:
            break
        }
        if let picture {
            var image = CIImage(cgImage: picture)
            // Aspect-fill the canvas.
            let scale = max(size.width / image.extent.width, size.height / image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2 - image.extent.minX,
                                                            y: (size.height - image.extent.height) / 2 - image.extent.minY))
            if bg.blur > 0.001 {
                let radius = bg.blur * 0.03 * Double(max(size.width, size.height))
                image = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            }
            if let rendered = self.context.createCGImage(image.cropped(to: bounds), from: bounds,
                                                         format: .BGRA8, colorSpace: colorSpace) {
                context.draw(rendered, in: bounds)
            }
        } else if bg.kind == .gradient || bg.kind == .wallpaper || bg.kind == .image {
            // Gradient (or a missing picture) — top-left → bottom-right.
            let stops = bg.gradient.isEmpty ? GradientPreset.all[0].colors : bg.gradient
            let colors = (stops.count > 1 ? stops : [stops[0], stops[0]]).map { $0.cgColor }
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) {
                context.drawLinearGradient(gradient,
                                           start: CGPoint(x: 0, y: size.height),
                                           end: CGPoint(x: size.width, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else {
            context.setFillColor(bg.color.cgColor)
            context.fill(bounds)
        }

        // Screen Studio shadow: distance 25, angle 90° (down), blur 20 —
        // scaled from recording points to output pixels, alpha 0.75 × intensity.
        if bg.shadow > 0.001, bg.hasVisibleBackdrop {
            let k = contentRect.width / (events.frameWidth / events.pixelScale)
            let path = CGPath(roundedRect: contentRect,
                              cornerWidth: geometry.cornerRadius,
                              cornerHeight: geometry.cornerRadius,
                              transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -25 * k),
                              blur: 30 * k,
                              color: CGColor(gray: 0, alpha: 0.75 * bg.shadow))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 0.6))
            context.fillPath()
            context.restoreGState()
        }
        guard let image = context.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        }
        return CIImage(cgImage: image)
    }

    /// White rounded content rect on black — the blend mask that clips the
    /// screen to its corners.
    private static func makeMask(geometry: Geometry) -> CIImage {
        let size = geometry.outputSize
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: size))
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: geometry.contentRect,
                               cornerWidth: geometry.cornerRadius,
                               cornerHeight: geometry.cornerRadius,
                               transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: size))
        }
        return CIImage(cgImage: image)
    }

    /// Light-gray disc used for click ripples, alpha-scaled per frame.
    private static func makeRippleDisc() -> CIImage {
        let n = Int(rippleDiscSize)
        guard let context = CGContext(data: nil, width: n, height: n,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return CIImage.empty()
        }
        context.setFillColor(CGColor(srgbRed: 0.867, green: 0.867, blue: 0.867, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: n - 2, height: n - 2))
        guard let image = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image)
    }
}

/// The synthetic cursor artwork, captured from AppKit on the main actor and
/// pre-rendered with its drop shadow at 4 px per point so it stays crisp when
/// the camera zooms in.
struct CursorSprite {
    let image: CIImage
    /// Bitmap pixels per cursor point.
    let pixelsPerPoint: CGFloat
    /// Hotspot in bitmap pixels from the bitmap's bottom-left corner.
    let hotSpotPixels: CGPoint

    @MainActor
    static func arrow() -> CursorSprite {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot // points, from the image's top-left
        var rect = CGRect(origin: .zero, size: size)
        let cgImage = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? fallback()
        return render(cgImage, size: size, hotSpot: hotSpot)
    }

    private static func render(_ cgImage: CGImage, size: CGSize, hotSpot: CGPoint) -> CursorSprite {
        let scale: CGFloat = 4
        let padPt: CGFloat = 6 // room for the shadow
        let width = Int((size.width + padPt * 2) * scale)
        let height = Int((size.height + padPt * 2) * scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return CursorSprite(image: CIImage(cgImage: cgImage), pixelsPerPoint: 1,
                                hotSpot: hotSpot, imageHeight: CGFloat(cgImage.height))
        }
        context.interpolationQuality = .high
        context.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 3 * scale,
                          color: CGColor(gray: 0, alpha: 0.35))
        let drawRect = CGRect(x: padPt * scale, y: padPt * scale,
                              width: size.width * scale, height: size.height * scale)
        context.draw(cgImage, in: drawRect)
        guard let rendered = context.makeImage() else {
            return CursorSprite(image: CIImage(cgImage: cgImage), pixelsPerPoint: 1,
                                hotSpot: hotSpot, imageHeight: CGFloat(cgImage.height))
        }
        // Hotspot: measured from the top-left in points → bitmap px from bottom-left.
        let hx = (padPt + hotSpot.x) * scale
        let hy = CGFloat(height) - (padPt + hotSpot.y) * scale
        return CursorSprite(image: RecordingCompositor.gpuResident(CIImage(cgImage: rendered)),
                            pixelsPerPoint: scale,
                            hotSpotPixels: CGPoint(x: hx, y: hy))
    }

    private init(image: CIImage, pixelsPerPoint: CGFloat, hotSpotPixels: CGPoint) {
        self.image = image
        self.pixelsPerPoint = pixelsPerPoint
        self.hotSpotPixels = hotSpotPixels
    }

    /// Unpadded fallback when the shadowed bitmap can't be built.
    private init(image: CIImage, pixelsPerPoint: CGFloat, hotSpot: CGPoint, imageHeight: CGFloat) {
        self.image = image
        self.pixelsPerPoint = pixelsPerPoint
        self.hotSpotPixels = CGPoint(x: hotSpot.x, y: imageHeight - hotSpot.y)
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
