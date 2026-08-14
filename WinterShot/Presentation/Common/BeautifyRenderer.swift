import SwiftUI

extension BackgroundPreset {
    /// Backdrop gradient colors (top-leading to bottom-trailing).
    var gradientColors: [Color] {
        switch self {
        case .none: return [.clear]
        case .graphite: return [Color(red: 0.22, green: 0.23, blue: 0.27), Color(red: 0.09, green: 0.09, blue: 0.12)]
        case .midnight: return [Color(red: 0.13, green: 0.16, blue: 0.35), Color(red: 0.05, green: 0.05, blue: 0.15)]
        case .ocean: return [Color(red: 0.15, green: 0.55, blue: 0.85), Color(red: 0.10, green: 0.20, blue: 0.55)]
        case .sunset: return [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.20, blue: 0.55)]
        case .forest: return [Color(red: 0.20, green: 0.60, blue: 0.40), Color(red: 0.05, green: 0.30, blue: 0.25)]
        case .candy: return [Color(red: 0.95, green: 0.60, blue: 0.85), Color(red: 0.45, green: 0.35, blue: 0.90)]
        case .snow: return [Color(red: 0.96, green: 0.96, blue: 0.98), Color(red: 0.82, green: 0.84, blue: 0.90)]
        }
    }
}

/// Shared "background beautify" geometry and drawing, used by the live
/// editor canvas and the flattened export renderer so the preview is exactly
/// what ships.
enum BeautifyRenderer {

    /// Padding around the content in image pixels for a given style.
    static func padding(for style: BackdropStyle, content: CGSize) -> CGFloat {
        guard style.isEnabled else { return 0 }
        return style.padding * min(content.width, content.height)
    }

    /// Total output size: content plus backdrop padding.
    static func outputSize(visible: CGRect, style: BackdropStyle) -> CGSize {
        let pad = padding(for: style, content: visible.size)
        return CGSize(width: visible.width + pad * 2, height: visible.height + pad * 2)
    }

    /// Draws backdrop + clipped content (image and annotations) into a context
    /// whose (0,0)..outputSize covers the final output, in image pixel scale.
    static func drawContent(in context: inout GraphicsContext,
                            image: NSImage?,
                            imageSize: CGSize,
                            annotations: [Annotation],
                            visible: CGRect,
                            style: BackdropStyle) {
        let pad = padding(for: style, content: visible.size)
        let output = outputSize(visible: visible, style: style)
        let contentRect = CGRect(x: pad, y: pad, width: visible.width, height: visible.height)
        let radius = style.isEnabled ? min(style.cornerRadius, min(visible.width, visible.height) / 2) : 0
        let clipPath = Path(roundedRect: contentRect, cornerRadius: radius)

        if style.isEnabled {
            context.fill(
                Path(CGRect(origin: .zero, size: output)),
                with: .linearGradient(
                    Gradient(colors: style.preset.gradientColors),
                    startPoint: .zero,
                    endPoint: CGPoint(x: output.width, y: output.height)
                )
            )
            if style.shadow {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.45),
                                            radius: pad * 0.35,
                                            y: pad * 0.12))
                    layer.fill(clipPath, with: .color(.black.opacity(0.6)))
                }
            }
        }

        context.drawLayer { layer in
            if style.isEnabled {
                layer.clip(to: clipPath)
            }
            layer.translateBy(x: contentRect.origin.x - visible.origin.x,
                              y: contentRect.origin.y - visible.origin.y)
            if let image {
                layer.draw(Image(nsImage: image),
                           in: CGRect(origin: .zero, size: imageSize))
            }
            for annotation in annotations {
                AnnotationRenderer.draw(annotation, in: &layer)
            }
        }
    }
}
