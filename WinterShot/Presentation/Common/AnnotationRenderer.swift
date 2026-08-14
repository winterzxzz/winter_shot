import SwiftUI

/// Draws annotations into a SwiftUI GraphicsContext in image pixel space.
/// Shared by the live editor canvas and the flattened export renderer so
/// what you see is exactly what ships.
enum AnnotationRenderer {

    static func draw(_ annotation: Annotation, in context: inout GraphicsContext) {
        let color = annotation.color.swiftUIColor
        let style = StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round)

        switch annotation.tool {
        case .arrow:
            drawArrow(annotation, color: color, in: &context)

        case .rectangle:
            context.stroke(Path(annotation.rect), with: .color(color), style: style)

        case .ellipse:
            context.stroke(Path(ellipseIn: annotation.rect), with: .color(color), style: style)

        case .line:
            var path = Path()
            path.move(to: annotation.start)
            path.addLine(to: annotation.end)
            context.stroke(path, with: .color(color), style: style)

        case .freehand:
            context.stroke(smoothPath(annotation.points), with: .color(color), style: style)

        case .highlighter:
            let width = max(annotation.lineWidth * 4, 16)
            let highlightStyle = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            context.stroke(smoothPath(annotation.points),
                           with: .color(color.opacity(0.35)),
                           style: highlightStyle)

        case .text:
            let text = Text(annotation.text.isEmpty ? "Text" : annotation.text)
                .font(.system(size: annotation.fontSize, weight: .semibold))
                .foregroundColor(color)
            context.draw(text, at: annotation.start, anchor: .topLeading)

        case .counter:
            let radius = annotation.fontSize * 0.75
            let circle = CGRect(x: annotation.start.x - radius,
                                y: annotation.start.y - radius,
                                width: radius * 2,
                                height: radius * 2)
            context.fill(Path(ellipseIn: circle), with: .color(color))
            let number = Text("\(annotation.number)")
                .font(.system(size: annotation.fontSize * 0.9, weight: .bold))
                .foregroundColor(.white)
            context.draw(number, at: annotation.start, anchor: .center)

        case .redact:
            context.fill(Path(annotation.rect), with: .color(.black))
        }
    }

    static func drawSelectionOutline(for annotation: Annotation, in context: inout GraphicsContext) {
        let rect = annotation.bounds.insetBy(dx: -8, dy: -8)
        let dashed = StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        context.stroke(Path(rect), with: .color(.accentColor), style: dashed)
    }

    private static func drawArrow(_ annotation: Annotation, color: Color, in context: inout GraphicsContext) {
        let start = annotation.start
        let end = annotation.end
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(annotation.lineWidth * 4, 18)
        let headAngle: CGFloat = .pi / 7

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        context.stroke(shaft, with: .color(color),
                       style: StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round))

        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - headLength * cos(angle - headAngle),
                                 y: end.y - headLength * sin(angle - headAngle)))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - headLength * cos(angle + headAngle),
                                 y: end.y - headLength * sin(angle + headAngle)))
        context.stroke(head, with: .color(color),
                       style: StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round))
    }

    private static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        // Quadratic smoothing through midpoints for a natural freehand look.
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2,
                              y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
