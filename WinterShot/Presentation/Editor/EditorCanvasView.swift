import SwiftUI

/// The live annotation canvas. Shows the (possibly cropped) screenshot at
/// the current zoom, scrollable when larger than the window. In crop mode
/// the full image is shown with the crop selection marked. All gesture
/// coordinates are converted into image pixel space before they reach the
/// view model.
struct EditorCanvasView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let visible = viewModel.visibleRect
            let scale = viewModel.effectiveScale(fitting: proxy.size)
            let contentSize = CGSize(width: visible.width * scale,
                                     height: visible.height * scale)
            let canvasSize = CGSize(width: max(contentSize.width, proxy.size.width),
                                    height: max(contentSize.height, proxy.size.height))
            let origin = CGPoint(x: (canvasSize.width - contentSize.width) / 2,
                                 y: (canvasSize.height - contentSize.height) / 2)

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                canvas(scale: scale, origin: origin, visible: visible)
                    .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .onAppear { viewModel.renderedScale = scale }
            .onChange(of: scale) { _, newValue in viewModel.renderedScale = newValue }
        }
        .background(Color.black.opacity(0.35))
    }

    private func canvas(scale: CGFloat, origin: CGPoint, visible: CGRect) -> some View {
        Canvas { context, _ in
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -visible.origin.x, y: -visible.origin.y)

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
            if viewModel.isCropping {
                drawCropOverlay(in: &context, scale: scale)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let point = imagePoint(value.location, scale: scale, origin: origin, visible: visible)
                    let translation = CGSize(width: value.translation.width / scale,
                                             height: value.translation.height / scale)
                    if !isDragging {
                        isDragging = true
                        viewModel.dragBegan(at: imagePoint(value.startLocation, scale: scale,
                                                           origin: origin, visible: visible))
                    }
                    viewModel.dragChanged(to: point, translation: translation)
                }
                .onEnded { value in
                    isDragging = false
                    let translation = CGSize(width: value.translation.width / scale,
                                             height: value.translation.height / scale)
                    viewModel.dragEnded(at: imagePoint(value.location, scale: scale,
                                                       origin: origin, visible: visible),
                                        translation: translation)
                }
        )
    }

    /// Dim everything outside the crop selection, stroke it, and mark the
    /// rule-of-thirds grid. Drawn in image space (context already scaled).
    private func drawCropOverlay(in context: inout GraphicsContext, scale: CGFloat) {
        let full = viewModel.fullImageRect
        var dim = Path()
        dim.addRect(full)
        if let draft = viewModel.cropDraft, draft.width > 1, draft.height > 1 {
            dim.addRect(draft)
            context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(draft), with: .color(.white), lineWidth: 2 / scale)

            var thirds = Path()
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                thirds.move(to: CGPoint(x: draft.minX + draft.width * fraction, y: draft.minY))
                thirds.addLine(to: CGPoint(x: draft.minX + draft.width * fraction, y: draft.maxY))
                thirds.move(to: CGPoint(x: draft.minX, y: draft.minY + draft.height * fraction))
                thirds.addLine(to: CGPoint(x: draft.maxX, y: draft.minY + draft.height * fraction))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 1 / scale)

            let label = Text("\(Int(draft.width)) × \(Int(draft.height)) px")
                .font(.system(size: 13 / scale, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            context.draw(label, at: CGPoint(x: draft.midX, y: draft.maxY + 18 / scale), anchor: .center)
        } else {
            context.fill(dim, with: .color(.black.opacity(0.35)))
        }
    }

    private func imagePoint(_ location: CGPoint, scale: CGFloat, origin: CGPoint,
                            visible: CGRect) -> CGPoint {
        let size = viewModel.imagePixelSize
        let x = (location.x - origin.x) / scale + visible.origin.x
        let y = (location.y - origin.y) / scale + visible.origin.y
        return CGPoint(x: min(max(x, 0), size.width),
                       y: min(max(y, 0), size.height))
    }
}
