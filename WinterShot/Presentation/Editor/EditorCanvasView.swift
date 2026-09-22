import SwiftUI

/// The live annotation canvas. Shows the (possibly cropped and rotated)
/// screenshot at the current zoom, scrollable when larger than the window.
/// In crop mode the full image is shown with the crop selection marked. All
/// gesture coordinates are converted into image pixel space — undoing the
/// rotation — before they reach the view model.
struct EditorCanvasView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let visible = viewModel.visibleRect
            let scale = viewModel.effectiveScale(fitting: proxy.size)
            let outputSize = BeautifyRenderer.outputSize(visible: visible,
                                                         style: viewModel.displayBackdrop,
                                                         rotation: viewModel.rotation)
            let contentSize = CGSize(width: outputSize.width * scale,
                                     height: outputSize.height * scale)
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
            let style = viewModel.displayBackdrop
            let rotation = viewModel.rotation

            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)

            // Backdrop + clipped image and committed annotations.
            BeautifyRenderer.drawContent(in: &context,
                                         image: viewModel.image,
                                         imageSize: viewModel.imagePixelSize,
                                         annotations: viewModel.annotations,
                                         visible: visible,
                                         style: style,
                                         rotation: rotation)

            // Live overlays in the same image pixel space.
            BeautifyRenderer.applyContentTransform(&context, visible: visible,
                                                   style: style, rotation: rotation)
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
                    let translation = imageTranslation(value.translation, scale: scale)
                    if !isDragging {
                        isDragging = true
                        viewModel.dragBegan(at: imagePoint(value.startLocation, scale: scale,
                                                           origin: origin, visible: visible))
                    }
                    viewModel.dragChanged(to: point, translation: translation)
                }
                .onEnded { value in
                    isDragging = false
                    let translation = imageTranslation(value.translation, scale: scale)
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
            // The context is turned with the capture; undo that for the
            // readout so it stays upright on a rotated shot.
            let anchor = CGPoint(x: draft.midX, y: draft.maxY + 18 / scale)
            context.drawLayer { layer in
                layer.translateBy(x: anchor.x, y: anchor.y)
                layer.rotate(by: .degrees(-viewModel.rotation.degrees))
                layer.draw(label, at: .zero, anchor: .center)
            }
        } else {
            context.fill(dim, with: .color(.black.opacity(0.35)))
        }
    }

    /// A drag delta in view points as the capture's own pixels: scaled down
    /// and turned back, so dragging an annotation on a rotated shot moves it
    /// the way the cursor went.
    private func imageTranslation(_ translation: CGSize, scale: CGFloat) -> CGSize {
        let unturned = viewModel.rotation.unrotate(CGPoint(x: translation.width / scale,
                                                           y: translation.height / scale))
        return CGSize(width: unturned.x, height: unturned.y)
    }

    /// Inverse of `BeautifyRenderer.applyContentTransform`: view point →
    /// image pixel, clamped to the capture.
    private func imagePoint(_ location: CGPoint, scale: CGFloat, origin: CGPoint,
                            visible: CGRect) -> CGPoint {
        let size = viewModel.imagePixelSize
        let rotation = viewModel.rotation
        let content = BeautifyRenderer.contentSize(visible: visible, rotation: rotation)
        let pad = BeautifyRenderer.padding(for: viewModel.displayBackdrop, content: content)
        let fromCentre = CGPoint(x: (location.x - origin.x) / scale - pad - content.width / 2,
                                 y: (location.y - origin.y) / scale - pad - content.height / 2)
        let unturned = rotation.unrotate(fromCentre)
        return CGPoint(x: min(max(unturned.x + visible.midX, 0), size.width),
                       y: min(max(unturned.y + visible.midY, 0), size.height))
    }
}
