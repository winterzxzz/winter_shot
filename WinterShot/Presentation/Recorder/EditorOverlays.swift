import SwiftUI
import AVFoundation

// Crop and mask editing for the recording editor — Screen Studio's crop
// window (dimmed surround, rule-of-thirds, eight handles, min 200 px, aspect
// lock, Size/Position/Reset toolbar) and its mask mode (draw a rectangle on
// the video, then move/resize it) share one rect-editing overlay.

// MARK: - Rect editing

/// Which part of a rect a drag grabbed.
enum RectHandle: CaseIterable {
    case move
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
}

/// Moves/resizes a rect in unit coordinates (0…1, top-left origin) with a
/// minimum size and an optional locked aspect ratio (width/height in unit
/// space), keeping it inside the unit square.
struct RectEditing {
    var minWidth: Double
    var minHeight: Double
    /// Locked width ÷ height in *unit* space (nil = free).
    var aspect: Double?

    func apply(_ handle: RectHandle, to start: UnitRect, dx: Double, dy: Double) -> UnitRect {
        var r = start
        switch handle {
        case .move:
            r.x += dx
            r.y += dy
            return r.clamped(minWidth: minWidth, minHeight: minHeight)
        case .left, .topLeft, .bottomLeft:
            let newX = min(max(start.x + dx, 0), start.x + start.width - minWidth)
            r.width = start.width - (newX - start.x)
            r.x = newX
        case .right, .topRight, .bottomRight:
            r.width = min(max(start.width + dx, minWidth), 1 - start.x)
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            let newY = min(max(start.y + dy, 0), start.y + start.height - minHeight)
            r.height = start.height - (newY - start.y)
            r.y = newY
        case .bottom, .bottomLeft, .bottomRight:
            r.height = min(max(start.height + dy, minHeight), 1 - start.y)
        default: break
        }
        if let aspect { r = lockAspect(r, anchor: handle, from: start, aspect: aspect) }
        return r.clamped(minWidth: minWidth, minHeight: minHeight)
    }

    /// Re-derives the secondary dimension so width/height == aspect, growing
    /// away from the edge opposite the dragged handle.
    private func lockAspect(_ r: UnitRect, anchor: RectHandle, from start: UnitRect, aspect: Double) -> UnitRect {
        var out = r
        let horizontal: Bool
        switch anchor {
        case .left, .right: horizontal = true
        case .top, .bottom: horizontal = false
        default: horizontal = abs(r.width - start.width) >= abs(r.height - start.height)
        }
        if horizontal {
            out.height = out.width / aspect
        } else {
            out.width = out.height * aspect
        }
        // Keep the anchored edges fixed.
        switch anchor {
        case .topLeft, .top, .left:
            out.x = start.x + start.width - out.width
            out.y = start.y + start.height - out.height
        case .topRight, .right:
            out.y = start.y + start.height - out.height
        case .bottomLeft, .bottom:
            out.x = start.x + start.width - out.width
        default: break
        }
        // If the locked size overflowed the unit square, shrink to fit.
        if out.width > 1 || out.height > 1 || out.x < 0 || out.y < 0 || out.x + out.width > 1 || out.y + out.height > 1 {
            let maxW = min(1, (1) * aspect)
            let w = min(out.width, maxW, 1)
            out.width = w
            out.height = w / aspect
            out.x = min(max(out.x, 0), 1 - out.width)
            out.y = min(max(out.y, 0), 1 - out.height)
        }
        return out
    }

    /// The handle under `point` for a rect drawn in `frame` (view points).
    static func hitTest(_ point: CGPoint, rect: CGRect, grip: CGFloat = 12) -> RectHandle? {
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) <= grip }
        let insideX = point.x >= rect.minX - grip && point.x <= rect.maxX + grip
        let insideY = point.y >= rect.minY - grip && point.y <= rect.maxY + grip
        guard insideX, insideY else { return nil }
        let l = near(point.x, rect.minX), r = near(point.x, rect.maxX)
        let t = near(point.y, rect.minY), b = near(point.y, rect.maxY)
        switch (l, r, t, b) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default:
            return rect.contains(point) ? .move : nil
        }
    }
}

/// Handles + outline for a rect being edited, drawn over `frame` (view points).
struct RectHandlesView: View {
    let frame: CGRect
    var color: Color = .white
    var showThirds = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            if showThirds {
                Path { p in
                    for i in 1...2 {
                        let x = frame.minX + frame.width * CGFloat(i) / 3
                        let y = frame.minY + frame.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                        p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                    }
                }
                .stroke(color.opacity(0.35), lineWidth: 1)
            }
            ForEach(Array(handlePoints.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(p)
            }
        }
        .allowsHitTesting(false)
    }

    private var handlePoints: [CGPoint] {
        [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.midY),
        ]
    }
}

// MARK: - Crop editor

/// Screen Studio's crop aspect choices (Any + fixed ratios), in pixel terms.
enum CropAspect: String, CaseIterable, Identifiable {
    case any, wide, classic, square, tall, vertical
    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any"
        case .wide: return "16:9"
        case .classic: return "4:3"
        case .square: return "1:1"
        case .tall: return "3:4"
        case .vertical: return "9:16"
        }
    }

    var ratio: Double? {
        switch self {
        case .any: return nil
        case .wide: return 16.0 / 9.0
        case .classic: return 4.0 / 3.0
        case .square: return 1
        case .tall: return 3.0 / 4.0
        case .vertical: return 9.0 / 16.0
        }
    }
}

/// The crop editor: the raw frame with the crop rectangle over it — dimmed
/// surround, thirds grid, eight handles; drag inside to move, handles to
/// resize; minimum 200 × 200 px; optional aspect lock.
struct CropEditorView: View {
    let image: CGImage?
    let frameSize: CGSize      // recording pixels
    @Binding var crop: UnitRect
    let aspect: CropAspect

    @State private var dragStart: UnitRect?
    @State private var dragHandle: RectHandle?

    private var editing: RectEditing {
        RectEditing(minWidth: min(200 / frameSize.width, 1),
                    minHeight: min(200 / frameSize.height, 1),
                    aspect: aspect.ratio.map { $0 * (frameSize.height / frameSize.width) })
    }

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            let cropFrame = CGRect(x: fit.minX + crop.x * fit.width,
                                   y: fit.minY + crop.y * fit.height,
                                   width: crop.width * fit.width,
                                   height: crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                Studio.background
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .offset(x: 0, y: 0)
                }
                // Dim everything outside the crop.
                Path { p in
                    p.addRect(fit)
                    p.addRect(cropFrame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                RectHandlesView(frame: cropFrame, showThirds: true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragHandle == nil {
                            dragHandle = RectEditing.hitTest(value.startLocation, rect: cropFrame) ?? .move
                            dragStart = crop
                        }
                        guard let handle = dragHandle, let start = dragStart else { return }
                        let dx = Double(value.translation.width / fit.width)
                        let dy = Double(value.translation.height / fit.height)
                        crop = editing.apply(handle, to: start, dx: dx, dy: dy)
                    }
                    .onEnded { _ in
                        dragHandle = nil
                        dragStart = nil
                    }
            )
        }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let avail = CGSize(width: max(size.width - inset * 2, 1), height: max(size.height - inset * 2, 1))
        let scale = min(avail.width / frameSize.width, avail.height / frameSize.height)
        let w = frameSize.width * scale, h = frameSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// Grabs a still of the raw recording at `time` for the crop editor.
enum RecordingStills {
    static func frame(of url: URL, at time: Double, maxSize: CGSize = CGSize(width: 1800, height: 1200)) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = maxSize
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        return try? await generator.image(at: cmTime).image
    }
}

// MARK: - Mask overlay

/// Drawn over the composited preview in mask mode: existing masks as
/// outlined rectangles, the selected one with handles; drag on empty space
/// to draw a new mask. Coordinates are unit coordinates of the cropped
/// recording; `contentFrame` is where that recording sits in the overlay.
struct MaskOverlayView: View {
    let masks: [RecordingMask]
    let selectedID: UUID?
    let contentFrame: CGRect
    let time: Double
    let onSelect: (UUID?) -> Void
    let onChange: (UUID, UnitRect) -> Void
    let onCreate: (UnitRect) -> Void

    @State private var dragHandle: RectHandle?
    @State private var dragStart: UnitRect?
    @State private var dragMaskID: UUID?
    @State private var rubberBand: CGRect?

    private static let maskColor = Color(red: 0x82 / 255, green: 0x34 / 255, blue: 0x5A / 255)
    private let editing = RectEditing(minWidth: 0.02, minHeight: 0.02, aspect: nil)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(masks) { mask in
                let frame = viewRect(mask.rect)
                let selected = mask.id == selectedID
                let live = time >= mask.start && time <= mask.end
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected ? Color.white : Self.maskColor.opacity(live ? 1 : 0.6),
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [5, 4]))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                Text(mask.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(selected ? Studio.primary : Self.maskColor, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: frame.minX + 4, y: frame.minY + 4)
                    .allowsHitTesting(false)
                if selected {
                    RectHandlesView(frame: frame)
                }
            }
            if let rubberBand {
                Rectangle()
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background(Color.white.opacity(0.08))
                    .frame(width: rubberBand.width, height: rubberBand.height)
                    .offset(x: rubberBand.minX, y: rubberBand.minY)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragHandle == nil, dragMaskID == nil, rubberBand == nil {
                        begin(at: value.startLocation)
                    }
                    if let id = dragMaskID, let handle = dragHandle, let start = dragStart {
                        let dx = Double(value.translation.width / contentFrame.width)
                        let dy = Double(value.translation.height / contentFrame.height)
                        onChange(id, editing.apply(handle, to: start, dx: dx, dy: dy))
                    } else {
                        let a = value.startLocation, b = value.location
                        rubberBand = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                            width: abs(b.x - a.x), height: abs(b.y - a.y))
                    }
                }
                .onEnded { value in
                    if let band = rubberBand {
                        if band.width > 6, band.height > 6 {
                            onCreate(unitRect(band))
                        } else if dragMaskID == nil {
                            // A plain click on empty space clears the selection.
                            onSelect(nil)
                        }
                    }
                    dragHandle = nil
                    dragStart = nil
                    dragMaskID = nil
                    rubberBand = nil
                }
        )
    }

    private func begin(at point: CGPoint) {
        // Selected mask first (its handles win), then any other mask body.
        if let id = selectedID, let mask = masks.first(where: { $0.id == id }),
           let handle = RectEditing.hitTest(point, rect: viewRect(mask.rect)) {
            dragMaskID = id
            dragHandle = handle
            dragStart = mask.rect
            return
        }
        if let mask = masks.last(where: { viewRect($0.rect).contains(point) }) {
            onSelect(mask.id)
            dragMaskID = mask.id
            dragHandle = .move
            dragStart = mask.rect
            return
        }
        rubberBand = CGRect(origin: point, size: .zero)
    }

    private func viewRect(_ r: UnitRect) -> CGRect {
        CGRect(x: contentFrame.minX + r.x * contentFrame.width,
               y: contentFrame.minY + r.y * contentFrame.height,
               width: r.width * contentFrame.width,
               height: r.height * contentFrame.height)
    }

    private func unitRect(_ frame: CGRect) -> UnitRect {
        return UnitRect(x: Double((frame.minX - contentFrame.minX) / contentFrame.width),
                 y: Double((frame.minY - contentFrame.minY) / contentFrame.height),
                 width: Double(frame.width / contentFrame.width),
                 height: Double(frame.height / contentFrame.height))
            .clamped(minWidth: 0.02, minHeight: 0.02)
    }
}
