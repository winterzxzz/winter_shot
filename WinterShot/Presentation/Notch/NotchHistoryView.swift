import SwiftUI
import AppKit

// MARK: - View model

/// State for the notch history panel: the capture library plus the same
/// quick actions a library card offers.
@MainActor
final class NotchHistoryViewModel: ObservableObject {
    @Published var screenshots: [Screenshot] = []

    private let container: DIContainer

    init(container: DIContainer) {
        self.container = container
    }

    func reload() {
        screenshots = (try? container.fetchHistoryUseCase.execute()) ?? []
    }

    func copy(_ screenshot: Screenshot) {
        guard let image = NSImage(contentsOf: screenshot.imageURL) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func pin(_ screenshot: Screenshot) {
        guard let image = NSImage(contentsOf: screenshot.imageURL) else { return }
        PinWindowManager.shared.pin(image: image)
    }

    func delete(_ screenshot: Screenshot) {
        try? container.deleteScreenshotUseCase.execute(screenshot)
        screenshots.removeAll { $0.id == screenshot.id }
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(container.screenshotRepository.storageDirectory)
    }
}

// MARK: - Shape

/// The hanging-from-the-notch silhouette: flared top corners (mirroring the
/// hardware notch) and rounded bottom corners.
struct NotchShape: InsettableShape {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 26
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let t = topRadius
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Panel content

/// The notch dropdown itself: header with capture actions, a horizontally
/// scrolling capture history, and a small utility footer. Dark glass over
/// pure black so it reads as an extension of the notch.
struct NotchHistoryView: View {
    @ObservedObject var state: NotchPanelState
    @ObservedObject var viewModel: NotchHistoryViewModel
    let onOpen: (Screenshot) -> Void
    let onOpenLibrary: () -> Void
    let onCapture: (CaptureMode) -> Void
    let onClose: () -> Void

    private var collapsedSize: CGSize { CGSize(width: 220, height: max(state.topInset, 34)) }
    private static let expandedSize = CGSize(width: 720, height: 440)

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            panel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { viewModel.reload() }
    }

    private var panel: some View {
        content
            .frame(width: state.expanded ? Self.expandedSize.width : collapsedSize.width,
                   height: state.expanded ? Self.expandedSize.height : collapsedSize.height,
                   alignment: .top)
            .background {
                ZStack {
                    Color.black
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), .clear],
                        startPoint: .top, endPoint: .init(x: 0.5, y: 0.55)
                    )
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.55, blue: 1).opacity(0.10),
                                 Color(red: 0.65, green: 0.35, blue: 1).opacity(0.06),
                                 .clear],
                        startPoint: .bottom, endPoint: .init(x: 0.5, y: 0.4)
                    )
                }
            }
            .clipShape(NotchShape(topRadius: 12, bottomRadius: state.expanded ? 28 : 16))
            .overlay {
                NotchShape(topRadius: 12, bottomRadius: state.expanded ? 28 : 16)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.16),
                                                Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
            .shadow(color: Color(red: 0.4, green: 0.5, blue: 1).opacity(state.expanded ? 0.16 : 0),
                    radius: 40, y: 18)
            .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state.expanded)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Dead zone behind the hardware notch / menu bar.
            Color.clear.frame(height: state.topInset)

            Group {
                header
                if viewModel.screenshots.isEmpty {
                    emptyState
                } else {
                    historyStrip
                }
                footer
            }
            .opacity(state.expanded ? 1 : 0)
            .animation(state.expanded
                       ? .easeOut(duration: 0.24).delay(0.10)
                       : .easeIn(duration: 0.08),
                       value: state.expanded)
        }
        .padding(.horizontal, 12)   // clear the shape's flared top corners
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.full)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text("WinterShot")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("\(viewModel.screenshots.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.white.opacity(0.10), in: Capsule())

            Spacer()

            HStack(spacing: 8) {
                ForEach(CaptureMode.allCases) { mode in
                    GlassIconButton(icon: mode.systemImage,
                                    help: "\(mode.label)  ⌘⇧\(mode.hotkeyNumber)") {
                        onCapture(mode)
                    }
                }
            }

            Capsule()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 4)

            GlassIconButton(icon: "photo.on.rectangle.angled", help: "Open Library") {
                onOpenLibrary()
            }
            GlassIconButton(icon: "xmark", help: "Close") {
                onClose()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: History

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(viewModel.screenshots.prefix(30)) { screenshot in
                    NotchCaptureCard(
                        screenshot: screenshot,
                        onOpen: { onOpen(screenshot) },
                        onCopy: { viewModel.copy(screenshot) },
                        onPin: { viewModel.pin(screenshot) },
                        onDelete: { viewModel.delete(screenshot) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(nsImage: AppIcon.full)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .opacity(0.65)
            Text("No captures yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Press ⌘⇧4 to capture an area")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            FooterButton(icon: "folder", title: "Captures Folder") {
                viewModel.openCapturesFolder()
                onClose()
            }
            FooterButton(icon: "arrow.clockwise", title: "Refresh") {
                viewModel.reload()
            }
            Spacer()
            FooterButton(icon: "power", title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

// MARK: - Building blocks

private struct GlassIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 30, height: 30)
                .background(.white.opacity(hovering ? 0.18 : 0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(hovering ? 0.3 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct FooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(hovering ? 0.10 : 0), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// One capture in the strip: thumbnail with hover quick actions, then the
/// capture's age underneath. Draggable into other apps.
private struct NotchCaptureCard: View {
    let screenshot: Screenshot
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private static let thumbSize = CGSize(width: 250, height: 168)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.white.opacity(0.06)
                    .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(hovering ? 0.45 : 0.12),
                                          lineWidth: 1)
                    )
                    .overlay(alignment: .bottom) {
                        if hovering {
                            HStack(spacing: 13) {
                                quickAction(icon: "rectangle.and.pencil.and.ellipsis",
                                            help: "Annotate", action: onOpen)
                                quickAction(icon: "doc.on.doc", help: "Copy", action: onCopy)
                                quickAction(icon: "pin", help: "Pin to screen", action: onPin)
                                quickAction(icon: "trash", help: "Delete", action: onDelete)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.72), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
            }
            .scaleEffect(hovering ? 1.03 : 1)

            HStack(spacing: 6) {
                Image(systemName: screenshot.mode.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text(age)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.leading, 4)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .onDrag { NSItemProvider(contentsOf: screenshot.imageURL) ?? NSItemProvider() }
        .help("Click to annotate, or drag into another app")
        .task(id: screenshot.id) { loadThumbnail() }
    }

    private func quickAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var age: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: screenshot.createdAt, relativeTo: Date())
    }

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        thumbnail = NSImage(contentsOf: screenshot.imageURL)
    }
}
