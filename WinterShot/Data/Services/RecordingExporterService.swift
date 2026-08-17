import AppKit
import AVFoundation
import CoreImage
import CoreVideo

/// Offline export: decodes the raw recording and renders a constant-rate
/// movie through the shared RecordingCompositor — the same pipeline the live
/// preview uses.
///
/// ScreenCaptureKit only emits a frame when the screen changes, so the raw
/// recording is variable-rate with long gaps while nothing moves. The camera
/// animates through those gaps, so output frames are produced on a fixed
/// clock and each one composites the latest source frame at or before it.
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
        let asset = AVURLAsset(url: recording.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let assetDuration = try await asset.load(.duration).seconds
        let duration = max(recording.duration, assetDuration)

        let compositor = await RecordingCompositor(events: events,
                                                   options: options,
                                                   duration: duration,
                                                   maxWidth: options.maxOutputWidth)
        // A video background decodes on demand; wait for it to open so the
        // first exported frame already shows it.
        await compositor.prepareBackground()
        let outputSize = compositor.geometry.outputSize
        let fps = RecordingCompositor.tickRate
        let timescale: CMTimeScale = 600

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ExportError.renderFailed("reader setup") }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
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

        // Source frames, pulled on demand: `current` is the newest frame at
        // or before the output time, `pending` the next one not yet due.
        guard let firstSample = readerOutput.copyNextSampleBuffer(),
              let firstBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            writer.cancelWriting()
            throw ExportError.renderFailed(reader.error?.localizedDescription ?? "the recording has no frames")
        }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstSample)
        var current: CVPixelBuffer = firstBuffer
        var pending: (buffer: CVPixelBuffer, t: Double)? = nil
        func pullNext() {
            pending = nil
            while let sample = readerOutput.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t = (CMSampleBufferGetPresentationTimeStamp(sample) - firstPTS).seconds
                pending = (buffer, t)
                return
            }
        }
        pullNext()

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw ExportError.renderFailed("no pixel buffer pool")
        }

        let frameCount = max(1, Int((duration * fps).rounded(.up)))
        for n in 0..<frameCount {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            let t = Double(n) / fps
            while let next = pending, next.t <= t + 1e-6 {
                current = next.buffer
                pullNext()
            }

            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else {
                writer.cancelWriting()
                throw ExportError.renderFailed("could not create frame buffer")
            }
            compositor.render(frame: current, at: t, into: outBuffer)

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let pts = CMTime(value: CMTimeValue((t * Double(timescale)).rounded()), timescale: timescale)
            guard adaptor.append(outBuffer, withPresentationTime: pts) else {
                let reason = writer.error?.localizedDescription ?? "could not append frame"
                writer.cancelWriting()
                throw ExportError.renderFailed(reason)
            }
            if n % 6 == 0 { progress(min(t / max(duration, 0.001), 1)) }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.renderFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        reader.cancelReading()
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.renderFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }
}
