import SwiftUI

/// Renders the screenshot with its annotations at native pixel size,
/// honoring the non-destructive crop, rotation and background beautify.
/// Used with ImageRenderer to produce flattened exports — the only moment
/// annotations (including redactions) are burned into pixels.
struct FlattenedImageView: View {
    let image: NSImage
    let imageSize: CGSize
    let annotations: [Annotation]
    var crop: CGRect?
    var background: BackdropStyle = .none
    var rotation: ImageRotation = .none

    private var visibleRect: CGRect {
        crop ?? CGRect(origin: .zero, size: imageSize)
    }

    var outputSize: CGSize {
        BeautifyRenderer.outputSize(visible: visibleRect, style: background, rotation: rotation)
    }

    var body: some View {
        Canvas { context, _ in
            var ctx = context
            BeautifyRenderer.drawContent(in: &ctx,
                                         image: image,
                                         imageSize: imageSize,
                                         annotations: annotations,
                                         visible: visibleRect,
                                         style: background,
                                         rotation: rotation)
        }
        .frame(width: outputSize.width, height: outputSize.height)
    }
}
