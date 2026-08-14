import SwiftUI

/// The live annotation canvas. The screenshot is drawn at fit-to-window
/// scale; all gesture coordinates are converted into image pixel space
/// before they reach the view model.
struct EditorCanvasView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let layout = layout(in: proxy.size)

            Canvas { context, _ in
                context.translateBy(x: layout.origin.x, y: layout.origin.y)
                context.scaleBy(x: layout.scale, y: layout.scale)

                if let image = viewModel.image {
                    context.draw(Image(nsImage: image),
                                 in: CGRect(origin: .zero, size: viewModel.imagePixelSize))
                }
                for annotation in viewModel.annotations {
                    AnnotationRenderer.draw(annotation, in: &context)
                }
                if let draft = viewModel.draft {
                    AnnotationRenderer.draw(draft, in: &context)
                }
                if let selected = viewModel.annotations.first(where: { $0.id == viewModel.selectedAnnotationID }) {
                    AnnotationRenderer.drawSelectionOutline(for: selected, in: &context)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = imagePoint(value.location, layout: layout)
                        if !isDragging {
                            isDragging = true
                            viewModel.dragBegan(at: point)
                        } else {
                            viewModel.dragChanged(to: point)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        viewModel.dragEnded(at: imagePoint(value.location, layout: layout))
                    }
            )
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private struct CanvasLayout {
        var scale: CGFloat
        var origin: CGPoint
    }

    private func layout(in available: CGSize) -> CanvasLayout {
        let imageSize = viewModel.imagePixelSize
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0 else {
            return CanvasLayout(scale: 1, origin: .zero)
        }
        let padding: CGFloat = 24
        let fit = min((available.width - padding) / imageSize.width,
                      (available.height - padding) / imageSize.height,
                      1)
        let scale = max(fit, 0.01)
        let origin = CGPoint(x: (available.width - imageSize.width * scale) / 2,
                             y: (available.height - imageSize.height * scale) / 2)
        return CanvasLayout(scale: scale, origin: origin)
    }

    private func imagePoint(_ location: CGPoint, layout: CanvasLayout) -> CGPoint {
        let size = viewModel.imagePixelSize
        let x = (location.x - layout.origin.x) / layout.scale
        let y = (location.y - layout.origin.y) / layout.scale
        return CGPoint(x: min(max(x, 0), size.width),
                       y: min(max(y, 0), size.height))
    }
}
