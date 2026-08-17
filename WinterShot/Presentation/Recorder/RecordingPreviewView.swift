import SwiftUI
import AVFoundation
import CoreVideo
import IOSurface

/// Owns the AVPlayer driving the polished preview: play/pause, looping, and
/// a published playhead for the transport bar.
@MainActor
final class PreviewTransport: ObservableObject {
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    let duration: Double

    @Published var isPlaying = false
    @Published var time: Double = 0
    /// Playback rate for the preview (export is unaffected).
    @Published var speed: Float = 1 {
        didSet { if isPlaying { player.rate = speed } }
    }

    private var timeObserver: Any?
    private var endObserver: Any?

    init(recording: Recording) {
        let item = AVPlayerItem(url: recording.videoURL)
        // Bound the decode size on 5K/6K displays; the compositor samples the
        // decoded frame on the GPU, so this only trades sharpness at 2× zoom
        // against decoder bandwidth.
        item.preferredMaximumResolution = CGSize(width: 3200, height: 2000)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        duration = recording.duration

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] cmTime in
            MainActor.assumeIsolated { self?.time = cmTime.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.rate = self.speed
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.rate = speed
        }
        isPlaying.toggle()
    }

    func play() {
        player.rate = speed
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }
}

/// Live polished preview: pulls decoded frames from the player's video output
/// on a display link and runs them through the same RecordingCompositor the
/// exporter uses — what you see is exactly what ships.
struct CompositedPreview: NSViewRepresentable {
    let transport: PreviewTransport
    let events: RecordingEventLog
    let options: RecordingExportOptions

    func makeNSView(context: Context) -> RecordingPreviewNSView {
        RecordingPreviewNSView(transport: transport, events: events, options: options)
    }

    func updateNSView(_ nsView: RecordingPreviewNSView, context: Context) {
        nsView.apply(options: options)
    }
}

/// Composites on every display refresh — not just when the player decodes a
/// new frame — so the camera keeps gliding across the long static stretches
/// of a ScreenCaptureKit recording. Frames are rendered by Core Image on the
/// GPU into IOSurface-backed buffers that the layer displays directly.
final class RecordingPreviewNSView: NSView {
    private let transport: PreviewTransport
    private let events: RecordingEventLog
    private var options: RecordingExportOptions

    private var compositor: RecordingCompositor
    private var displayLink: CADisplayLink?
    private var lastFrame: CVPixelBuffer?
    private var lastRenderedTime: Double = -1

    /// Triple-buffered render targets: the layer shows one while the next is
    /// drawn.
    private var targets: [CVPixelBuffer] = []
    private var targetIndex = 0

    /// Preview render width — enough for a Retina canvas without decoding
    /// more than needed.
    private static let previewWidth: CGFloat = 1600

    init(transport: PreviewTransport, events: RecordingEventLog, options: RecordingExportOptions) {
        self.transport = transport
        self.events = events
        self.options = options
        self.compositor = RecordingCompositor(events: events, options: options,
                                              duration: transport.duration,
                                              maxWidth: Self.previewWidth)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = .clear
        rebuildTargets()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func apply(options: RecordingExportOptions) {
        guard options != self.options else { return }
        self.options = options
        // A fresh compositor re-simulates the camera up to the current time,
        // so paused edits are live too.
        compositor = RecordingCompositor(events: events, options: options,
                                         duration: transport.duration,
                                         maxWidth: Self.previewWidth)
        rebuildTargets()
        if let lastFrame, lastRenderedTime >= 0 {
            renderAndDisplay(frame: lastFrame, t: lastRenderedTime)
        }
    }

    private func rebuildTargets() {
        let size = compositor.geometry.outputSize
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        targets = (0..<3).compactMap { _ in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
            return buffer
        }
        targetIndex = 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let itemTime = transport.videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, itemTime.seconds.isFinite else { return }
        var newFrame = false
        if transport.videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = transport.videoOutput.copyPixelBuffer(forItemTime: itemTime,
                                                                   itemTimeForDisplay: nil) {
            lastFrame = pixelBuffer
            newFrame = true
        }
        guard let frame = lastFrame else { return }
        let t = itemTime.seconds
        // Paused and nothing new: keep the last composite.
        guard newFrame || abs(t - lastRenderedTime) > 1e-4 else { return }
        renderAndDisplay(frame: frame, t: t)
    }

    private func renderAndDisplay(frame: CVPixelBuffer, t: Double) {
        guard !targets.isEmpty else { return }
        targetIndex = (targetIndex + 1) % targets.count
        let target = targets[targetIndex]
        compositor.render(frame: frame, at: t, into: target)
        lastRenderedTime = t
        if let surface = CVPixelBufferGetIOSurface(target)?.takeUnretainedValue() {
            layer?.contents = surface
        }
    }
}
