import SwiftUI
import AppKit

/// Grid of past captures. Double-click to reopen in the editor —
/// annotations come back fully editable from the sidecar.
struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    init(container: DIContainer) {
        _viewModel = StateObject(wrappedValue: HistoryViewModel(container: container))
    }

    var body: some View {
        Group {
            if viewModel.screenshots.isEmpty {
                ContentUnavailableView(
                    "No Screenshots Yet",
                    systemImage: "camera.viewfinder",
                    description: Text("Capture something from the menu-bar icon and it will show up here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.screenshots) { screenshot in
                            HistoryCell(screenshot: screenshot)
                                .onTapGesture(count: 2) { open(screenshot) }
                                .contextMenu {
                                    Button("Open in Editor") { open(screenshot) }
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([screenshot.imageURL])
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        viewModel.delete(screenshot)
                                    }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("History")
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { viewModel.reload() }
        .toolbar {
            Button {
                viewModel.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func open(_ screenshot: Screenshot) {
        openWindow(value: screenshot)
    }
}

private struct HistoryCell: View {
    let screenshot: Screenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = NSImage(contentsOf: screenshot.imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1))
            )

            Text(screenshot.filename)
                .font(.caption)
                .lineLimit(1)
            Text(screenshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
