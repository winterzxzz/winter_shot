import AppKit
import CoreGraphics
import ImageIO

/// The Wallpaper backdrop catalogue: the full-size desktop pictures macOS
/// ships locally (most modern ones are download-on-demand stubs, so only a
/// handful exist on any given Mac) plus procedurally rendered packs in the
/// style of Screen Studio's — radial glows, sunsets, pastel meshes, solar
/// gradients — which need no bundled assets and render at any size.
final class WallpaperLibrary {
    struct Wallpaper: Identifiable, Hashable {
        enum Source: Hashable {
            case system(URL)
            case generated(GeneratedDesign)
        }

        let id: String
        let name: String
        let category: String
        let source: Source
    }

    /// A design rendered from a base gradient plus soft radial blobs.
    struct GeneratedDesign: Hashable {
        struct Stop: Hashable {
            let color: RGBAColor
            let location: Double
        }

        struct Blob: Hashable {
            let color: RGBAColor
            /// Centre in unit coordinates (0…1, bottom-left origin).
            let x: Double
            let y: Double
            /// Radius as a fraction of the longer edge.
            let radius: Double
            let alpha: Double
        }

        let stops: [Stop]
        /// Gradient direction in degrees (0 = left→right, 90 = bottom→top).
        let angle: Double
        let blobs: [Blob]
    }

    static let shared = WallpaperLibrary()

    static let systemCategory = "macOS"
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var categories: [String] = []

    private let thumbnailCache = NSCache<NSString, CGImage>()
    private let imageCache = NSCache<NSString, CGImage>()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        var all = Self.generatedWallpapers()
        let system = Self.systemWallpapers()
        all = system + all
        wallpapers = all
        var seen: [String] = []
        for w in all where !seen.contains(w.category) { seen.append(w.category) }
        categories = seen
        imageCache.countLimit = 6
        thumbnailCache.countLimit = 200
    }

    func wallpaper(id: String) -> Wallpaper? {
        wallpapers.first { $0.id == id } ?? wallpapers.first
    }

    func wallpapers(in category: String) -> [Wallpaper] {
        wallpapers.filter { $0.category == category }
    }

    func random(excluding id: String? = nil) -> Wallpaper? {
        wallpapers.filter { $0.id != id }.randomElement() ?? wallpapers.first
    }

    // MARK: Rendering

    /// Full-size image, downsampled so its longer edge is at most `maxPixelSize`.
    func image(for wallpaper: Wallpaper, maxPixelSize: CGFloat) -> CGImage? {
        let key = "\(wallpaper.id)@\(Int(maxPixelSize))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let image: CGImage?
        switch wallpaper.source {
        case .system(let url):
            image = Self.decode(url, maxPixelSize: maxPixelSize)
        case .generated(let design):
            image = Self.render(design, size: CGSize(width: maxPixelSize, height: maxPixelSize * 10 / 16))
        }
        if let image { imageCache.setObject(image, forKey: key) }
        return image
    }

    /// Small preview for pickers (~176 px wide), cached.
    func thumbnail(for wallpaper: Wallpaper) -> CGImage? {
        let key = wallpaper.id as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let image: CGImage?
        switch wallpaper.source {
        case .system(let url):
            // macOS keeps ready-made thumbnails next to the pictures.
            let thumbURL = url.deletingLastPathComponent()
                .appendingPathComponent(".thumbnails")
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("heic")
            image = Self.decode(thumbURL, maxPixelSize: 220) ?? Self.decode(url, maxPixelSize: 220)
        case .generated(let design):
            image = Self.render(design, size: CGSize(width: 176, height: 110))
        }
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }

    /// Decodes an image file downsampled during decode (ImageIO thumbnails),
    /// so 6K HEICs never hit memory at full size.
    static func decode(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func render(_ design: GeneratedDesign, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let colors = design.stops.map { $0.color.cgColor } as CFArray
        let locations = design.stops.map { CGFloat($0.location) }
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            let a = design.angle * .pi / 180
            let dx = cos(a), dy = sin(a)
            // Span the whole canvas along the direction.
            let half = (abs(dx) * w + abs(dy) * h) / 2
            let c = CGPoint(x: w / 2, y: h / 2)
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                                       end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for blob in design.blobs {
            let center = CGPoint(x: blob.x * w, y: blob.y * h)
            let radius = blob.radius * max(w, h)
            let core = blob.color.with(alpha: blob.alpha).cgColor
            let mid = blob.color.with(alpha: blob.alpha * 0.55).cgColor
            let edge = blob.color.with(alpha: 0).cgColor
            guard let g = CGGradient(colorsSpace: colorSpace,
                                     colors: [core, mid, edge] as CFArray,
                                     locations: [0, 0.4, 1]) else { continue }
            context.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius,
                                       options: [])
        }
        return context.makeImage()
    }

    // MARK: Catalogue

    private static func systemWallpapers() -> [Wallpaper] {
        let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return Wallpaper(id: "system:" + name, name: name, category: systemCategory, source: .system(url))
            }
    }

    private static func generatedWallpapers() -> [Wallpaper] {
        func c(_ hex: UInt32) -> RGBAColor {
            RGBAColor(r: Double((hex >> 16) & 0xFF) / 255,
                      g: Double((hex >> 8) & 0xFF) / 255,
                      b: Double(hex & 0xFF) / 255)
        }
        func stops(_ hexes: [UInt32]) -> [GeneratedDesign.Stop] {
            hexes.enumerated().map { i, hex in
                .init(color: c(hex), location: hexes.count > 1 ? Double(i) / Double(hexes.count - 1) : 0)
            }
        }
        func blob(_ hex: UInt32, _ x: Double, _ y: Double, _ r: Double, _ a: Double = 0.9) -> GeneratedDesign.Blob {
            .init(color: c(hex), x: x, y: y, radius: r, alpha: a)
        }
        func design(_ id: String, _ name: String, _ category: String,
                    _ base: [UInt32], angle: Double = 45, blobs: [GeneratedDesign.Blob] = []) -> Wallpaper {
            Wallpaper(id: id, name: name, category: category,
                      source: .generated(.init(stops: stops(base), angle: angle, blobs: blobs)))
        }

        var list: [Wallpaper] = []

        // Radial — a deep base with a bright glow, like macOS's radial set.
        let radial: [(String, String, UInt32, UInt32, UInt32)] = [
            ("radial-blue", "Blue", 0x061437, 0x0E2C8A, 0x4F8BFF),
            ("radial-sky", "Sky", 0x0B2A4A, 0x1F6BB5, 0x8FD3FF),
            ("radial-purple", "Purple", 0x1A0B3D, 0x4A1F9E, 0xB07CFF),
            ("radial-green", "Green", 0x06261C, 0x0F6B4A, 0x5FE3A8),
            ("radial-yellow", "Yellow", 0x3A2A05, 0xB07A12, 0xFFD966),
            ("radial-red", "Red", 0x330A12, 0x9C1F3A, 0xFF7A8C),
            ("radial-teal", "Teal", 0x052A2E, 0x117C86, 0x6FE6EA),
            ("radial-graphite", "Graphite", 0x0C0D12, 0x2A2D38, 0x6C7080),
        ]
        for (id, name, base, mid, glow) in radial {
            list.append(design(id, name, "Radial", [base, mid], angle: 65,
                               blobs: [blob(glow, 0.32, 0.68, 0.7, 0.85), blob(base, 0.85, 0.12, 0.6, 0.6)]))
        }

        // Sunset — warm multi-stop skies.
        list += [
            design("sunset-dusk", "Dusk", "Sunset", [0x2B1055, 0x7A2A8A, 0xF2704E], angle: 90,
                   blobs: [blob(0xFFB56B, 0.5, 0.18, 0.55, 0.8)]),
            design("sunset-peach", "Peach", "Sunset", [0xFF7E5F, 0xFEB47B], angle: 30,
                   blobs: [blob(0xFFE3C0, 0.2, 0.8, 0.5, 0.7)]),
            design("sunset-magenta", "Magenta", "Sunset", [0x3D0B45, 0xC02676, 0xFF7B54], angle: 75,
                   blobs: [blob(0xFFC371, 0.7, 0.2, 0.5, 0.75)]),
            design("sunset-golden", "Golden", "Sunset", [0x5A2E0E, 0xC7671B, 0xF6C453], angle: 90,
                   blobs: [blob(0xFFF1B5, 0.35, 0.3, 0.5, 0.75)]),
            design("sunset-lavender", "Lavender", "Sunset", [0x4B3F72, 0x9C6FB6, 0xF9A8C9], angle: 60,
                   blobs: [blob(0xFFD6E7, 0.75, 0.75, 0.5, 0.7)]),
            design("sunset-ember", "Ember", "Sunset", [0x1B0A0A, 0x7A1E12, 0xF25C05], angle: 90,
                   blobs: [blob(0xFFB347, 0.5, 0.05, 0.6, 0.85)]),
        ]

        // Spring — pastel meshes.
        list += [
            design("spring-meadow", "Meadow", "Spring", [0xD9F7E5, 0xBDE8F5], angle: 40,
                   blobs: [blob(0xFFD6E8, 0.2, 0.75, 0.45, 0.85), blob(0xC9F2C7, 0.8, 0.25, 0.5, 0.8)]),
            design("spring-lilac", "Lilac", "Spring", [0xE8DDF7, 0xD3E6FF], angle: 20,
                   blobs: [blob(0xF7C8E0, 0.75, 0.7, 0.45, 0.85), blob(0xC5D5FF, 0.2, 0.2, 0.5, 0.8)]),
            design("spring-lemon", "Lemon", "Spring", [0xFFF6C7, 0xE2F7D9], angle: 60,
                   blobs: [blob(0xBDE0FE, 0.8, 0.8, 0.5, 0.8), blob(0xFFE29A, 0.15, 0.3, 0.45, 0.8)]),
            design("spring-mint", "Mint", "Spring", [0xCFF5EA, 0xE4F0FF], angle: 100,
                   blobs: [blob(0xA7E9D5, 0.3, 0.7, 0.5, 0.85), blob(0xFAD4E4, 0.85, 0.2, 0.45, 0.75)]),
            design("spring-blossom", "Blossom", "Spring", [0xFDE2E4, 0xE2ECE9], angle: 135,
                   blobs: [blob(0xF9BEC7, 0.65, 0.65, 0.5, 0.85), blob(0xCDE7BE, 0.15, 0.2, 0.45, 0.8)]),
            design("spring-sky", "Sky", "Spring", [0xDCEFFF, 0xF3F8FF], angle: 90,
                   blobs: [blob(0xA6D4FF, 0.3, 0.75, 0.55, 0.85), blob(0xFFF0C4, 0.8, 0.25, 0.4, 0.75)]),
        ]

        // Solar — dark bases with a single big glow.
        list += [
            design("solar-navy", "Navy", "Solar", [0x03081A, 0x0A1F52], angle: 90,
                   blobs: [blob(0xFF9F43, 0.5, 0.05, 0.75, 0.9)]),
            design("solar-violet", "Violet", "Solar", [0x07030F, 0x220A4A], angle: 90,
                   blobs: [blob(0x9D4EDD, 0.5, 0.15, 0.7, 0.9)]),
            design("solar-teal", "Teal", "Solar", [0x02110F, 0x0B3F3A], angle: 90,
                   blobs: [blob(0xB8F26B, 0.5, 0.05, 0.7, 0.85)]),
            design("solar-rose", "Rose", "Solar", [0x120309, 0x4A0E29], angle: 90,
                   blobs: [blob(0xFF5E8A, 0.5, 0.1, 0.7, 0.9)]),
            design("solar-mono", "Mono", "Solar", [0x050505, 0x1C1C1F], angle: 90,
                   blobs: [blob(0xEDEDED, 0.5, 0.05, 0.75, 0.6)]),
            design("solar-aurora", "Aurora", "Solar", [0x020B14, 0x06253A], angle: 90,
                   blobs: [blob(0x3DF0B0, 0.3, 0.2, 0.6, 0.8), blob(0x5B7CFF, 0.8, 0.5, 0.55, 0.7)]),
        ]
        return list
    }
}

extension RGBAColor {
    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func with(alpha: Double) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: alpha)
    }
}
