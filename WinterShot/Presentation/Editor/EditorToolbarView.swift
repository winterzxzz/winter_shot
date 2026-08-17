import SwiftUI

/// The floating tool pill: select cursor, the nine annotation tools, color
/// and width, undo/redo, extras menu, Copy, and Done.
struct EditorToolbarView: View {
    @ObservedObject var viewModel: EditorViewModel
    let onDone: () -> Void
    @State private var showColorPopover = false
    @State private var showBeautifyPopover = false

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

            toolButton(icon: "wand.and.stars", label: "Background Beautify",
                       isActive: viewModel.backdrop.isEnabled) {
                showBeautifyPopover.toggle()
            }
            .popover(isPresented: $showBeautifyPopover, arrowEdge: .bottom) {
                BeautifyPopover(viewModel: viewModel)
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

            iconButton(icon: "text.viewfinder", label: "Recognize Text (OCR)") {
                Task { await viewModel.recognizeText() }
            }
            .popover(isPresented: $viewModel.showOCRResult, arrowEdge: .bottom) {
                OCRResultPopover(viewModel: viewModel)
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
        // The pill is a dark HUD in every theme; keep its text/icons light.
        .environment(\.colorScheme, .dark)
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

/// Background beautify settings: backdrop preset, padding, corners, shadow.
private struct BeautifyPopover: View {
    @ObservedObject var viewModel: EditorViewModel

    private var style: Binding<BackdropStyle> {
        Binding(get: { viewModel.backdrop }, set: { viewModel.updateBackdrop($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(BackgroundPreset.allCases) { preset in
                    presetSwatch(preset)
                }
            }

            HStack {
                Text("Padding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Slider(value: style.padding, in: 0.02...0.2)
                    .frame(width: 150)
            }
            .disabled(!viewModel.backdrop.isEnabled)

            HStack {
                Text("Corners")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Slider(value: style.cornerRadius, in: 0...120)
                    .frame(width: 150)
            }
            .disabled(!viewModel.backdrop.isEnabled)

            Toggle("Shadow", isOn: style.shadow)
                .font(.caption)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.backdrop.isEnabled)
        }
        .padding(14)
    }

    private func presetSwatch(_ preset: BackgroundPreset) -> some View {
        Button {
            var next = viewModel.backdrop
            next.preset = preset
            viewModel.updateBackdrop(next)
        } label: {
            Group {
                if preset == .none {
                    Circle()
                        .fill(.primary.opacity(0.08))
                        .overlay(Image(systemName: "slash.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary))
                } else {
                    Circle()
                        .fill(LinearGradient(colors: preset.gradientColors,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                }
            }
            .frame(width: 24, height: 24)
            .overlay(
                Circle().strokeBorder(
                    viewModel.backdrop.preset == preset ? Color.accentColor : .primary.opacity(0.2),
                    lineWidth: viewModel.backdrop.preset == preset ? 2 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .help(preset.rawValue.capitalized)
    }
}


/// The OCR result: recognized text (selectable, scrollable), a character
/// count, and Copy — text is also copied automatically when recognition
/// finishes.
private struct OCRResultPopover: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recognized text", systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let text = viewModel.ocrText, !text.isEmpty {
                    Text("\(text.count) characters")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                if viewModel.isRecognizingText {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Recognizing text…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else if let error = viewModel.ocrError {
                    Text("OCR failed: \(error)")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                } else if let text = viewModel.ocrText, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                    .frame(height: min(240, max(96, CGFloat(text.split(separator: "\n").count) * 17 + 20)))
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("No text found in this screenshot.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .font(.system(size: 12))
            HStack {
                if viewModel.crop != nil {
                    Text("Limited to the cropped area")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { viewModel.copyRecognizedText() }
                    .disabled((viewModel.ocrText ?? "").isEmpty)
                    .keyboardShortcut("c", modifiers: .command)
                Button("Done") { viewModel.showOCRResult = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
