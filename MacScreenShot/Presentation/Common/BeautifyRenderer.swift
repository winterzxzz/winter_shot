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

    /// The visible capture as it is drawn: the crop, turned by `rotation`.
    static func contentSize(visible: CGRect, rotation: ImageRotation) -> CGSize {
        rotation.apply(to: visible.size)
    }

    /// Total output size: turned content plus backdrop padding.
    static func outputSize(visible: CGRect, style: BackdropStyle,
                           rotation: ImageRotation = .none) -> CGSize {
        let content = contentSize(visible: visible, rotation: rotation)
        let pad = padding(for: style, content: content)
        return CGSize(width: content.width + pad * 2, height: content.height + pad * 2)
    }

    /// Moves a context from output space into image pixel space: the visible
    /// rect lands centred inside the padded content box, turned by `rotation`.
    /// Drawing afterwards happens in the capture's own coordinates, so
    /// annotations and crop rects never have to be rewritten when it turns.
    static func applyContentTransform(_ context: inout GraphicsContext,
                                      visible: CGRect,
                                      style: BackdropStyle,
                                      rotation: ImageRotation) {
        let content = contentSize(visible: visible, rotation: rotation)
        let pad = padding(for: style, content: content)
        context.translateBy(x: pad + content.width / 2, y: pad + content.height / 2)
        if !rotation.isIdentity {
            context.rotate(by: .degrees(rotation.degrees))
        }
        context.translateBy(x: -visible.midX, y: -visible.midY)
    }

    /// Draws backdrop + clipped content (image and annotations) into a context
    /// whose (0,0)..outputSize covers the final output, in image pixel scale.
    static func drawContent(in context: inout GraphicsContext,
                            image: NSImage?,
                            imageSize: CGSize,
                            annotations: [Annotation],
                            visible: CGRect,
                            style: BackdropStyle,
                            rotation: ImageRotation = .none) {
        let content = contentSize(visible: visible, rotation: rotation)
        let pad = padding(for: style, content: content)
        let output = outputSize(visible: visible, style: style, rotation: rotation)
        let contentRect = CGRect(x: pad, y: pad, width: content.width, height: content.height)
        let radius = style.isEnabled ? min(style.cornerRadius, min(content.width, content.height) / 2) : 0
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
            // Always clip: the image is drawn at full size and only moved
            // into place, so without this the parts outside the crop paint too.
            layer.clip(to: clipPath)
            applyContentTransform(&layer, visible: visible, style: style, rotation: rotation)
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
