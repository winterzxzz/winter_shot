import AppKit
import SwiftUI

/// Frozen-screen area selector, BridgeShot-style: every display is covered by
/// its frozen snapshot; a pixel loupe with live coordinates follows the
/// cursor; dragging marks the selection with a size readout. Release captures,
/// Esc cancels.
///
/// Set WINTERSHOT_AUTOAREA="x,y,w,h" (global points, CG coords, optionally
/// WINTERSHOT_AUTOPICK_DELAY=<seconds>) to auto-select — used by smoke tests.
@MainActor
final class AreaPickerOverlayPresenter: AreaPickerUI {
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<AreaSelection?, Never>?

    func pickArea(backdrops: [DisplayBackdrop]) async -> AreaSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(backdrops: backdrops)
        }
    }

    private func present(backdrops: [DisplayBackdrop]) {
        for backdrop in backdrops {
            let panel = OverlayPanel(
                contentRect: appKitFrame(for: backdrop.frame),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = NSHostingView(rootView: AreaPickerScreenView(
                backdrop: backdrop,
                onSelect: { [weak self] rect in
                    self?.finish(AreaSelection(backdrop: backdrop, rect: rect))
                }
            ))
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.finish(nil)
                return nil
            }
            return event
        }

        armAutoSelectIfRequested(backdrops: backdrops)
    }

    private func finish(_ result: AreaSelection?) {
        guard let continuation else { return }
        self.continuation = nil

        NSCursor.pop()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panels.forEach { $0.close() }
        panels.removeAll()

        continuation.resume(returning: result)
    }

    /// CG global coords (top-left origin, y down) -> AppKit screen coords.
    private func appKitFrame(for cgFrame: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens
            .first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return NSRect(x: cgFrame.origin.x,
                      y: mainHeight - cgFrame.maxY,
                      width: cgFrame.width,
                      height: cgFrame.height)
    }

    private func armAutoSelectIfRequested(backdrops: [DisplayBackdrop]) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["WINTERSHOT_AUTOAREA"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let delay = Double(env["WINTERSHOT_AUTOPICK_DELAY"] ?? "") ?? 1.0
        guard parts.count == 4 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finish(nil) }
            return
        }
        let global = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        guard let backdrop = backdrops.first(where: { $0.frame.contains(global.origin) }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finish(nil) }
            return
        }
        let local = global.offsetBy(dx: -backdrop.frame.origin.x, dy: -backdrop.frame.origin.y)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.finish(AreaSelection(backdrop: backdrop, rect: local))
        }
    }
}

private struct AreaPickerScreenView: View {
    let backdrop: DisplayBackdrop
    let onSelect: (CGRect) -> Void

    @State private var cursor: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private var pixelScale: CGFloat {
        CGFloat(backdrop.image.width) / max(backdrop.frame.width, 1)
    }

    private var selection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(x: min(dragStart.x, dragCurrent.x),
                      y: min(dragStart.y, dragCurrent.y),
                      width: abs(dragCurrent.x - dragStart.x),
                      height: abs(dragCurrent.y - dragStart.y))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Image(decorative: backdrop.image, scale: pixelScale)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Canvas { context, size in
                    drawOverlay(in: &context, size: size)
                }

                if selection == nil {
                    HStack(spacing: 14) {
                        Text("Drag to select an area").fontWeight(.semibold)
                        Text("Esc").fontWeight(.semibold) + Text("  Cancel").foregroundColor(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 48)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): cursor = location
                case .ended: cursor = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        dragStart = value.startLocation
                        dragCurrent = value.location
                        cursor = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard let rect = selection, rect.width >= 4, rect.height >= 4 else { return }
                        _ = value
                        onSelect(rect)
                    }
            )
        }
        .ignoresSafeArea()
    }

    private func drawOverlay(in context: inout GraphicsContext, size: CGSize) {
        var dim = Path()
        dim.addRect(CGRect(origin: .zero, size: size))
        if let selection {
            dim.addRect(selection)
        }
        context.fill(dim,
                     with: .color(.black.opacity(selection == nil ? 0.22 : 0.45)),
                     style: FillStyle(eoFill: true))

        if let selection {
            context.stroke(Path(selection), with: .color(.white.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.5))
            let label = Text("\(Int(selection.width * pixelScale)) × \(Int(selection.height * pixelScale)) px")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            let anchor = CGPoint(x: selection.midX,
                                 y: selection.maxY + 18 < size.height ? selection.maxY + 14 : selection.maxY - 14)
            drawChip(label, at: anchor, in: &context)
        } else if let cursor {
            // Crosshair guides across the whole display.
            var guides = Path()
            guides.move(to: CGPoint(x: 0, y: cursor.y))
            guides.addLine(to: CGPoint(x: size.width, y: cursor.y))
            guides.move(to: CGPoint(x: cursor.x, y: 0))
            guides.addLine(to: CGPoint(x: cursor.x, y: size.height))
            context.stroke(guides, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }

        if let cursor {
            drawLoupe(at: cursor, in: &context, size: size)
        }
    }

    /// Magnified view of the frozen pixels under the cursor + live coordinates.
    private func drawLoupe(at point: CGPoint, in context: inout GraphicsContext, size: CGSize) {
        let magnification: CGFloat = 6
        let radius: CGFloat = 60
        let offset: CGFloat = 85

        var center = CGPoint(x: point.x + offset, y: point.y - offset)
        if center.x + radius > size.width { center.x = point.x - offset }
        if center.y - radius < 0 { center.y = point.y + offset }
        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)

        context.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: circle))
            layer.translateBy(x: center.x - point.x * magnification,
                              y: center.y - point.y * magnification)
            layer.scaleBy(x: magnification, y: magnification)
            layer.draw(Image(decorative: backdrop.image, scale: pixelScale),
                       in: CGRect(origin: .zero, size: backdrop.frame.size))
        }
        context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.9)), lineWidth: 2)

        // Center tick marking the exact pixel.
        let tick = CGRect(x: center.x - magnification / 2, y: center.y - magnification / 2,
                          width: magnification, height: magnification)
        context.stroke(Path(tick), with: .color(.red), lineWidth: 1)

        let coords = Text("\(Int(point.x * pixelScale)), \(Int(point.y * pixelScale))")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
        drawChip(coords, at: CGPoint(x: center.x, y: center.y + radius + 14), in: &context)
    }

    private func drawChip(_ text: Text, at point: CGPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 400, height: 100))
        let padding: CGFloat = 6
        let rect = CGRect(x: point.x - textSize.width / 2 - padding,
                          y: point.y - textSize.height / 2 - padding / 2,
                          width: textSize.width + padding * 2,
                          height: textSize.height + padding)
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                     with: .color(.black.opacity(0.65)))
        context.draw(resolved, at: point, anchor: .center)
    }
}
