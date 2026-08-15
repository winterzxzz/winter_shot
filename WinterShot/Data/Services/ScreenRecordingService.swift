import AppKit
import AVFoundation
import ScreenCaptureKit
import QuartzCore

/// Records the display under the cursor with ScreenCaptureKit and writes an
/// H.264 movie. The system cursor is excluded from the captured pixels; a
/// 120 Hz sampler logs its real position and clicks so the exporter can draw
/// a smooth synthetic cursor and auto-zoom camera afterwards.
@MainActor
final class ScreenRecordingService: ScreenRecorder {
    enum RecordingError: LocalizedError {
        case alreadyRecording
        case notRecording
        case screenCaptureUnavailable
        case displayNotFound
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No recording is in progress."
            case .screenCaptureUnavailable: return "Screen capture is unavailable. Check Screen Recording permission."
            case .displayNotFound: return "Could not find the display to record."
            case .writerFailed(let reason): return "Could not write the recording: \(reason)"
            }
        }
    }

    private(set) var isRecording = false

    private let store: FileScreenshotStore

    // Active session state
    private var stream: SCStream?
    private var sink: FrameSink?
    private var output: StreamOutput?
    private var session: RecordingSession?
    private let sampleQueue = DispatchQueue(label: "com.winterzxzz.WinterShot.recording")

    init(store: FileScreenshotStore) {
        self.store = store
    }

    func start() async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecordingError.screenCaptureUnavailable
        }

        // Record the display under the cursor; fall back to the main display.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound
        }

        // Keep WinterShot's own windows (status item, notch panel) out of the shot.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let scale = screen.backingScaleFactor
        let pixelSize = CGSize(width: (screen.frame.width * scale).rounded(),
                               height: (screen.frame.height * scale).rounded())

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let videoURL = store.newImageURL().deletingPathExtension().appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("incompatible video settings") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "could not start writing")
        }

        let sink = FrameSink(writer: writer, input: input)
        let output = StreamOutput(sink: sink)
        let session = RecordingSession(id: UUID(),
                                       videoURL: videoURL,
                                       screenFrame: screen.frame,
                                       pixelScale: scale,
                                       pixelSize: pixelSize)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)

        self.sink = sink
        self.output = output
        self.session = session
        self.stream = stream

        try await stream.startCapture()
        session.startEventSampling()
        isRecording = true
        NSLog("WinterShot: recording started (%@)", videoURL.lastPathComponent)
    }

    func stop() async throws -> (Recording, RecordingEventLog) {
        guard isRecording, let stream, let sink, let session else {
            throw RecordingError.notRecording
        }
        isRecording = false
        session.stopEventSampling()

        try? await stream.stopCapture()
        self.stream = nil
        self.output = nil

        // Drain the sample queue so no frame is appended after finish.
        await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume() }
        }
        let result = await sink.finish()
        self.sink = nil
        self.session = nil

        guard case let .finished(firstFrameTime, lastFrameTime) = result else {
            try? FileManager.default.removeItem(at: session.videoURL)
            if case let .failed(reason) = result { throw RecordingError.writerFailed(reason) }
            throw RecordingError.writerFailed("no frames were captured")
        }

        let log = session.makeEventLog(firstFrameTime: firstFrameTime)
        let recording = Recording(id: session.id,
                                  videoURL: session.videoURL,
                                  createdAt: session.createdAt,
                                  duration: max(0, lastFrameTime - firstFrameTime),
                                  frameSize: session.pixelSize)
        try session.writeSidecar(log, to: Self.sidecarURL(for: session.videoURL))
        NSLog("WinterShot: recording stopped (%.1fs, %d cursor samples, %d clicks)",
              recording.duration, log.cursorSamples.count, log.clicks.count)
        return (recording, log)
    }

    static func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("wsrec.json")
    }
}

// MARK: - Frame sink

/// Owns the asset writer during capture. Touched only on the stream's sample
/// queue until `finish()`, which the service calls after draining that queue.
private final class FrameSink: @unchecked Sendable {
    enum Result {
        case finished(firstFrameTime: Double, lastFrameTime: Double)
        case failed(String)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    private var firstFrameTime: Double = .nan
    private var lastFrameTime: Double = .nan

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    /// Called on the sample queue for every complete frame.
    func append(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstFrameTime = pts.seconds
        }
        guard input.isReadyForMoreMediaData, writer.status == .writing else { return }
        if input.append(sampleBuffer) {
            lastFrameTime = pts.seconds
        }
    }

    /// Called once, after the sample queue is drained.
    func finish() async -> Result {
        guard sessionStarted else {
            writer.cancelWriting()
            return .failed("no frames were captured")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            return .failed(writer.error?.localizedDescription ?? "unknown error")
        }
        return .finished(firstFrameTime: firstFrameTime, lastFrameTime: lastFrameTime)
    }
}

/// SCStream requires an NSObject output; forwards complete frames to the sink.
private final class StreamOutput: NSObject, SCStreamOutput {
    private let sink: FrameSink

    init(sink: FrameSink) {
        self.sink = sink
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only complete frames carry displayable content.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        sink.append(sampleBuffer)
    }
}

// MARK: - Session

/// Per-recording input-event sampler and metadata. Lives on the main actor.
@MainActor
private final class RecordingSession {
    let id: UUID
    let videoURL: URL
    let createdAt = Date()
    let screenFrame: CGRect
    let pixelScale: CGFloat
    let pixelSize: CGSize

    private var cursorSamples: [CursorSample] = []
    private var clicks: [ClickEvent] = []
    private var samplingTimer: Timer?
    private var clickMonitors: [Any] = []

    init(id: UUID, videoURL: URL, screenFrame: CGRect, pixelScale: CGFloat, pixelSize: CGSize) {
        self.id = id
        self.videoURL = videoURL
        self.screenFrame = screenFrame
        self.pixelScale = pixelScale
        self.pixelSize = pixelSize
    }

    func startEventSampling() {
        // 120 Hz cursor sampling on the main run loop. Positions are converted
        // to video pixels (bottom-left origin) immediately.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }) {
            clickMonitors.append(global)
        }
        clickMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.recordClick() }
            return event
        } as Any)
    }

    func stopEventSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
    }

    private func sampleCursor() {
        let p = videoPoint(from: NSEvent.mouseLocation)
        cursorSamples.append(CursorSample(t: CACurrentMediaTime(), x: p.x, y: p.y))
    }

    private func recordClick() {
        let p = videoPoint(from: NSEvent.mouseLocation)
        clicks.append(ClickEvent(t: CACurrentMediaTime(), x: p.x, y: p.y))
    }

    /// Global AppKit point (bottom-left origin) → video pixel (bottom-left origin).
    private func videoPoint(from global: NSPoint) -> (x: Double, y: Double) {
        let localX = (global.x - screenFrame.minX) * pixelScale
        let localY = (global.y - screenFrame.minY) * pixelScale
        return (Double(localX), Double(localY))
    }

    func makeEventLog(firstFrameTime: Double) -> RecordingEventLog {
        RecordingEventLog(recordingID: id,
                          createdAt: createdAt,
                          firstFrameTime: firstFrameTime,
                          frameWidth: pixelSize.width,
                          frameHeight: pixelSize.height,
                          pixelScale: pixelScale,
                          cursorSamples: cursorSamples,
                          clicks: clicks)
    }

    nonisolated func writeSidecar(_ log: RecordingEventLog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(log).write(to: url, options: .atomic)
    }
}
