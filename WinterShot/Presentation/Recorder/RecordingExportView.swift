import SwiftUI
import AVFoundation

/// Screen Studio-style editor window: dark chrome, a big composited preview
/// on a canvas, a click-timeline underneath, and an inspector of option cards
/// on the right. The preview runs through the same RecordingCompositor as the
/// exporter — what you see is exactly what ships.
struct RecordingExportView: View {
    let recording: Recording
    let events: RecordingEventLog

    @State private var options = RecordingExportOptions()
    @StateObject private var transport: PreviewTransport
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportError: String?

    private static let chrome = Color(red: 0.086, green: 0.086, blue: 0.094)
    private static let canvas = Color(red: 0.055, green: 0.055, blue: 0.063)
    private static let panel = Color(red: 0.114, green: 0.114, blue: 0.125)

    init(recording: Recording, events: RecordingEventLog) {
        self.recording = recording
        self.events = events
        _transport = StateObject(wrappedValue: PreviewTransport(recording: recording))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.black.opacity(0.6))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        Self.canvas
                        CompositedPreview(transport: transport, events: events, options: options)
                            .padding(20)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    }
                    timelineBar
                }
                Divider().overlay(Color.black.opacity(0.6))
                inspector
            }
        }
        .background(Self.chrome)
        .preferredColorScheme(.dark)
        .onAppear { transport.play() }
        .onDisappear { transport.player.pause() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.filename)
                    .font(.system(size: 13, weight: .semibold))
                Text(String(format: "%.1fs · %d clicks · %.0f×%.0f",
                            recording.duration,
                            events.clicks.count,
                            recording.frameSize.width,
                            recording.frameSize.height))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isExporting {
                ProgressView(value: progress)
                    .frame(width: 140)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 260)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal raw recording")

            Button {
                export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .keyboardShortcut(.defaultAction)
            .disabled(isExporting)
        }
        .padding(.trailing, 14)
        .padding(.leading, 84) // clear the traffic lights (fullSizeContentView)
        .frame(height: 52)
    }

    // MARK: - Timeline

    private var timelineBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    transport.togglePlayback()
                } label: {
                    Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)

                TimelineStrip(duration: max(transport.duration, 0.1),
                              time: transport.time,
                              zoomWindows: CameraRig.zoomWindows(events: events),
                              clicks: events.clicks.map { $0.t - events.firstFrameTime },
                              zoomEnabled: options.autoZoom) { t in
                    transport.seek(to: t)
                }
                .frame(height: 36)

                Text(timecode(transport.time) + " / " + timecode(transport.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Self.chrome)
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                card("Background", icon: "photo.fill") {
                    presetGrid
                    if options.background.isEnabled {
                        LabeledSlider(label: "Padding", value: $options.background.padding, in: 0...0.2)
                        LabeledSlider(label: "Corners", value: $options.background.cornerRadius, in: 0...64)
                        toggleRow("Shadow", isOn: $options.background.shadow)
                    }
                }

                card("Zoom", icon: "plus.magnifyingglass") {
                    toggleRow("Auto-zoom on clicks", isOn: $options.autoZoom)
                    if options.autoZoom {
                        LabeledSlider(label: "Depth", value: $options.zoomLevel, in: 1.2...3)
                    }
                }

                card("Cursor", icon: "cursorarrow.motionlines") {
                    toggleRow("Smooth cursor", isOn: $options.showCursor)
                    if options.showCursor {
                        LabeledSlider(label: "Size", value: $options.cursorScale, in: 1...4)
                        toggleRow("Click ripples", isOn: $options.clickRipples)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 288)
        .background(Self.panel)
    }

    private func card(_ title: String, icon: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.07)))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(BackgroundPreset.allCases) { preset in
                presetSwatch(preset)
            }
        }
    }

    private func presetSwatch(_ preset: BackgroundPreset) -> some View {
        let selected = options.background.preset == preset
        return Button {
            options.background.preset = preset
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: preset == .none ? [Color.white.opacity(0.08)] : preset.gradientColors,
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
                        .strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .help(preset.rawValue.capitalized)
    }

    // MARK: - Export

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = recording.videoURL
            .deletingPathExtension().lastPathComponent + "-polished.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        progress = 0
        exportError = nil
        transport.player.pause()

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

// MARK: - Timeline strip

/// Scrubbable timeline: zoom windows drawn as segments, clicks as dots, and
/// a draggable playhead — a light take on Screen Studio's timeline.
private struct TimelineStrip: View {
    let duration: Double
    let time: Double
    let zoomWindows: [(start: Double, end: Double)]
    let clicks: [Double]
    let zoomEnabled: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))

                if zoomEnabled {
                    ForEach(Array(zoomWindows.enumerated()), id: \.offset) { _, window in
                        let x0 = x(for: window.start, width: width)
                        let x1 = x(for: min(window.end, duration), width: width)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.30))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor.opacity(0.55)))
                            .frame(width: max(x1 - x0, 4))
                            .padding(.vertical, 5)
                            .offset(x: x0)
                    }
                }

                ForEach(Array(clicks.enumerated()), id: \.offset) { _, t in
                    Circle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 4, height: 4)
                        .offset(x: x(for: t, width: width) - 2)
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: x(for: time, width: width) - 1)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(max(value.location.x / width, 0), 1)
                        onSeek(f * duration)
                    }
            )
        }
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(max(t / duration, 0), 1)) * width
    }
}

/// Compact slider row with a leading label and live value.
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
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(String(format: "%.2f", value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}
