import SwiftUI

/// The app's main window, BridgeShot-style: captures library on the left,
/// editor canvas on the right with capture buttons in the header.
struct MainWindowView: View {
    @StateObject private var viewModel: MainViewModel
    @ObservedObject private var selectionBus: SelectionBus
    private let container: DIContainer

    init(container: DIContainer) {
        _viewModel = StateObject(wrappedValue: MainViewModel(container: container))
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
                Text("WinterShot")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.leading, 6)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.reload()
            consumePending()
        }
        .onReceive(selectionBus.$pending) { _ in consumePending() }
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
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
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
