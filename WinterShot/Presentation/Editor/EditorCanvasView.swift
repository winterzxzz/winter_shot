import SwiftUI

/// The live annotation canvas. The screenshot renders at the current zoom
/// (fit or an explicit percentage, scrollable when larger than the window);
/// all gesture coordinates are converted into image pixel space before they
/// reach the view model.
struct EditorCanvasView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let scale = viewModel.effectiveScale(fitting: proxy.size)
            let contentSize = CGSize(width: viewModel.imagePixelSize.width * scale,
                                     height: viewModel.imagePixelSize.height * scale)
            let canvasSize = CGSize(width: max(contentSize.width, proxy.size.width),
                                    height: max(contentSize.height, proxy.size.height))
            let origin = CGPoint(x: (canvasSize.width - contentSize.width) / 2,
                                 y: (canvasSize.height - contentSize.height) / 2)

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                canvas(scale: scale, origin: origin)
                    .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .onAppear { viewModel.renderedScale = scale }
            .onChange(of: scale) { _, newValue in viewModel.renderedScale = newValue }
        }
        .background(Color.black.opacity(0.35))
    }

    private func canvas(scale: CGFloat, origin: CGPoint) -> some View {
        Canvas { context, _ in
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)

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
                    let point = imagePoint(value.location, scale: scale, origin: origin)
                    let translation = CGSize(width: value.translation.width / scale,
                                             height: value.translation.height / scale)
                    if !isDragging {
                        isDragging = true
                        viewModel.dragBegan(at: imagePoint(value.startLocation, scale: scale, origin: origin))
                    }
                    viewModel.dragChanged(to: point, translation: translation)
                }
                .onEnded { value in
                    isDragging = false
                    let translation = CGSize(width: value.translation.width / scale,
                                             height: value.translation.height / scale)
                    viewModel.dragEnded(at: imagePoint(value.location, scale: scale, origin: origin),
                                        translation: translation)
                }
        )
    }

    private func imagePoint(_ location: CGPoint, scale: CGFloat, origin: CGPoint) -> CGPoint {
        let size = viewModel.imagePixelSize
        let x = (location.x - origin.x) / scale
        let y = (location.y - origin.y) / scale
        return CGPoint(x: min(max(x, 0), size.width),
                       y: min(max(y, 0), size.height))
    }
}
