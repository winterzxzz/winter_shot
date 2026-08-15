import AppKit
import AVFoundation
import CoreGraphics
import VideoToolbox

/// Offline render pipeline that turns a raw recording into a polished video:
/// gradient backdrop with rounded corners and shadow (mirroring the
/// screenshot beautify look), an auto-zoom camera driven by the click log,
/// a smoothed synthetic cursor, and click ripples.
///
/// Coordinates: everything here uses video pixels with a bottom-left origin —
/// the native orientation of a CGBitmapContext — matching the event log.
final class RecordingExporterService: RecordingRenderer {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track."
            case .renderFailed(let reason): return "Export failed: \(reason)"
            }
        }
    }

    func export(recording: Recording,
                events: RecordingEventLog,
                options: RecordingExportOptions,
                to destination: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        // Snapshot the cursor image on the main actor before heavy work.
        let cursor = await MainActor.run { CursorSprite.arrow() }

        let asset = AVURLAsset(url: recording.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let nominalFrameRate = try await track.load(.nominalFrameRate)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ExportError.renderFailed("reader setup") }
        reader.add(readerOutput)

        // Geometry: scale the frame down to fit maxOutputWidth, then pad.
        let frame = CGSize(width: events.frameWidth, height: events.frameHeight)
        let fit = min(1, options.maxOutputWidth / max(frame.width, 1))
        let content = CGSize(width: (frame.width * fit).rounded(.down),
                             height: (frame.height * fit).rounded(.down))
        let style = options.background
        let pad = style.isEnabled ? (style.padding * min(content.width, content.height)).rounded() : 0
        let outputSize = CGSize(width: even(content.width + pad * 2),
                                height: even(content.height + pad * 2))
        let contentRect = CGRect(x: pad, y: pad, width: content.width, height: content.height)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(max(nominalFrameRate, 30)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ])
        guard writer.canAdd(input) else { throw ExportError.renderFailed("writer setup") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.renderFailed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw ExportError.renderFailed(reader.error?.localizedDescription ?? "could not read recording")
        }

        var camera = CameraRig(frame: frame, events: events, options: options)
        var cursorTrack = CursorTrack(events: events)
        var firstPTS: CMTime?
        var lastT = 0.0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstPTS == nil { firstPTS = pts }
            let t = (pts - firstPTS!).seconds
            let dt = max(t - lastT, 1.0 / 120.0)
            lastT = t

            var frameImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &frameImage)
            guard let frameImage else { continue }

            let view = camera.step(to: t, dt: dt)
            let cursorPos = options.showCursor ? cursorTrack.step(to: t, dt: dt) : nil

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.renderFailed("no pixel buffer pool")
            }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { throw ExportError.renderFailed("could not create frame buffer") }

            render(frameImage: frameImage,
                   into: outBuffer,
                   outputSize: outputSize,
                   contentRect: contentRect,
                   visible: view,
                   style: style,
                   pad: pad,
                   cursor: cursorPos.map { ($0, cursor) },
                   ripples: options.clickRipples ? activeRipples(at: t, events: events) : [],
                   cursorScale: options.cursorScale,
                   pixelScale: events.pixelScale)

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard adaptor.append(outBuffer, withPresentationTime: pts - firstPTS!) else {
                throw ExportError.renderFailed(writer.error?.localizedDescription ?? "could not append frame")
            }
            if duration > 0 { progress(min(t / duration, 1)) }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.renderFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.renderFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    private func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    // MARK: - Frame rendering

    private struct Ripple {
        let center: CGPoint
        let age: Double
    }

    private func activeRipples(at t: Double, events: RecordingEventLog) -> [Ripple] {
        events.clicks.compactMap { click in
            let age = t - (click.t - events.firstFrameTime)
            guard age >= 0, age <= 0.45 else { return nil }
            return Ripple(center: CGPoint(x: click.x, y: click.y), age: age)
        }
    }

    private func render(frameImage: CGImage,
                        into buffer: CVPixelBuffer,
                        outputSize: CGSize,
                        contentRect: CGRect,
                        visible: CGRect,
                        style: BackdropStyle,
                        pad: CGFloat,
                        cursor: (position: CGPoint, sprite: CursorSprite)?,
                        ripples: [Ripple],
                        cursorScale: Double,
                        pixelScale: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(outputSize.width),
                                      height: Int(outputSize.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        // Backdrop gradient (top-left → bottom-right in visual terms).
        let colors = style.isEnabled ? style.preset.cgGradientColors : [CGColor(gray: 0, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: colors.count > 1 ? colors as CFArray : [colors[0], colors[0]] as CFArray,
                                     locations: nil) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: outputSize.height),
                                       end: CGPoint(x: outputSize.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        let radius = style.isEnabled ? min(style.cornerRadius, min(contentRect.width, contentRect.height) / 2) : 0
        let contentPath = CGPath(roundedRect: contentRect,
                                 cornerWidth: radius,
                                 cornerHeight: radius,
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

        for ripple in ripples {
            let p = CGPoint(x: contentRect.minX + (ripple.center.x - visible.minX) * s,
                            y: contentRect.minY + (ripple.center.y - visible.minY) * s)
            let progress = CGFloat(ripple.age / 0.45)
            let radius = (10 + 45 * easeOut(progress)) * pixelScale * s
            context.setFillColor(CGColor(gray: 1, alpha: 0.35 * (1 - progress)))
            context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                           width: radius * 2, height: radius * 2))
        }

        if let cursor {
            let p = CGPoint(x: contentRect.minX + (cursor.position.x - visible.minX) * s,
                            y: contentRect.minY + (cursor.position.y - visible.minY) * s)
            let k = pixelScale * cursorScale * s
            let w = cursor.sprite.size.width * k
            let h = cursor.sprite.size.height * k
            // Anchor the hotspot (given from the image's top-left) at p.
            let origin = CGPoint(x: p.x - cursor.sprite.hotSpot.x * k,
                                 y: p.y - h + cursor.sprite.hotSpot.y * k)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2 * k),
                              blur: 4 * k,
                              color: CGColor(gray: 0, alpha: 0.35))
            context.draw(cursor.sprite.image, in: CGRect(origin: origin, size: CGSize(width: w, height: h)))
            context.restoreGState()
        }

        context.restoreGState()
    }

    private func easeOut(_ x: CGFloat) -> CGFloat {
        1 - (1 - x) * (1 - x)
    }
}

// MARK: - Camera

/// Auto-zoom camera: click bursts open a zoom window; scale and center chase
/// their targets with exponential smoothing, which reads as the Screen Studio
/// ease. Stepped frame by frame in presentation order.
private struct CameraRig {
    private let frame: CGSize
    private let zoomLevel: CGFloat
    private let windows: [(start: Double, end: Double)]
    private let clicks: [(t: Double, point: CGPoint)]

    private var scale: CGFloat = 1
    private var center: CGPoint

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

        let scaleAlpha = 1 - exp(-dt / 0.22)
        let centerAlpha = 1 - exp(-dt / 0.28)
        scale += (targetScale - scale) * scaleAlpha
        center.x += (targetCenter.x - center.x) * centerAlpha
        center.y += (targetCenter.y - center.y) * centerAlpha

        let w = frame.width / scale
        let h = frame.height / scale
        let x = min(max(center.x, w / 2), frame.width - w / 2) - w / 2
        let y = min(max(center.y, h / 2), frame.height - h / 2) - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Cursor

/// Interpolates the raw 120 Hz cursor log at frame times, then applies a
/// light exponential smoothing — jitter dies, intent stays.
private struct CursorTrack {
    private let samples: [(t: Double, point: CGPoint)]
    private var smoothed: CGPoint?
    private var index = 0

    init(events: RecordingEventLog) {
        samples = events.cursorSamples
            .map { (t: $0.t - events.firstFrameTime, point: CGPoint(x: $0.x, y: $0.y)) }
            .sorted { $0.t < $1.t }
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
private struct CursorSprite {
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
