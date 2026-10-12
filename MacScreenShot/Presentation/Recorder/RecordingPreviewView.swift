import SwiftUI
import AVFoundation
import Combine
import CoreVideo
import IOSurface

/// Owns the AVPlayer driving the polished preview: play/pause (single pass,
/// no looping) and a published playhead for the transport bar.
@MainActor
final class PreviewTransport: ObservableObject {
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    let duration: Double

    @Published var isPlaying = false
    /// Position shown in the preview. During a hover preview this is the
    /// transient cursor time; otherwise it tracks the committed playhead.
    @Published var time: Double = 0
    /// The committed playhead — where playback resumes and where a hover
    /// preview snaps back to. Moves only on play, commit seeks, or clicks.
    private var headTime: Double = 0
    /// True while the pointer is hovering the timeline (paused preview).
    private var isPreviewing = false
    /// Playback rate for the preview (export is unaffected).
    @Published var speed: Float = 1 {
        didSet { if isPlaying { player.rate = speed } }
    }

    private var timeObserver: Any?
    private var endObserver: Any?
    private var statusObserver: AnyCancellable?

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
        // Stop at the end of the clip; play() rewinds when the playhead is
        // parked there, so the play button doubles as replay.
        player.actionAtItemEnd = .pause
        duration = recording.duration

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] cmTime in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = cmTime.seconds
                // Keep the committed playhead in sync except while a hover
                // preview is temporarily driving the player.
                if !self.isPreviewing { self.headTime = self.time }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Play once: park the playhead at the end and flip the
                // transport to paused so the play button reads as replay.
                self.isPlaying = false
            }
        }
        // Mirror the player's real state so the play/pause button never lies
        // (e.g. if the system pauses playback for us).
        statusObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let playing = status != .paused
                if self.isPlaying != playing { self.isPlaying = playing }
            }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            play()
        }
    }

    func play() {
        isPreviewing = false
        // If we're parked at the very end, start over instead of doing nothing.
        if let item = player.currentItem, item.duration.isNumeric,
           item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            headTime = 0
            time = 0
        }
        player.rate = speed
        isPlaying = true
    }

    private func move(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    /// Commits the playhead to `seconds`. Used by clicks, the transport bar,
    /// and jump-to-mask — this is the position playback resumes from.
    func seek(to seconds: Double) {
        isPreviewing = false
        headTime = seconds
        move(to: seconds)
    }

    /// Screen Studio-style hover preview: while paused, follow the pointer
    /// without disturbing the committed playhead. Ignored during playback.
    func previewSeek(to seconds: Double) {
        guard !isPlaying else { return }
        isPreviewing = true
        move(to: seconds)
    }

    /// Pointer left the timeline: snap the preview back to the committed
    /// playhead. No-op if we weren't previewing.
    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        move(to: headTime)
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
    private var wasAwaitingBackground = false

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
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Render for the vsync this frame will appear on. The link's target
        // timestamp is exact; sampling the clock inside the callback adds
        // dispatch jitter that made the camera freeze and double-step.
        let itemTime = transport.videoOutput.itemTime(forHostTime: link.targetTimestamp)
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
        // Paused and nothing new: keep the last composite — unless a video
        // background is still opening (render through it, plus one extra
        // tick once it settles, so the clip appears without a transport nudge).
        let awaiting = compositor.awaitingBackgroundVideo
        defer { wasAwaitingBackground = awaiting }
        guard newFrame || abs(t - lastRenderedTime) > 1e-4 || awaiting || wasAwaitingBackground else { return }
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
