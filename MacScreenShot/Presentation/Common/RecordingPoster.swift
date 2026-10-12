import AVFoundation
import CoreGraphics
import Foundation

/// A recording's poster frame and length, for library cards and the detail
/// pane. Decoded off the main thread and cached per file, so scrolling the
/// library or reopening the notch panel doesn't touch the video again.
struct RecordingPoster {
    let image: CGImage?
    /// Seconds; 0 when the asset could not be read.
    let duration: Double

    static func load(for url: URL, maxSize: CGSize = CGSize(width: 480, height: 320)) async -> RecordingPoster {
        let key = cacheKey(for: url, maxSize: maxSize)
        if let cached = cache.object(forKey: key) {
            return cached.poster
        }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let duration = seconds.isFinite ? max(0, seconds) : 0

        // The nearest keyframe a little way in; the tolerances are left wide
        // so the still comes back without decoding a run of frames.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        let image = try? await generator.image(at: time).image

        let poster = RecordingPoster(image: image, duration: duration)
        cache.setObject(Box(poster), forKey: key)
        return poster
    }

    /// `0:14`, or `1:02:03` past an hour.
    static func label(seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private final class Box {
        let poster: RecordingPoster
        init(_ poster: RecordingPoster) { self.poster = poster }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 200
        return cache
    }()

    private static func cacheKey(for url: URL, maxSize: CGSize) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)|\(Int(maxSize.width))x\(Int(maxSize.height))" as NSString
    }
}
