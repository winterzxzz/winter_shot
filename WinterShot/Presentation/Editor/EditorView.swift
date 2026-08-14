import SwiftUI

/// The annotation editor window for a single screenshot.
struct EditorView: View {
    @StateObject private var viewModel: EditorViewModel

    init(screenshot: Screenshot, container: DIContainer) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(screenshot: screenshot, container: container))
    }

    var body: some View {
        HStack(spacing: 0) {
            EditorCanvasView(viewModel: viewModel)
                .frame(minWidth: 480, minHeight: 360)
            Divider()
            EditorInspectorView(viewModel: viewModel)
        }
        .navigationTitle(viewModel.screenshot.filename)
        .toolbar {
            ToolbarItemGroup {
                toolPicker
            }

            ToolbarItemGroup {
                Button {
                    viewModel.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo)
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    viewModel.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!viewModel.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button(role: .destructive) {
                    viewModel.deleteSelected()
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(viewModel.selectedAnnotationID == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }

            ToolbarItemGroup {
                Button {
                    Task { await viewModel.copyRecognizedText() }
                } label: {
                    Label("Copy Text (OCR)", systemImage: "text.viewfinder")
                }
                .help("Recognize text on-device and copy it")

                Button {
                    viewModel.pinToScreen()
                } label: {
                    Label("Pin to Screen", systemImage: "pin")
                }

                Button {
                    viewModel.copyFlattenedToPasteboard()
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    viewModel.exportPNG()
                } label: {
                    Label("Export PNG", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private var toolPicker: some View {
        Picker("Tool", selection: $viewModel.selectedTool) {
            ForEach(AnnotationTool.allCases) { tool in
                Label(tool.label, systemImage: tool.systemImage)
                    .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .help("Annotation tool")
    }
}
