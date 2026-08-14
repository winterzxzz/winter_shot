import SwiftUI

/// Renders the screenshot with its annotations at native pixel size,
/// honoring the non-destructive crop. Used with ImageRenderer to produce
/// flattened exports — the only moment annotations (including redactions)
/// are burned into pixels.
struct FlattenedImageView: View {
    let image: NSImage
    let imageSize: CGSize
    let annotations: [Annotation]
    var crop: CGRect?

    private var visibleRect: CGRect {
        crop ?? CGRect(origin: .zero, size: imageSize)
    }

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: -visibleRect.origin.x, y: -visibleRect.origin.y)
            context.draw(Image(nsImage: image),
                         in: CGRect(origin: .zero, size: imageSize))
            for annotation in annotations {
                AnnotationRenderer.draw(annotation, in: &context)
            }
        }
        .frame(width: visibleRect.width, height: visibleRect.height)
    }
}
