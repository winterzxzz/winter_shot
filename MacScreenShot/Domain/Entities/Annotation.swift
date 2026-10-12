import Foundation
import CoreGraphics

/// The nine annotation tools.
enum AnnotationTool: String, Codable, CaseIterable, Identifiable, Hashable {
    case arrow
    case rectangle
    case ellipse
    case line
    case freehand
    case text
    case counter
    case highlighter
    case redact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .freehand: return "Freehand"
        case .text: return "Text"
        case .counter: return "Counter"
        case .highlighter: return "Highlighter"
        case .redact: return "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .highlighter: return "highlighter"
        case .redact: return "eye.slash"
        }
    }

    /// Tools that are placed with a single click instead of a drag.
    var isPointTool: Bool { self == .text || self == .counter }

    /// Tools that collect every point of the drag instead of just start/end.
    var isPathTool: Bool { self == .freehand || self == .highlighter }
}

/// A UI-framework-agnostic RGBA color so the Domain layer stays free of SwiftUI.
struct AnnotationColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let red = AnnotationColor(red: 0.93, green: 0.26, blue: 0.21, alpha: 1)
    static let orange = AnnotationColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)
    static let yellow = AnnotationColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1)
    static let green = AnnotationColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    static let blue = AnnotationColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1)
    static let purple = AnnotationColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
    static let black = AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1, alpha: 1)

    static let presets: [AnnotationColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

/// One annotation on a screenshot. Coordinates are in image pixel space so
/// they stay valid regardless of how the editor window is sized.
struct Annotation: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var text: String = ""
    var number: Int = 1
    var color: AnnotationColor = .red
    var lineWidth: Double = 4
    var fontSize: Double = 28

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    /// Normalized bounding rect between the first and last point.
    var rect: CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
    }

    /// Bounding box of all points, used for selection outlines.
    var bounds: CGRect {
        guard !points.isEmpty else { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
