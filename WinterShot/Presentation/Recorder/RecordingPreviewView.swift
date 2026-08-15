import SwiftUI
import AVFoundation
import VideoToolbox

/// Owns the AVPlayer driving the polished preview: play/pause, looping, and
/// a published playhead for the transport bar.
@MainActor
final class PreviewTransport: ObservableObject {
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    let duration: Double

    @Published var isPlaying = false
    @Published var time: Double = 0

    private var timeObserver: Any?
    private var endObserver: Any?

    init(recording: Recording) {
        let item = AVPlayerItem(url: recording.videoURL)
        // Decode at preview scale — compositing a full 5K frame per tick is
        // what makes the preview stutter, and the preview never shows more
        // than ~1500 px anyway.
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1200)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
                self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self?.player.play()
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
            player.play()
        }
        isPlaying.toggle()
    }

    func play() {
        player.play()
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

final class RecordingPreviewNSView: NSView {
    private let transport: PreviewTransport
    private let events: RecordingEventLog
    private var options: RecordingExportOptions

    private var compositor: RecordingCompositor
    private var bitmap: CGContext?
    private var displayLink: CADisplayLink?
    private var lastFrame: (image: CGImage, t: Double)?

    /// Preview render width — smaller than export for 60 fps CPU compositing.
    private static let previewWidth: CGFloat = 1100

    init(transport: PreviewTransport, events: RecordingEventLog, options: RecordingExportOptions) {
        self.transport = transport
        self.events = events
        self.options = options
        self.compositor = RecordingCompositor(events: events, options: options, maxWidth: Self.previewWidth)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = .clear
        rebuildBitmap()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func apply(options: RecordingExportOptions) {
        guard options != self.options else { return }
        self.options = options
        compositor = RecordingCompositor(events: events, options: options, maxWidth: Self.previewWidth)
        rebuildBitmap()
        // Re-render the frozen frame immediately so paused edits are live too.
        if let lastFrame {
            renderAndDisplay(frame: lastFrame.image, t: lastFrame.t, forceResimulate: true)
        }
    }

    private func rebuildBitmap() {
        let size = compositor.geometry.outputSize
        bitmap = CGContext(data: nil,
                           width: Int(size.width),
                           height: Int(size.height),
                           bitsPerComponent: 8,
                           bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue)
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
        guard transport.videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = transport.videoOutput.copyPixelBuffer(forItemTime: itemTime,
                                                                      itemTimeForDisplay: nil) else { return }
        var frameImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &frameImage)
        guard let frameImage else { return }
        renderAndDisplay(frame: frameImage, t: itemTime.seconds, forceResimulate: false)
    }

    private func renderAndDisplay(frame: CGImage, t: Double, forceResimulate: Bool) {
        guard let bitmap else { return }
        lastFrame = (frame, t)
        if forceResimulate {
            // A tiny backward nudge makes the compositor re-simulate the
            // camera deterministically up to t.
            compositor.render(frame: frame, at: max(0, t - 0.001), into: bitmap)
        }
        compositor.render(frame: frame, at: t, into: bitmap)
        layer?.contents = bitmap.makeImage()
    }
}
