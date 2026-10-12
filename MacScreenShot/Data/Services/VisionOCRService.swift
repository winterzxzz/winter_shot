import Foundation
import Vision
import AppKit

/// On-device OCR using Apple Vision. Nothing leaves the machine.
final class VisionOCRService: OCRService {
    enum OCRError: Error {
        case unreadableImage
    }

    func recognizeText(in imageURL: URL, region: CGRect?) async throws -> String {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let original = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.unreadableImage
        }
        // Vision misreads small text; upscaling a small capture (a cropped
        // dialog, a phone-sized shot) to ~1500 px on its long edge makes it
        // read cleanly. The region of interest is normalized, so it is
        // unaffected by the scale.
        let cgImage = Self.upscaledIfSmall(original)

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision returns observations in reading order per block; sort
                // top-to-bottom, then left-to-right, so multi-column layouts
                // don't interleave (Vision's y axis points up).
                let sorted = observations.sorted { a, b in
                    let ay = a.boundingBox.midY, by = b.boundingBox.midY
                    if abs(ay - by) > min(a.boundingBox.height, b.boundingBox.height) * 0.5 { return ay > by }
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            if let region {
                // Image pixels (top-left origin) → Vision's normalized,
                // bottom-left-origin region of interest.
                let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
                let clamped = region.intersection(CGRect(x: 0, y: 0, width: w, height: h))
                if clamped.width > 1, clamped.height > 1 {
                    request.regionOfInterest = CGRect(x: clamped.minX / w,
                                                      y: 1 - clamped.maxY / h,
                                                      width: clamped.width / w,
                                                      height: clamped.height / h)
                }
            }

            let handler = VNImageRequestHandler(cgImage: cgImage)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func upscaledIfSmall(_ image: CGImage, target: CGFloat = 1500, maxScale: CGFloat = 3) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        let scale = min(maxScale, (target / max(longEdge, 1)).rounded(.up))
        guard scale > 1 else { return image }
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
