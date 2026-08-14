import SwiftUI

/// Renders the screenshot with its annotations at native pixel size.
/// Used with ImageRenderer to produce flattened exports — the only moment
/// annotations (including redactions) are burned into pixels.
struct FlattenedImageView: View {
    let image: NSImage
    let imageSize: CGSize
    let annotations: [Annotation]

    var body: some View {
        Canvas { context, _ in
            context.draw(Image(nsImage: image),
                         in: CGRect(origin: .zero, size: imageSize))
            for annotation in annotations {
                AnnotationRenderer.draw(annotation, in: &context)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
    }
}
