import SwiftUI
import AVKit

/// Post-recording window: raw preview on the left, Screen Studio-style export
/// options on the right. The polish (backdrop, auto-zoom, smooth cursor) is
/// applied only on export — the recording itself stays raw and reusable.
struct RecordingExportView: View {
    let recording: Recording
    let events: RecordingEventLog

    @State private var options = RecordingExportOptions()
    @State private var player: AVPlayer
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportError: String?

    init(recording: Recording, events: RecordingEventLog) {
        self.recording = recording
        self.events = events
        _player = State(initialValue: AVPlayer(url: recording.videoURL))
    }

    var body: some View {
        HSplitView {
            VideoPlayer(player: player)
                .frame(minWidth: 480, minHeight: 360)
                .layoutPriority(1)

            optionsPanel
                .frame(width: 300)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    section("Background") {
                        presetGrid
                        if options.background.isEnabled {
                            LabeledSlider(label: "Padding", value: $options.background.padding, in: 0...0.2)
                            LabeledSlider(label: "Corners", value: $options.background.cornerRadius, in: 0...64)
                            Toggle("Shadow", isOn: $options.background.shadow)
                        }
                    }

                    section("Camera") {
                        Toggle("Auto-zoom on clicks", isOn: $options.autoZoom)
                        if options.autoZoom {
                            LabeledSlider(label: "Zoom", value: $options.zoomLevel, in: 1.2...3)
                        }
                    }

                    section("Cursor") {
                        Toggle("Smooth cursor", isOn: $options.showCursor)
                        if options.showCursor {
                            LabeledSlider(label: "Size", value: $options.cursorScale, in: 1...4)
                            Toggle("Click ripples", isOn: $options.clickRipples)
                        }
                    }
                }
                .padding(16)
            }

            Divider()
            footer
                .padding(16)
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export Recording")
                .font(.headline)
            Text(String(format: "%.1fs · %d clicks · %.0f×%.0f",
                        recording.duration,
                        events.clicks.count,
                        recording.frameSize.width,
                        recording.frameSize.height))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(BackgroundPreset.allCases) { preset in
                Button {
                    options.background.preset = preset
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: preset == .none ? [Color(.quaternaryLabelColor)] : preset.gradientColors,
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(height: 34)
                        .overlay {
                            if preset == .none {
                                Image(systemName: "slash.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(options.background.preset == preset ? Color.accentColor : .clear,
                                              lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(preset.rawValue.capitalized)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExporting {
                ProgressView(value: progress) {
                    Text("Exporting… \(Int(progress * 100))%")
                        .font(.caption)
                }
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Reveal Raw File") {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
                }
                Spacer()
                Button {
                    export()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = recording.videoURL
            .deletingPathExtension().lastPathComponent + "-polished.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        progress = 0
        exportError = nil
        player.pause()

        let useCase = DIContainer.shared.exportRecordingUseCase
        let recording = recording
        let events = events
        let options = options
        Task {
            do {
                try await useCase.execute(recording: recording,
                                          events: events,
                                          options: options,
                                          to: destination) { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    isExporting = false
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

/// Compact slider row with a leading label.
private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(label: String, value: Binding<Double>, in range: ClosedRange<Double>) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}
