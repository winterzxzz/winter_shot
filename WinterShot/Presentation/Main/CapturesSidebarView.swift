import SwiftUI
import AppKit

/// Left sidebar: the captures library. Cards show a thumbnail with hover
/// quick actions, name, age, and pixel size. Footer: folder, refresh, settings.
struct CapturesSidebarView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.screenshots.isEmpty {
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
            Text("\(viewModel.screenshots.count)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: Capsule())
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
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
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
                ForEach(viewModel.screenshots) { screenshot in
                    CaptureCard(
                        screenshot: screenshot,
                        isSelected: viewModel.selected?.id == screenshot.id,
                        onOpen: { viewModel.select(screenshot) },
                        onCopy: { viewModel.copyFlattened(screenshot) },
                        onPin: { viewModel.pin(screenshot) },
                        onDelete: { viewModel.delete(screenshot) }
                    )
                    .contextMenu {
                        Button("Open in Editor") { viewModel.select(screenshot) }
                        Button("Copy Image") { viewModel.copyFlattened(screenshot) }
                        Button("Pin to Screen") { viewModel.pin(screenshot) }
                        Button("Reveal in Finder") { viewModel.revealInFinder(screenshot) }
                        Divider()
                        Button("Delete", role: .destructive) { viewModel.delete(screenshot) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
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

            Button { viewModel.openCapturesFolder() } label: {
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
    let screenshot: Screenshot
    let isSelected: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var pixelSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 1)
                )
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
                        .help("Delete")
                        .padding(6)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hovering || isSelected {
                        HStack(spacing: 14) {
                            quickAction(icon: "rectangle.and.pencil.and.ellipsis", help: "Annotate", action: onOpen)
                            quickAction(icon: "doc.on.doc", help: "Copy", action: onCopy)
                            quickAction(icon: "pin", help: "Pin to screen", action: onPin)
                            quickAction(icon: "trash", help: "Delete", action: onDelete)
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
        .onTapGesture(perform: onOpen)
        .task(id: screenshot.id) { loadThumbnail() }
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
        "Screenshot " + screenshot.createdAt.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
    }

    private var subtitle: String {
        let age = RelativeDateTimeFormatter()
        age.unitsStyle = .abbreviated
        let ageText = age.localizedString(for: screenshot.createdAt, relativeTo: Date())
        guard pixelSize != .zero else { return ageText }
        return "\(ageText) · \(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }

    private func loadThumbnail() {
        guard thumbnail == nil, let image = NSImage(contentsOf: screenshot.imageURL) else { return }
        if let rep = image.representations.first {
            pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        thumbnail = image
    }
}
