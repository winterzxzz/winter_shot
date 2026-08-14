import SwiftUI

/// The app's main window, BridgeShot-style: captures library on the left,
/// editor canvas on the right with capture buttons in the header.
struct MainWindowView: View {
    @StateObject private var viewModel: MainViewModel
    @StateObject private var updateChecker: UpdateChecker
    @ObservedObject private var selectionBus: SelectionBus
    private let container: DIContainer

    init(container: DIContainer) {
        _viewModel = StateObject(wrappedValue: MainViewModel(container: container))
        _updateChecker = StateObject(wrappedValue: UpdateChecker(service: container.updateService))
        self.selectionBus = container.selectionBus
        self.container = container
    }

    var body: some View {
        NavigationSplitView {
            CapturesSidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ForEach(CaptureMode.allCases) { mode in
                    Button {
                        viewModel.capture(mode: mode)
                    } label: {
                        Image(systemName: mode.systemImage)
                    }
                    .help(mode.label)
                }
            }
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(nsImage: AppIcon.full)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("WinterShot")
                        .font(.system(size: 15, weight: .bold))
                    versionBadge
                }
                .padding(.horizontal, 10)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.reload()
            consumePending()
        }
        .onReceive(selectionBus.$pending) { _ in consumePending() }
        .task { await updateChecker.checkOnce() }
    }

    /// Version label plus the update button when GitHub has a newer release.
    @ViewBuilder
    private var versionBadge: some View {
        Text("v\(updateChecker.currentVersion)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.08), in: Capsule())
            .help(updateBadgeHelp)

        if case .available(let release) = updateChecker.state {
            Button {
                updateChecker.update()
            } label: {
                Label("Update to \(release.tagName)", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("A newer version is on GitHub — click to download and install it")
        }

        if case .updating(let status) = updateChecker.state {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.system(size: 11, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())
            .help("Installing the update — the app restarts when it's done")
        }
    }

    private var updateBadgeHelp: String {
        switch updateChecker.state {
        case .upToDate: return "You're on the latest release."
        case .checking: return "Checking GitHub for updates…"
        default: return "Installed version"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = viewModel.selected {
            EditorView(screenshot: selected, container: container) {
                viewModel.deselect()
            }
            .id(selected.id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppIcon.full)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text("Capture something, or pick one from the library")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func consumePending() {
        guard let pending = selectionBus.pending else { return }
        selectionBus.pending = nil
        viewModel.select(pending)
    }
}
