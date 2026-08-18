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

        // Bitrate tracks the output resolution — a fixed 12 Mbps starves 4K
        // (blocky) and wastes bits on 1080p. ~0.10 bits per pixel-second
        // gives ≈12 Mbps at 1080p60, ≈22 at 1440p60, ≈50 at 4K60.
        let bitRate = Int(min(60_000_000,
                              max(6_000_000, outputSize.width * outputSize.height * fps * 0.10)))

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
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

        // Optional background music, looped to cover the clip and mixed at the
        // chosen volume. Its own audio reader runs after the video frames.
        var audio: (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        if let musicPath = options.backgroundAudioPath {
            audio = try await Self.makeAudioMix(musicPath: musicPath,
                                                volume: options.backgroundAudioVolume,
                                                duration: duration,
                                                writer: writer)
        }

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

        // Feed the looped music on its own queue, concurrently with the video
        // frames below, so both writer inputs advance together.
        let audioPump: Task<Void, Never>? = audio.map { a in
            Task.detached { await Self.pumpAudio(a) }
        }

        let frameCount = max(1, Int((duration * fps).rounded(.up)))
        for n in 0..<frameCount {
            if Task.isCancelled {
                reader.cancelReading()
                audio?.reader.cancelReading()
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

        // The music was fed on its own queue in parallel with the video (the
        // writer stalls the video input if a second track never receives data);
        // wait for it to drain before finishing.
        await audioPump?.value

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.renderFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    /// Drains the looped-music reader into its writer input on a private
    /// queue, returning once the track is fully appended.
    private static func pumpAudio(
        _ audio: (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)
    ) async {
        guard audio.reader.startReading() else {
            audio.input.markAsFinished()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.winterzxzz.wintershot.audiomix")
            audio.input.requestMediaDataWhenReady(on: queue) {
                while audio.input.isReadyForMoreMediaData {
                    guard let sample = audio.output.copyNextSampleBuffer(),
                          audio.input.append(sample) else {
                        audio.input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    /// Builds a reader that yields the music file looped to `duration` at the
    /// given volume, plus an AAC writer input added to `writer`. Returns nil if
    /// the file has no audio track.
    private static func makeAudioMix(musicPath: String,
                                     volume: Double,
                                     duration: Double,
                                     writer: AVAssetWriter) async throws
        -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)? {
        let musicAsset = AVURLAsset(url: URL(fileURLWithPath: musicPath))
        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let musicDuration = try await musicAsset.load(.duration)
        guard musicDuration.seconds > 0.01 else { return nil }

        // Tile the track end to end until it covers the whole recording.
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let target = CMTime(seconds: duration, preferredTimescale: 600)
        var cursor = CMTime.zero
        while cursor < target {
            let remaining = target - cursor
            let chunk = CMTimeMinimum(musicDuration, remaining)
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk),
                                          of: musicTrack, at: cursor)
            cursor = cursor + chunk
        }

        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: compTrack)
        params.setVolume(Float(max(0, min(1, volume))), at: .zero)
        mix.inputParameters = [params]

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [compTrack], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return (reader, output, input)
    }
}
