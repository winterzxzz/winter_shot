import SwiftUI

/// Right-hand sidebar: tool options and the list of live annotations.
struct EditorInspectorView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Tool") {
                VStack(alignment: .leading, spacing: 12) {
                    colorSwatches
                    HStack {
                        Text("Width")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $viewModel.lineWidth, in: 1...16)
                    }
                }
                .padding(4)
            }

            GroupBox("Annotations (\(viewModel.annotations.count))") {
                if viewModel.annotations.isEmpty {
                    Text("Pick a tool and drag on the image.\nEverything stays editable — the\noriginal capture is never modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                } else {
                    annotationList
                }
            }

            if let selectedIndex = viewModel.selectedAnnotationIndex,
               viewModel.annotations[selectedIndex].tool == .text {
                GroupBox("Text") {
                    TextField("Label", text: Binding(
                        get: { viewModel.annotations[selectedIndex].text },
                        set: { viewModel.updateSelectedText($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .padding(4)
                }
            }

            Spacer()

            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { _, preset in
                Button {
                    viewModel.currentColor = preset
                } label: {
                    Circle()
                        .fill(preset.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                viewModel.currentColor == preset ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: viewModel.currentColor == preset ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var annotationList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(viewModel.annotations) { annotation in
                    HStack {
                        Image(systemName: annotation.tool.systemImage)
                            .frame(width: 18)
                        Text(rowTitle(for: annotation))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            viewModel.delete(annotation)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(annotation.id == viewModel.selectedAnnotationID
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectedAnnotationID = annotation.id
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func rowTitle(for annotation: Annotation) -> String {
        switch annotation.tool {
        case .text: return annotation.text.isEmpty ? "Text" : annotation.text
        case .counter: return "Counter \(annotation.number)"
        default: return annotation.tool.label
        }
    }
}
