import SwiftUI
import AppKit

/// Left sidebar: the capture library — screenshots and recordings together,
/// newest first. Cards show a thumbnail with hover quick actions, name, age
/// and pixel size (a recording adds its length). Footer: folder, refresh,
/// settings.
struct CapturesSidebarView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider().opacity(0.4)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Captures")
                .font(.system(size: 15, weight: .bold))
            Text("\(viewModel.items.count)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.1), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(nsImage: AppIcon.full)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .opacity(0.7)
            Text("No captures yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.items) { item in
                    CaptureCard(
                        item: item,
                        isSelected: viewModel.selected?.id == item.id,
                        onSelect: { viewModel.select(item) },
                        onEdit: { edit(item) },
                        onCopy: { if case .screenshot(let shot) = item { viewModel.copyFlattened(shot) } },
                        onPin: { if case .screenshot(let shot) = item { viewModel.pin(shot) } },
                        onReveal: { viewModel.revealInFinder(item) },
                        onDelete: { viewModel.delete(item) }
                    )
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    /// A screenshot edits in place in the detail pane; a recording opens the
    /// studio editor window (and shows in the detail pane behind it).
    private func edit(_ item: CaptureItem) {
        viewModel.select(item)
        if case .recording(let recording) = item {
            viewModel.openInStudio(recording)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: CaptureItem) -> some View {
        switch item {
        case .screenshot(let screenshot):
            Button("Open in Editor") { viewModel.select(item) }
            Button("Copy Image") { viewModel.copyFlattened(screenshot) }
            Button("Pin to Screen") { viewModel.pin(screenshot) }
            Button("Reveal in Finder") { viewModel.revealInFinder(item) }
            Divider()
            Button("Delete", role: .destructive) { viewModel.delete(item) }
        case .recording:
            Button("Open in Studio Editor") { edit(item) }
            Button("Reveal in Finder") { viewModel.revealInFinder(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { viewModel.delete(item) }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button { viewModel.openCapturesFolder() } label: {
                Image(systemName: "folder")
            }
            .help("Open captures folder")

            Button { viewModel.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct CaptureCard: View {
    let item: CaptureItem
    let isSelected: Bool
    /// Click: show the item in the detail pane.
    let onSelect: () -> Void
    /// Double-click / quick action: open the editor for it.
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var pixelSize: CGSize = .zero
    @State private var duration: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // Bounded base so wide thumbnails can't blow out the card layout;
                // the image only ever paints inside the clipped overlay.
                Color.primary.opacity(0.06)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else if item.isRecording {
                        Image(systemName: "film")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : .primary.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if item.isRecording, displayDuration > 0 {
                        Label(RecordingPoster.label(seconds: displayDuration), systemImage: "play.fill")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering || isSelected {
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.black.opacity(0.72), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(item.isRecording ? "Move to Trash" : "Delete")
                        .padding(6)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hovering || isSelected {
                        HStack(spacing: 14) {
                            switch item {
                            case .screenshot:
                                quickAction(icon: "rectangle.and.pencil.and.ellipsis", help: "Annotate", action: onEdit)
                                quickAction(icon: "doc.on.doc", help: "Copy", action: onCopy)
                                quickAction(icon: "pin", help: "Pin to screen", action: onPin)
                                quickAction(icon: "trash", help: "Delete", action: onDelete)
                            case .recording:
                                quickAction(icon: "movieclapper", help: "Open in Studio Editor", action: onEdit)
                                quickAction(icon: "folder", help: "Reveal in Finder", action: onReveal)
                                quickAction(icon: "trash", help: "Move to Trash", action: onDelete)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.72), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.12), value: hovering)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDoubleTap(if: item.isRecording, perform: onEdit)
        .onTapGesture(perform: onSelect)
        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
        .help(item.isRecording
              ? "Click to preview, double-click to open in the studio editor, or drag into another app"
              : "Click to annotate, or drag into another app")
        .task(id: item.id) { await loadThumbnail() }
    }

    private func quickAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var title: String {
        (item.isRecording ? "Recording " : "Screenshot ") + item.createdAt.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
    }

    /// The sidecar's length when it has one, else what the poster loader read.
    private var displayDuration: Double {
        if case .recording(let recording) = item, recording.duration > 0 { return recording.duration }
        return duration
    }

    private var subtitle: String {
        let age = RelativeDateTimeFormatter()
        age.unitsStyle = .abbreviated
        var parts = [age.localizedString(for: item.createdAt, relativeTo: Date())]
        if item.isRecording, displayDuration > 0 {
            parts.append(RecordingPoster.label(seconds: displayDuration))
        }
        if pixelSize != .zero {
            parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))")
        }
        return parts.joined(separator: " · ")
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        switch item {
        case .screenshot(let screenshot):
            guard let image = NSImage(contentsOf: screenshot.imageURL) else { return }
            if let rep = image.representations.first {
                pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            thumbnail = image
        case .recording(let recording):
            let poster = await RecordingPoster.load(for: recording.videoURL)
            duration = poster.duration
            if recording.frameSize != .zero {
                pixelSize = recording.frameSize
            } else if let image = poster.image {
                pixelSize = CGSize(width: image.width, height: image.height)
            }
            if let image = poster.image {
                thumbnail = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func onDoubleTap(if enabled: Bool, perform action: @escaping () -> Void) -> some View {
        if enabled {
            onTapGesture(count: 2, perform: action)
        } else {
            self
        }
    }
}
