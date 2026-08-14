import SwiftUI

/// The floating tool pill: select cursor, the nine annotation tools, color
/// and width, undo/redo, extras menu, Copy, and Done.
struct EditorToolbarView: View {
    @ObservedObject var viewModel: EditorViewModel
    let onDone: () -> Void
    @State private var showColorPopover = false

    var body: some View {
        HStack(spacing: 4) {
            toolButton(icon: "cursorarrow", label: "Select", isActive: viewModel.selectedTool == nil) {
                viewModel.selectedTool = nil
            }

            pillDivider

            ForEach(AnnotationTool.allCases) { tool in
                toolButton(icon: tool.systemImage, label: tool.label,
                           isActive: viewModel.selectedTool == tool) {
                    viewModel.selectedTool = tool
                }
            }

            pillDivider

            Button {
                showColorPopover.toggle()
            } label: {
                Circle()
                    .fill(viewModel.currentColor.swiftUIColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Color & width")
            .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
                colorPopover
            }

            toolButton(icon: "crop", label: "Crop", isActive: viewModel.isCropping) {
                if viewModel.isCropping {
                    viewModel.cancelCrop()
                } else {
                    viewModel.enterCropMode()
                }
            }

            pillDivider

            iconButton(icon: "arrow.uturn.backward", label: "Undo", disabled: !viewModel.canUndo) {
                viewModel.undo()
            }
            .keyboardShortcut("z", modifiers: .command)

            iconButton(icon: "arrow.uturn.forward", label: "Redo", disabled: !viewModel.canRedo) {
                viewModel.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            pillDivider

            iconButton(icon: "text.viewfinder", label: "Copy Text (OCR)") {
                Task { await viewModel.copyRecognizedText() }
            }

            iconButton(icon: "pin", label: "Pin to Screen") {
                viewModel.pinToScreen()
            }

            Menu {
                Button("Export PNG…") { viewModel.exportPNG() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Reset Crop") { viewModel.resetCrop() }
                    .disabled(viewModel.crop == nil)
                Button("Delete Selected Annotation") { viewModel.deleteSelected() }
                    .disabled(viewModel.selectedAnnotationID == nil)
                Button("Clear All Annotations", role: .destructive) { viewModel.clearAll() }
                    .disabled(viewModel.annotations.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)

            Button {
                viewModel.copyFlattenedToPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var colorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        viewModel.currentColor = preset
                    } label: {
                        Circle()
                            .fill(preset.swiftUIColor)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().strokeBorder(
                                    viewModel.currentColor == preset ? Color.accentColor : Color.primary.opacity(0.2),
                                    lineWidth: viewModel.currentColor == preset ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Width")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $viewModel.lineWidth, in: 1...16)
                    .frame(width: 140)
            }
        }
        .padding(14)
    }

    private func toolButton(icon: String, label: String, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? .white.opacity(0.22) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func iconButton(icon: String, label: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(label)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }
}
