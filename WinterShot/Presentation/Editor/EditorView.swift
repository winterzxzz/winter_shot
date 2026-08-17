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
                if viewModel.isCropping {
                    cropBar
                } else if viewModel.selectedAnnotation?.tool == .text {
                    textEditor
                }
                Spacer()
                if let message = viewModel.statusMessage {
                    statusToast(message)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                zoomBar
            }
            .padding(.top, 14)
            .padding(.bottom, 18)
            .animation(.easeOut(duration: 0.2), value: viewModel.statusMessage)
        }
        .onAppear {
            // Test hook: run OCR as soon as the editor opens (screenshots).
            if ProcessInfo.processInfo.environment["WS_EDITOR_OCR"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task { await viewModel.recognizeText() }
                }
            }
        }
        .onDeleteCommand { viewModel.deleteSelected() }
        .onExitCommand {
            if viewModel.isCropping { viewModel.cancelCrop() }
        }
    }

    private func statusToast(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .padding(.bottom, 4)
            .environment(\.colorScheme, .dark)
    }

    private var cropBar: some View {
        HStack(spacing: 10) {
            Text("Drag to crop")
                .foregroundStyle(.secondary)

            Button {
                viewModel.applyCrop()
            } label: {
                Label("Apply", systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.cropDraft == nil)
            .opacity(viewModel.cropDraft == nil ? 0.5 : 1)
            .keyboardShortcut(.return, modifiers: [])

            Button {
                viewModel.cancelCrop()
            } label: {
                Label("Cancel (Esc)", systemImage: "xmark")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
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
        .environment(\.colorScheme, .dark)
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
        .environment(\.colorScheme, .dark)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 16)
    }

    private var sizeLabel: String {
        let visible = viewModel.crop ?? CGRect(origin: .zero, size: viewModel.imagePixelSize)
        var label = "\(Int(visible.width)) × \(Int(visible.height)) px"
        if viewModel.crop != nil { label += " (cropped)" }
        return label
    }
}
