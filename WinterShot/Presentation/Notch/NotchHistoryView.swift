import SwiftUI
import AppKit
import Combine

// MARK: - View model

/// State for the notch history panel: the capture library — screenshots and
/// recordings — plus the same quick actions a library card offers.
@MainActor
final class NotchHistoryViewModel: ObservableObject {
    @Published var items: [CaptureItem] = []

    private let container: DIContainer
    private var cancellables = Set<AnyCancellable>()

    init(container: DIContainer) {
        self.container = container
        NotificationCenter.default.publisher(for: .winterShotLibraryChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        items = (try? container.fetchLibraryUseCase.execute()) ?? []
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

    func revealInFinder(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    func delete(_ item: CaptureItem) {
        switch item {
        case .screenshot(let screenshot):
            try? container.deleteScreenshotUseCase.execute(screenshot)
        case .recording(let recording):
            try? container.deleteRecordingUseCase.execute(recording)
        }
        items.removeAll { $0.id == item.id }
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(container.screenshotRepository.storageDirectory)
    }
}

// MARK: - Shape

/// The hanging-from-the-notch silhouette: small flared top corners
/// (mirroring the hardware notch) and large rounded bottom corners.
struct NotchShape: InsettableShape {
    var topRadius: CGFloat = 10
    var bottomRadius: CGFloat = 30
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

/// The notch dropdown, MacNotch-style: seamless deep black extending the
/// notch, header row living at menu-bar height on either side of the
/// hardware notch, then the capture history strip. No hard borders — just
/// black, hairline dividers, and soft shadow.
struct NotchHistoryView: View {
    @ObservedObject var state: NotchPanelState
    @ObservedObject var viewModel: NotchHistoryViewModel
    let onOpen: (CaptureItem) -> Void
    let onOpenLibrary: () -> Void
    let onCapture: (CaptureMode) -> Void
    let onClose: () -> Void

    private static let expandedSize = CGSize(width: 860, height: 296)

    /// The strip at menu-bar height; the hardware notch sits in its middle.
    private var headerHeight: CGFloat { max(state.topInset, 34) + 10 }
    private var collapsedSize: CGSize { CGSize(width: 250, height: max(state.topInset, 32)) }

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
                // Seamless with the hardware notch: pure black, easing into a
                // barely-lifted charcoal at the bottom.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.45),
                        .init(color: Color(white: 0.055), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(NotchShape(topRadius: 10, bottomRadius: state.expanded ? 30 : 14))
            .shadow(color: .black.opacity(0.65), radius: 28, y: 14)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state.expanded)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
                .frame(height: headerHeight)
            Group {
                divider
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    historyStrip
                }
                bottomRow
            }
            .opacity(state.expanded ? 1 : 0)
            .animation(state.expanded
                       ? .easeOut(duration: 0.22).delay(0.10)
                       : .easeIn(duration: 0.08),
                       value: state.expanded)
        }
        .padding(.horizontal, 10)   // clear the shape's flared top corners
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 6)
    }

    // MARK: Header — lives at menu-bar height, split around the notch

    private var header: some View {
        HStack(spacing: 8) {
            // Left of the notch: identity.
            HStack(spacing: 8) {
                Image(nsImage: AppIcon.full)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("WinterShot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(viewModel.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .opacity(state.expanded ? 1 : 0)

            Spacer(minLength: state.hasNotch ? 230 : 20)

            // Right of the notch: actions.
            HStack(spacing: 7) {
                ForEach(CaptureMode.allCases) { mode in
                    HeaderButton(icon: mode.systemImage,
                                 help: mode.usesGlobalHotkey
                                     ? "\(mode.label)  \(AppPreferences.shared.captureHotkey.displayString)"
                                     : mode.label) {
                        onCapture(mode)
                    }
                }
                HeaderButton(icon: "photo.on.rectangle.angled", help: "Open Library") {
                    onOpenLibrary()
                }
                HeaderButton(icon: "xmark", help: "Close") {
                    onClose()
                }
            }
            .opacity(state.expanded ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    // MARK: History

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 12) {
                ForEach(viewModel.items.prefix(30)) { item in
                    NotchCaptureCard(
                        item: item,
                        onOpen: { onOpen(item) },
                        onCopy: { if case .screenshot(let shot) = item { viewModel.copy(shot) } },
                        onPin: { if case .screenshot(let shot) = item { viewModel.pin(shot) } },
                        onReveal: { viewModel.revealInFinder(item) },
                        onDelete: { viewModel.delete(item) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("No captures yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("\(AppPreferences.shared.captureHotkey.displayString) to capture · more in the menu bar")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 4) {
            GhostButton(icon: "folder", title: "Captures Folder") {
                viewModel.openCapturesFolder()
                onClose()
            }
            GhostButton(icon: "arrow.clockwise", title: "Refresh") {
                viewModel.reload()
            }
            Spacer()
            GhostButton(icon: "power", title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - Building blocks

/// Small round dark button for the header strip — no borders, just a soft
/// fill that brightens on hover.
private struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 26, height: 26)
                .background(.white.opacity(hovering ? 0.16 : 0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct GhostButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.4))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(hovering ? 0.08 : 0), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// One capture in the strip: borderless thumbnail (a poster frame for a
/// recording) with the capture's age on a bottom scrim, quick actions on
/// hover. Draggable into other apps.
private struct NotchCaptureCard: View {
    let item: CaptureItem
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var duration: Double = 0

    private static let thumbSize = CGSize(width: 236, height: 156)

    var body: some View {
        ZStack {
            Color(white: 0.09)
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: item.isRecording ? "film" : "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                .overlay(alignment: .bottom) {
                    // Caption scrim: capture age (and length) over a soft fade.
                    HStack(spacing: 5) {
                        Image(systemName: captionIcon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(caption)
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 7)
                    .background {
                        LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .opacity(hovering ? 0 : 1)
                }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.45)
                            HStack(spacing: 14) {
                                switch item {
                                case .screenshot:
                                    quickAction(icon: "rectangle.and.pencil.and.ellipsis",
                                                help: "Annotate", action: onOpen)
                                    quickAction(icon: "doc.on.doc", help: "Copy", action: onCopy)
                                    quickAction(icon: "pin", help: "Pin to screen", action: onPin)
                                    quickAction(icon: "trash", help: "Delete", action: onDelete)
                                case .recording:
                                    quickAction(icon: "movieclapper", help: "Open in Studio Editor", action: onOpen)
                                    quickAction(icon: "folder", help: "Reveal in Finder", action: onReveal)
                                    quickAction(icon: "trash", help: "Move to Trash", action: onDelete)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.25),
                        radius: hovering ? 14 : 8, y: 4)
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
        .help(item.isRecording
              ? "Click to open in the studio editor, or drag into another app"
              : "Click to annotate, or drag into another app")
        .task(id: item.id) { await loadThumbnail() }
    }

    private func quickAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var captionIcon: String {
        switch item {
        case .screenshot(let screenshot): return screenshot.mode.systemImage
        case .recording: return "video.fill"
        }
    }

    private var caption: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let age = formatter.localizedString(for: item.createdAt, relativeTo: Date())
        if case .recording(let recording) = item {
            let length = recording.duration > 0 ? recording.duration : duration
            if length > 0 { return "\(age) · \(RecordingPoster.label(seconds: length))" }
        }
        return age
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        switch item {
        case .screenshot(let screenshot):
            thumbnail = NSImage(contentsOf: screenshot.imageURL)
        case .recording(let recording):
            let poster = await RecordingPoster.load(for: recording.videoURL)
            duration = poster.duration
            if let image = poster.image {
                thumbnail = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}
