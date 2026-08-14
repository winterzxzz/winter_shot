import SwiftUI

/// The annotation editor pane: canvas with a floating tool pill on top and
/// a floating zoom bar at the bottom, BridgeShot-style.
struct EditorView: View {
    @StateObject private var viewModel: EditorViewModel
    let onDone: () -> Void

    init(screenshot: Screenshot, container: DIContainer, onDone: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(screenshot: screenshot, container: container))
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            EditorCanvasView(viewModel: viewModel)

            VStack(spacing: 10) {
                EditorToolbarView(viewModel: viewModel, onDone: onDone)
                if viewModel.selectedAnnotation?.tool == .text {
                    textEditor
                }
                Spacer()
                zoomBar
            }
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .onDeleteCommand { viewModel.deleteSelected() }
    }

    private var textEditor: some View {
        TextField("Label", text: Binding(
            get: { viewModel.selectedAnnotation?.text ?? "" },
            set: { viewModel.updateSelectedText($0) }
        ))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }

    private var zoomBar: some View {
        HStack(spacing: 0) {
            Text(sizeLabel)
                .foregroundStyle(.secondary)
                .padding(.trailing, 14)

            barDivider

            Button { viewModel.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)

            Text(viewModel.zoomLabel)
                .frame(width: 44)
                .fontWeight(.medium)

            Button { viewModel.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)

            barDivider

            Button("Fit") { viewModel.zoomToFit() }
                .buttonStyle(.plain)
                .fontWeight(viewModel.zoomMode == .fit ? .semibold : .regular)
                .padding(.horizontal, 12)

            Button("100%") { viewModel.zoomToActual() }
                .buttonStyle(.plain)
                .fontWeight(viewModel.zoomMode == .percent(1) ? .semibold : .regular)
                .padding(.trailing, 4)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 16)
    }

    private var sizeLabel: String {
        "\(Int(viewModel.imagePixelSize.width)) × \(Int(viewModel.imagePixelSize.height)) px"
    }
}
