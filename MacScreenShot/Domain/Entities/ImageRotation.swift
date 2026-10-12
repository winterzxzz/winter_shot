import Foundation
import CoreGraphics

/// Non-destructive rotation of a capture, in quarter turns clockwise.
/// Like the crop and the backdrop it lives in the sidecar and is applied at
/// render time, so the original pixels are never rewritten and a rotation
/// stays as reversible as a crop.
enum ImageRotation: Int, Codable, CaseIterable, Identifiable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarters = 270

    var id: Int { rawValue }

    var isIdentity: Bool { self == .none }

    /// Clockwise angle to turn the content by when drawing.
    var degrees: Double { Double(rawValue) }

    /// A quarter turn either way swaps the content's width and height.
    var swapsAxes: Bool { self == .quarter || self == .threeQuarters }

    var inverse: ImageRotation {
        switch self {
        case .none: return .none
        case .quarter: return .threeQuarters
        case .half: return .half
        case .threeQuarters: return .quarter
        }
    }

    func turnedRight() -> ImageRotation {
        ImageRotation(rawValue: (rawValue + 90) % 360) ?? .none
    }

    func turnedLeft() -> ImageRotation {
        ImageRotation(rawValue: (rawValue + 270) % 360) ?? .none
    }

    /// The size `size` occupies once turned.
    func apply(to size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    /// Turns an offset measured from the rotation centre, clockwise, in the
    /// y-down space both the canvas and the export renderer draw in.
    func rotate(_ offset: CGPoint) -> CGPoint {
        switch self {
        case .none: return offset
        case .quarter: return CGPoint(x: -offset.y, y: offset.x)
        case .half: return CGPoint(x: -offset.x, y: -offset.y)
        case .threeQuarters: return CGPoint(x: offset.y, y: -offset.x)
        }
    }

    /// Maps a drawn offset back into unturned image space.
    func unrotate(_ offset: CGPoint) -> CGPoint { inverse.rotate(offset) }

    var label: String { "\(rawValue)°" }
}
