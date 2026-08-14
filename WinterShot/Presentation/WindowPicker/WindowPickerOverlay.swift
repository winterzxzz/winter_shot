import AppKit
import SwiftUI

/// Frozen-screen window selector, BridgeShot-style: every display is covered
/// by a panel showing its frozen snapshot; the window under the cursor is
/// lifted out of a dimmed backdrop; click captures it, Esc cancels.
///
/// Set WINTERSHOT_AUTOPICK=1 (optionally WINTERSHOT_AUTOPICK_DELAY=<seconds>)
/// to auto-select the largest window — used by scripted smoke tests.
@MainActor
final class WindowPickerOverlayPresenter: WindowPickerUI {
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<PickableWindow?, Never>?
    private let model = PickerModel()

    func pickWindow(windows: [PickableWindow], backdrops: [DisplayBackdrop]) async -> PickableWindow? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(windows: windows, backdrops: backdrops)
        }
    }

    private func present(windows: [PickableWindow], backdrops: [DisplayBackdrop]) {
        model.hovered = nil

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
            panel.contentView = NSHostingView(rootView: WindowPickerScreenView(
                backdrop: backdrop,
                windows: windows,
                model: model,
                onPick: { [weak self] picked in self?.finish(picked) }
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

        armAutoPickIfRequested(windows: windows)
    }

    private func finish(_ result: PickableWindow?) {
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

    private func armAutoPickIfRequested(windows: [PickableWindow]) {
        let env = ProcessInfo.processInfo.environment
        guard env["WINTERSHOT_AUTOPICK"] == "1" else { return }
        let delay = Double(env["WINTERSHOT_AUTOPICK_DELAY"] ?? "") ?? 1.0
        guard let target = windows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finish(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + min(0.5, delay / 2)) { [weak self] in
            self?.model.hovered = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.finish(target)
        }
    }
}

@MainActor
private final class PickerModel: ObservableObject {
    @Published var hovered: PickableWindow?
}

private struct WindowPickerScreenView: View {
    let backdrop: DisplayBackdrop
    let windows: [PickableWindow]
    @ObservedObject fileprivate var model: PickerModel
    let onPick: (PickableWindow?) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Image(decorative: backdrop.image, scale: imageScale)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Canvas { context, size in
                    var dim = Path()
                    dim.addRect(CGRect(origin: .zero, size: size))
                    let hoveredRect = localRect(of: model.hovered, in: size)
                    if let hoveredRect {
                        dim.addRoundedRect(in: hoveredRect, cornerSize: CGSize(width: 8, height: 8))
                    }
                    context.fill(dim, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
                    if let hoveredRect {
                        context.stroke(Path(roundedRect: hoveredRect, cornerRadius: 8),
                                       with: .color(.accentColor),
                                       lineWidth: 2.5)
                    }
                }

                VStack(spacing: 10) {
                    if let hovered = model.hovered {
                        Text(hovered.title.isEmpty ? hovered.appName : "\(hovered.appName) — \(hovered.title)")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    HStack(spacing: 14) {
                        Text("Click a window").fontWeight(.semibold)
                        Text("Esc").fontWeight(.semibold) + Text("  Cancel").foregroundColor(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 48)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let global = CGPoint(x: backdrop.frame.origin.x + location.x,
                                         y: backdrop.frame.origin.y + location.y)
                    model.hovered = windows.first { $0.frame.contains(global) }
                case .ended:
                    break
                }
            }
            .onTapGesture {
                onPick(model.hovered)
            }
        }
        .ignoresSafeArea()
    }

    private var imageScale: CGFloat {
        CGFloat(backdrop.image.width) / max(backdrop.frame.width, 1)
    }

    /// Global window frame -> this panel's local coords (both top-left origin).
    private func localRect(of window: PickableWindow?, in size: CGSize) -> CGRect? {
        guard let window, backdrop.frame.intersects(window.frame) else { return nil }
        let sx = size.width / max(backdrop.frame.width, 1)
        let sy = size.height / max(backdrop.frame.height, 1)
        return CGRect(x: (window.frame.origin.x - backdrop.frame.origin.x) * sx,
                      y: (window.frame.origin.y - backdrop.frame.origin.y) * sy,
                      width: window.frame.width * sx,
                      height: window.frame.height * sy)
    }
}
