import AppKit
import AVFoundation
import CoreGraphics
import VideoToolbox

/// Offline export: decodes the raw recording and renders each frame through
/// the shared RecordingCompositor — the same pipeline the live preview uses —
/// into a polished H.264 movie.
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
        let compositor = await RecordingCompositor(events: events,
                                                   options: options,
                                                   maxWidth: options.maxOutputWidth)
        let outputSize = compositor.geometry.outputSize

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

        var firstPTS: CMTime?

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstPTS == nil { firstPTS = pts }
            let t = (pts - firstPTS!).seconds

            var frameImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &frameImage)
            guard let frameImage else { continue }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.renderFailed("no pixel buffer pool")
            }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { throw ExportError.renderFailed("could not create frame buffer") }

            CVPixelBufferLockBaseAddress(outBuffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(outBuffer),
                                       width: Int(outputSize.width),
                                       height: Int(outputSize.height),
                                       bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(outBuffer),
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                           | CGBitmapInfo.byteOrder32Little.rawValue) {
                compositor.render(frame: frameImage, at: t, into: context)
            }
            CVPixelBufferUnlockBaseAddress(outBuffer, [])

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
}
