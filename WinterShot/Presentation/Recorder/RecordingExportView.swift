import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Screen Studio-style editor window: a 60 pt top bar (project actions,
/// title, undo/redo, Presets, panel visibility, Export), an aspect-ratio
/// toolbar over the composited preview with transport controls beneath, a
/// vertical tool rail that swaps the 340 pt settings panel (Background &
/// Screen, Cursor, Animations), and a timeline underneath with the clip and
/// the zoom ranges the auto-zoom camera will follow. The preview runs through
/// the same RecordingCompositor as the exporter — what you see is what ships.
struct RecordingExportView: View {
    let recording: Recording
    let events: RecordingEventLog

    enum Panel: String, CaseIterable, Identifiable {
        case background, cursor, animations
        var id: String { rawValue }

        var title: String {
            switch self {
            case .background: return "Background & Screen"
            case .cursor: return "Cursor"
            case .animations: return "Animations"
            }
        }

        var icon: String {
            switch self {
            case .background: return "square.dashed.inset.filled"
            case .cursor: return "cursorarrow"
            case .animations: return "point.topleft.down.to.point.bottomright.curvepath.fill"
            }
        }
    }

    /// Built-in looks, like Screen Studio's Presets menu.
    struct Preset: Identifiable {
        let id: String
        let name: String
        let apply: (inout RecordingExportOptions) -> Void

        static let all: [Preset] = [
            Preset(id: "default", name: "Screen Studio default") { $0 = RecordingExportOptions() },
            Preset(id: "clean", name: "Clean") {
                $0.background.kind = .gradient
                $0.background.gradient = GradientPreset.all.first { $0.id == "graphite" }?.colors ?? $0.background.gradient
                $0.background.padding = 0.06
                $0.background.cornerRadius = 8
                $0.background.shadow = 0.4
                $0.motionBlur = 0.6
            },
            Preset(id: "cinematic", name: "Cinematic") {
                $0.background.kind = .wallpaper
                $0.background.wallpaperID = "solar-navy"
                $0.background.padding = 0.12
                $0.background.cornerRadius = 16
                $0.background.shadow = 1
                $0.zoomLevel = 2.4
                $0.motionBlur = 1
            },
            Preset(id: "pastel", name: "Pastel") {
                $0.background.kind = .wallpaper
                $0.background.wallpaperID = "spring-lilac"
                $0.background.blur = 0.2
                $0.background.padding = 0.10
                $0.background.cornerRadius = 14
                $0.background.shadow = 0.6
            },
            Preset(id: "minimal", name: "Minimal") {
                $0.background.kind = .color
                $0.background.color = RGBAColor(r: 0.07, g: 0.07, b: 0.09)
                $0.background.padding = 0.04
                $0.background.cornerRadius = 8
                $0.background.shadow = 0.3
                $0.autoZoom = false
                $0.clickRipples = false
                $0.motionBlur = 0.5
            },
            Preset(id: "vertical", name: "Vertical for Reels") {
                $0.aspect = .vertical
                $0.background.kind = .wallpaper
                $0.background.wallpaperID = "radial-purple"
                $0.background.padding = 0.08
                $0.background.cornerRadius = 14
            },
        ]
    }

    enum EditMode { case none, crop, mask }

    @State private var options = RecordingExportOptions()
    @State private var panel: Panel = .background
    @State private var showPanels = true
    @State private var editMode: EditMode = .none
    @State private var selectedMaskID: UUID?
    // Crop editor working state (applied on Done).
    @State private var cropDraft: UnitRect = .full
    @State private var cropAspect: CropAspect = .any
    @State private var cropStill: CGImage?
    @State private var wallpaperCategory: String = WallpaperLibrary.shared.categories.first ?? ""
    @State private var videoThumb: CGImage?
    @StateObject private var transport: PreviewTransport
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportError: String?
    @State private var confirmDelete = false

    // Undo/redo over option changes; edits within a short window coalesce
    // (a slider drag is one step).
    @State private var history: [RecordingExportOptions] = [RecordingExportOptions()]
    @State private var historyIndex = 0
    @State private var lastEdit = Date.distantPast
    @State private var restoringHistory = false

    private static let defaults = RecordingExportOptions()

    init(recording: Recording, events: RecordingEventLog) {
        self.recording = recording
        self.events = events
        _transport = StateObject(wrappedValue: PreviewTransport(recording: recording))
        // Test hooks: open on a panel / with options from JSON (used for screenshots).
        let env = ProcessInfo.processInfo.environment
        if let raw = env["WS_EDITOR_PANEL"], let initial = Panel(rawValue: raw) {
            _panel = State(initialValue: initial)
        }
        if let path = env["WS_EDITOR_OPTIONS"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(RecordingExportOptions.self, from: data) {
            _options = State(initialValue: decoded)
            _history = State(initialValue: [decoded])
            if let w = WallpaperLibrary.shared.wallpaper(id: decoded.background.wallpaperID) {
                _wallpaperCategory = State(initialValue: w.category)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    if editMode == .crop {
                        cropToolbar
                    } else {
                        previewToolbar
                    }
                    preview
                    controlsBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPanels {
                    rail
                    sidebar
                }
            }
            .padding(EdgeInsets(top: 4, leading: 14, bottom: 0, trailing: 14))
            if showPanels {
                timeline
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            } else {
                Spacer().frame(height: 14)
            }
        }
        .background(Studio.background)
        // The title bar is transparent and the top bar is drawn here, so lay
        // out over the title-bar region rather than below it (the window
        // controller sizes that region to match the top bar).
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            transport.play()
            // Test hook: open straight into crop / mask mode (screenshots).
            switch ProcessInfo.processInfo.environment["WS_EDITOR_MODE"] {
            case "crop": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { enterCropMode() }
            case "mask":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    enterMaskMode()
                    selectMask(options.masks.first?.id)
                }
            default: break
            }
        }
        .onDisappear { transport.player.pause() }
        .onChange(of: options) { _, new in recordHistory(new) }
        .alert("Move this recording to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The raw recording and its event log will be moved to the Trash.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            // Centered title, like Screen Studio's project name.
            VStack(spacing: 1) {
                Text(recording.filename)
                    .font(Studio.title)
                    .foregroundStyle(Studio.text)
                Text(String(format: "%@ · %d clicks · %.0f×%.0f",
                            timecode(recording.duration, precise: true),
                            events.clicks.count,
                            recording.frameSize.width,
                            recording.frameSize.height))
                    .font(Studio.label)
                    .foregroundStyle(Studio.textTertiary)
            }
            .lineLimit(1)
            .frame(maxWidth: 420)

            HStack(spacing: 4) {
                StudioIconButton(icon: "folder", size: Studio.controlHeight, iconSize: 14,
                                 help: "Reveal raw recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
                }
                StudioIconButton(icon: "trash", size: Studio.controlHeight, iconSize: 14,
                                 help: "Move recording to Trash") {
                    confirmDelete = true
                }
                Spacer()

                if isExporting {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Studio.primary)
                            .frame(width: 110)
                        Text("\(Int(progress * 100))%")
                            .font(Studio.label.monospacedDigit())
                            .foregroundStyle(Studio.textSecondary)
                    }
                    .padding(.trailing, 6)
                }
                if let exportError {
                    Text(exportError)
                        .font(Studio.label)
                        .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                }

                StudioIconButton(icon: "arrow.uturn.backward", size: Studio.controlHeight, iconSize: 14,
                                 help: "Undo (⌘Z)") { undo() }
                    .disabled(historyIndex == 0)
                    .opacity(historyIndex == 0 ? 0.35 : 1)
                    .keyboardShortcut("z", modifiers: [.command])
                StudioIconButton(icon: "arrow.uturn.forward", size: Studio.controlHeight, iconSize: 14,
                                 help: "Redo (⇧⌘Z)") { redo() }
                    .disabled(historyIndex >= history.count - 1)
                    .opacity(historyIndex >= history.count - 1 ? 0.35 : 1)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                topBarDivider
                presetsMenu
                topBarDivider
                StudioIconButton(icon: showPanels ? "eye" : "eye.slash", size: Studio.controlHeight, iconSize: 14,
                                 isActive: !showPanels,
                                 help: showPanels ? "Hide panels for a bigger preview" : "Show panels") {
                    withAnimation(.easeInOut(duration: 0.2)) { showPanels.toggle() }
                }
                StudioButton("Export", icon: "square.and.arrow.up", kind: .primary) {
                    export()
                }
                .disabled(isExporting)
                .opacity(isExporting ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 6)
            }
            .padding(.leading, 96) // clear the traffic lights, inline at x 19–79 (unified toolbar)
            .padding(.trailing, 14)
        }
        .padding(.bottom, 8) // centre the row on the traffic lights (26 pt), not on the 60 pt bar
        .frame(height: 60)
    }

    private var topBarDivider: some View {
        Rectangle()
            .fill(Studio.separator)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
    }

    private var presetsMenu: some View {
        Menu {
            ForEach(Preset.all) { preset in
                Button(preset.name) { applyPreset(preset) }
            }
        } label: {
            Label("Presets", systemImage: "wand.and.stars")
                .font(Studio.controlCopy)
                .foregroundStyle(Studio.text)
                .padding(.leading, 6)
                .frame(height: Studio.controlHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Apply a preset look")
    }

    // MARK: - Preview toolbar & transport

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(OutputAspect.allCases) { aspect in
                    Button {
                        options.aspect = aspect
                    } label: {
                        if aspect == options.aspect {
                            Label("\(aspect.label) — \(aspect.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(aspect.label) — \(aspect.detail)")
                        }
                    }
                }
            } label: {
                Label(options.aspect.label, systemImage: "aspectratio")
                    .font(Studio.controlCopy)
                    .foregroundStyle(Studio.text)
                    .frame(height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Output aspect ratio")

            Menu {
                ForEach(ExportResolution.allCases) { res in
                    Button {
                        options.resolution = res
                    } label: {
                        if res == (options.resolution ?? .native) {
                            Label("\(res.label) — \(res.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(res.label) — \(res.detail)")
                        }
                    }
                }
            } label: {
                Label((options.resolution ?? .native).label, systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(Studio.controlCopy)
                    .foregroundStyle(Studio.text)
                    .frame(height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Export resolution — higher is sharper but makes a bigger file")

            StudioToolButton(title: "Crop", icon: "crop", isActive: false) { enterCropMode() }
                .help("Crop the recording")
            StudioToolButton(title: "Mask", icon: "rectangle.dashed", isActive: editMode == .mask) {
                if editMode == .mask { leaveMaskMode() } else { enterMaskMode() }
            }
            .help("Blur or highlight part of the recording")
            if editMode == .mask {
                // Escape: drop the selection first, then leave mask mode.
                Button("") {
                    if selectedMaskID != nil { selectedMaskID = nil } else { leaveMaskMode() }
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
            }
        }
        .frame(height: 34)
    }

    // MARK: - Crop

    private var frameSize: CGSize { CGSize(width: events.frameWidth, height: events.frameHeight) }

    private var cropToolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Size").font(Studio.label).foregroundStyle(Studio.textTertiary)
                cropField(value: Binding(get: { cropDraft.width * frameSize.width },
                                         set: { setCropSize(width: $0) }))
                Text("×").font(Studio.label).foregroundStyle(Studio.textTertiary)
                cropField(value: Binding(get: { cropDraft.height * frameSize.height },
                                         set: { setCropSize(height: $0) }))
                Menu {
                    ForEach(CropAspect.allCases) { a in
                        Button {
                            cropAspect = a
                            if let ratio = a.ratio { lockCrop(to: ratio) }
                        } label: {
                            if a == cropAspect { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                        }
                    }
                } label: {
                    Label(cropAspect.label, systemImage: "aspectratio")
                        .font(Studio.controlCopy)
                        .foregroundStyle(cropAspect == .any ? Studio.text : Studio.primaryText)
                        .frame(height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("Set crop aspect ratio")
            }
            HStack(spacing: 6) {
                Text("Position").font(Studio.label).foregroundStyle(Studio.textTertiary)
                cropField(value: Binding(get: { cropDraft.x * frameSize.width },
                                         set: { v in cropDraft.x = v / frameSize.width; cropDraft = cropDraft.clamped() }))
                cropField(value: Binding(get: { cropDraft.y * frameSize.height },
                                         set: { v in cropDraft.y = v / frameSize.height; cropDraft = cropDraft.clamped() }))
            }
            Spacer()
            StudioButton("Reset", icon: "crop", kind: .secondary, size: .small) {
                cropDraft = .full
                cropAspect = .any
            }
            StudioButton("Cancel", kind: .transparent, size: .small) { editMode = .none }
                .keyboardShortcut(.cancelAction)
            StudioButton("Done", icon: "checkmark", kind: .primary, size: .small) { applyCrop() }
        }
        .frame(height: 34)
    }

    private func cropField(value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.grouping(.never).precision(.fractionLength(0)))
            .textFieldStyle(.plain)
            .font(Studio.controlCopy.monospacedDigit())
            .foregroundStyle(Studio.text)
            .multilineTextAlignment(.center)
            .frame(width: 54, height: 26)
            .background(Studio.lighter, in: RoundedRectangle(cornerRadius: Studio.radius))
            .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.border, lineWidth: 1))
    }

    private var minCropUnit: (w: Double, h: Double) {
        (min(200 / frameSize.width, 1), min(200 / frameSize.height, 1))
    }

    private func setCropSize(width: Double? = nil, height: Double? = nil) {
        var r = cropDraft
        if let width { r.width = width / frameSize.width }
        if let height { r.height = height / frameSize.height }
        if let ratio = cropAspect.ratio {
            let unitAspect = ratio * (frameSize.height / frameSize.width)
            if width != nil { r.height = r.width / unitAspect } else { r.width = r.height * unitAspect }
        }
        cropDraft = r.clamped(minWidth: minCropUnit.w, minHeight: minCropUnit.h)
    }

    /// Fits the current crop to a pixel aspect ratio, keeping its centre.
    private func lockCrop(to ratio: Double) {
        let unitAspect = ratio * (frameSize.height / frameSize.width)
        var r = cropDraft
        let cx = r.x + r.width / 2, cy = r.y + r.height / 2
        if r.width / r.height > unitAspect { r.width = r.height * unitAspect } else { r.height = r.width / unitAspect }
        r.x = cx - r.width / 2
        r.y = cy - r.height / 2
        cropDraft = r.clamped(minWidth: minCropUnit.w, minHeight: minCropUnit.h)
    }

    private func enterCropMode() {
        transport.player.pause()
        transport.isPlaying = false
        selectedMaskID = nil
        cropDraft = options.crop
        cropAspect = .any
        cropStill = nil
        editMode = .crop
        let url = recording.videoURL, t = transport.time
        Task {
            let image = await RecordingStills.frame(of: url, at: t)
            await MainActor.run { if editMode == .crop { cropStill = image } }
        }
    }

    private func applyCrop() {
        options.crop = cropDraft.clamped(minWidth: minCropUnit.w, minHeight: minCropUnit.h)
        editMode = .none
    }

    // MARK: - Masks

    private static let maskTrackColor = Color(red: 0x82 / 255, green: 0x34 / 255, blue: 0x5A / 255)

    private func enterMaskMode() {
        transport.player.pause()
        transport.isPlaying = false
        editMode = .mask
    }

    private func leaveMaskMode() {
        editMode = .none
    }

    private func addMask(rect: UnitRect) {
        let duration = max(transport.duration, RecordingMask.minDuration)
        var start = min(max(transport.time, 0), duration)
        var end = min(start + RecordingMask.defaultDuration, duration)
        if end - start < RecordingMask.minDuration {
            end = duration
            start = max(0, end - RecordingMask.minDuration)
        }
        let mask = RecordingMask(rect: rect, start: start, end: end)
        options.masks.append(mask)
        options.masks.sort { $0.start < $1.start }
        selectedMaskID = mask.id
    }

    private func selectMask(_ id: UUID?) {
        selectedMaskID = id
        guard let id, let mask = options.masks.first(where: { $0.id == id }) else { return }
        // Show the mask: park the playhead inside its range if it isn't.
        if transport.time < mask.start || transport.time > mask.end {
            transport.player.pause()
            transport.isPlaying = false
            transport.seek(to: mask.start + min(0.2, mask.duration / 2))
        }
    }

    private func updateMask(_ id: UUID, _ change: (inout RecordingMask) -> Void) {
        guard let index = options.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&options.masks[index])
    }

    private func deleteMask(_ id: UUID) {
        options.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil }
    }

    /// Options used for the live preview: mask mode pauses the auto-zoom so
    /// masks can be placed on a stable, unzoomed frame.
    private var previewOptions: RecordingExportOptions {
        guard editMode == .mask else { return options }
        var o = options
        o.autoZoom = false
        return o
    }

    private var maskEditor: some View {
        Group {
            if let id = selectedMaskID, let mask = options.masks.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 12) {
                    StudioButton("Close mask editor", icon: "xmark", kind: .secondary) { selectedMaskID = nil }
                    StudioSection {
                        StudioField("Mask type") {
                            StudioSegmented(selection: Binding(get: { mask.kind },
                                                               set: { k in updateMask(id) { $0.kind = k } }),
                                            options: RecordingMaskKind.allCases.map { ($0, $0.label) })
                        }
                        if mask.kind == .sensitiveData {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "timeline.selection")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.6, blue: 0))
                                Text("Make sure the mask covers the entire part of the timeline where sensitive data is present.")
                                    .font(Studio.label)
                                    .foregroundStyle(Studio.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(Color(red: 1, green: 0.6, blue: 0).opacity(0.1), in: RoundedRectangle(cornerRadius: Studio.radius))
                        } else {
                            StudioField("Highlight mask opacity") {
                                StudioSlider(value: Binding(get: { mask.highlightOpacity },
                                                            set: { v in updateMask(id) { $0.highlightOpacity = v } }),
                                             in: 0.1...0.9, step: 0.05, resetValue: 0.5) { String(format: "%.0f%%", $0 * 100) }
                            }
                        }
                        StudioField("Timing", description: String(format: "%@ → %@. Drag the mask on the timeline to move or trim it, or snap an edge to the playhead.",
                                                                    timecode(mask.start, precise: true), timecode(mask.end, precise: true))) {
                            HStack(spacing: 8) {
                                StudioButton("Start at playhead", kind: .secondary, size: .small) {
                                    updateMask(id) { m in
                                        m.start = min(max(transport.time, 0), m.end - RecordingMask.minDuration)
                                    }
                                }
                                StudioButton("End at playhead", kind: .secondary, size: .small) {
                                    updateMask(id) { m in
                                        m.end = max(min(transport.time, transport.duration), m.start + RecordingMask.minDuration)
                                    }
                                }
                            }
                        }
                    }
                    StudioSection(isLast: true) {
                        StudioRow("Disable", description: "When disabled, the mask is not applied but stays in the timeline.") {
                            StudioToggle(isOn: Binding(get: { mask.isDisabled },
                                                       set: { v in updateMask(id) { $0.isDisabled = v } }))
                        }
                        StudioButton("Delete mask", icon: "trash", kind: .secondary) { deleteMask(id) }
                    }
                }
            }
        }
    }

    private var previewAspect: CGFloat {
        let size = RecordingCompositor.geometry(events: events, options: previewOptions, maxWidth: 1600).outputSize
        return max(size.width, 1) / max(size.height, 1)
    }

    @ViewBuilder private var preview: some View {
        if editMode == .crop {
            CropEditorView(image: cropStill, frameSize: frameSize, crop: $cropDraft, aspect: cropAspect)
                .clipShape(RoundedRectangle(cornerRadius: Studio.mediaRadius))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let geometry = RecordingCompositor.geometry(events: events, options: previewOptions, maxWidth: 1600)
            CompositedPreview(transport: transport, events: events, options: previewOptions)
                .overlay {
                    if editMode == .mask {
                        GeometryReader { geo in
                            let scale = geo.size.width / max(geometry.outputSize.width, 1)
                            let content = CGRect(x: geometry.contentRect.minX * scale,
                                                 y: (geometry.outputSize.height - geometry.contentRect.maxY) * scale,
                                                 width: geometry.contentRect.width * scale,
                                                 height: geometry.contentRect.height * scale)
                            MaskOverlayView(masks: options.masks,
                                            selectedID: selectedMaskID,
                                            contentFrame: content,
                                            time: transport.time,
                                            onSelect: { selectMask($0) },
                                            onChange: { id, rect in updateMask(id) { $0.rect = rect } },
                                            onCreate: { addMask(rect: $0) })
                        }
                    }
                }
                .aspectRatio(previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Studio.mediaRadius))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlsBar: some View {
        ZStack {
            HStack {
                Text(timecode(transport.time, precise: true) + "  /  " + timecode(transport.duration, precise: true))
                    .font(Studio.copy.monospacedDigit())
                    .foregroundStyle(Studio.textTertiary)
                Spacer()
                speedMenu
            }
            HStack(spacing: 6) {
                StudioIconButton(icon: "backward.end.fill", iconSize: 13, help: "Go to start") {
                    seek(to: 0)
                }
                StudioIconButton(icon: transport.isPlaying ? "pause.circle" : "play.circle",
                                 size: Studio.toolbarHeight, iconSize: 24,
                                 help: transport.isPlaying ? "Pause (space)" : "Play (space)") {
                    transport.togglePlayback()
                }
                .frame(width: 56)
                .keyboardShortcut(.space, modifiers: [])
                StudioIconButton(icon: "forward.end.fill", iconSize: 13, help: "Go to end") {
                    seek(to: transport.duration)
                }
            }
            // Frame stepping on the arrow keys, as in Screen Studio.
            HStack {
                Button("") { step(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                Button {
                    transport.speed = Float(rate)
                } label: {
                    if Float(rate) == transport.speed {
                        Label(String(format: "%g×", rate), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%g×", rate))
                    }
                }
            }
        } label: {
            Text(String(format: "%g×", transport.speed))
                .font(Studio.controlCopy.monospacedDigit())
                .foregroundStyle(Studio.text)
                .frame(height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Playback speed")
    }

    private func seek(to t: Double) {
        transport.player.pause()
        transport.isPlaying = false
        transport.seek(to: min(max(t, 0), transport.duration))
    }

    private func step(by frames: Int) {
        seek(to: transport.time + Double(frames) / RecordingCompositor.tickRate)
    }

    private func timecode(_ seconds: Double, precise: Bool = false) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        if precise {
            let hundredths = Int((clamped - Double(total)) * 100)
            return String(format: "%d:%02d.%02d", total / 60, total % 60, hundredths)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Rail & sidebar

    private var rail: some View {
        VStack(spacing: 8) {
            ForEach(Panel.allCases) { item in
                StudioRailButton(icon: item.icon, title: item.title, isActive: panel == item) {
                    withAnimation(.easeOut(duration: 0.15)) { panel = item }
                }
            }
            Spacer()
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if selectedMaskID != nil, options.masks.contains(where: { $0.id == selectedMaskID }) {
                    maskEditor
                } else {
                    switch panel {
                    case .background: backgroundPanel
                    case .cursor: cursorPanel
                    case .animations: animationsPanel
                    }
                }
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 32, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(Studio.panel)
        .clipShape(RoundedRectangle(cornerRadius: Studio.panelRadius))
    }

    // MARK: Background & Screen

    @ViewBuilder private var backgroundPanel: some View {
        StudioSection {
            StudioField("Background") {
                StudioSegmented(selection: $options.background.kind,
                                options: RecordingBackgroundKind.allCases.map { ($0, $0.label) })
            }
            switch options.background.kind {
            case .wallpaper: wallpaperFields
            case .gradient: gradientFields
            case .color:
                StudioRow("Background color") {
                    ColorPicker("", selection: colorBinding($options.background.color), supportsOpacity: false)
                        .labelsHidden()
                }
            case .image: imageFields
            case .video: videoFields
            }
        }
        StudioSection(isLast: true) {
            StudioField("Padding") {
                StudioSlider(value: paddingPercent, in: 0...35, step: 0.5,
                             resetValue: Self.defaults.background.padding * 100) { String(format: "%.1f%%", $0) }
            }
            StudioField("Rounded corners") {
                StudioSlider(value: $options.background.cornerRadius, in: 0...64, step: 1,
                             resetValue: Self.defaults.background.cornerRadius) { String(format: "%.0f", $0) }
            }
            StudioField("Shadow") {
                StudioSlider(value: $options.background.shadow, in: 0...1, step: 0.05,
                             resetValue: Self.defaults.background.shadow) { String(format: "%.0f%%", $0 * 100) }
            }
        }
    }

    @ViewBuilder private var wallpaperFields: some View {
        let library = WallpaperLibrary.shared
        StudioField("Wallpaper") {
            VStack(alignment: .leading, spacing: 10) {
                StudioChips(selection: $wallpaperCategory,
                            options: library.categories.map { ($0, $0) })
                StudioButton("Pick random wallpaper", icon: "sparkles", kind: .secondary, wide: true) {
                    if let pick = library.random(excluding: options.background.wallpaperID) {
                        options.background.wallpaperID = pick.id
                        wallpaperCategory = pick.category
                    }
                }
                WallpaperGrid(wallpapers: library.wallpapers(in: wallpaperCategory),
                              selectedID: options.background.wallpaperID) { id in
                    options.background.wallpaperID = id
                }
            }
        }
        StudioField("Background blur") {
            StudioSlider(value: $options.background.blur, in: 0...1, step: 0.05,
                         resetValue: 0) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    @ViewBuilder private var gradientFields: some View {
        StudioField("Gradient presets") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(GradientPreset.all) { preset in
                    let selected = options.background.gradient == preset.colors
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { options.background.gradient = preset.colors }
                    } label: {
                        RoundedRectangle(cornerRadius: Studio.radius)
                            .fill(LinearGradient(colors: preset.colors.map { $0.color },
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 38)
                            .overlay(RoundedRectangle(cornerRadius: Studio.radius)
                                .strokeBorder(selected ? Studio.primaryText : Studio.border,
                                              lineWidth: selected ? 2 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: Studio.radius))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
        }
        StudioRow("Start color") {
            ColorPicker("", selection: gradientStopBinding(0), supportsOpacity: false).labelsHidden()
        }
        StudioRow("End color") {
            ColorPicker("", selection: gradientStopBinding(1), supportsOpacity: false).labelsHidden()
        }
    }

    @ViewBuilder private var imageFields: some View {
        StudioField("Image", description: "Any picture on your Mac, scaled to fill the canvas.") {
            HStack(spacing: 10) {
                if let path = options.background.imagePath,
                   let thumb = WallpaperLibrary.decode(URL(fileURLWithPath: path), maxPixelSize: 160) {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: Studio.radius))
                        .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.border))
                }
                StudioButton(options.background.imagePath == nil ? "Choose image…" : "Change image…",
                             icon: "photo", kind: .secondary, wide: options.background.imagePath == nil) {
                    chooseImage()
                }
            }
        }
        StudioField("Background blur") {
            StudioSlider(value: $options.background.blur, in: 0...1, step: 0.05,
                         resetValue: 0) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    @ViewBuilder private var videoFields: some View {
        StudioField("Video", description: "Any video on your Mac, scaled to fill the canvas. It loops when shorter than the recording; its sound is not used.") {
            HStack(spacing: 10) {
                if let thumb = videoThumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: Studio.radius))
                        .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.border))
                }
                StudioButton(options.background.videoPath == nil ? "Choose video…" : "Change video…",
                             icon: "film", kind: .secondary, wide: options.background.videoPath == nil) {
                    chooseVideo()
                }
            }
            .task(id: options.background.videoPath) {
                guard let path = options.background.videoPath else {
                    videoThumb = nil
                    return
                }
                videoThumb = await RecordingStills.frame(of: URL(fileURLWithPath: path), at: 0,
                                                         maxSize: CGSize(width: 320, height: 200))
            }
        }
        StudioField("Background blur") {
            StudioSlider(value: $options.background.blur, in: 0...1, step: 0.05,
                         resetValue: 0) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.background.imagePath = url.path
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.background.videoPath = url.path
    }

    private var paddingPercent: Binding<Double> {
        Binding(get: { options.background.padding * 100 },
                set: { options.background.padding = $0 / 100 })
    }

    private func colorBinding(_ binding: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { binding.wrappedValue.color },
                set: { binding.wrappedValue = RGBAColor($0) })
    }

    private func gradientStopBinding(_ index: Int) -> Binding<Color> {
        Binding(get: {
            let stops = options.background.gradient
            return (stops.indices.contains(index) ? stops[index] : (stops.first ?? .black)).color
        }, set: { new in
            var stops = options.background.gradient
            while stops.count < 2 { stops.append(stops.last ?? .black) }
            stops[index] = RGBAColor(new)
            options.background.gradient = stops
        })
    }

    // MARK: Cursor & Animations

    private var recordingHasCursorTypes: Bool {
        events.cursorSamples.contains { $0.kind != nil }
    }

    @ViewBuilder private var cursorPanel: some View {
        StudioSection {
            StudioRow("Smooth cursor", description: "Replace the recorded pointer with a synthetic one that glides between positions.") {
                StudioToggle(isOn: $options.showCursor)
            }
            StudioField("Cursor size") {
                StudioSlider(value: $options.cursorScale, in: 1...4, step: 0.05,
                             resetValue: Self.defaults.cursorScale) { String(format: "%.2f×", $0) }
            }
            .disabled(!options.showCursor)
            .opacity(options.showCursor ? 1 : 0.4)
        }
        StudioSection {
            StudioRow("Follow the app's cursor",
                      description: recordingHasCursorTypes
                        ? "Show the pointer the app was showing — text cursor over text, hand over links, resize arrows at edges."
                        : "This recording has no pointer types (recorded before they were captured); the pointer below is used.") {
                StudioToggle(isOn: $options.followRecordedCursor)
            }
            .disabled(!recordingHasCursorTypes)
            .opacity(recordingHasCursorTypes ? 1 : 0.6)
            StudioField("Pointer", description: options.followRecordedCursor && recordingHasCursorTypes
                        ? "Used wherever the app's pointer isn't one of the standard ones."
                        : nil) {
                CursorKindGrid(selection: $options.cursorType, tint: options.cursorTint)
            }
            StudioField("Color") {
                StudioSegmented(selection: $options.cursorTint,
                                options: CursorTint.allCases.map { ($0, $0.label) })
            }
        }
        .disabled(!options.showCursor)
        .opacity(options.showCursor ? 1 : 0.4)
        StudioSection(isLast: true) {
            StudioRow("Click effect", description: "A quick circle where the mouse was pressed.") {
                StudioToggle(isOn: $options.clickRipples)
            }
            .disabled(!options.showCursor)
            .opacity(options.showCursor ? 1 : 0.4)
        }
    }

    @ViewBuilder private var animationsPanel: some View {
        StudioSection {
            StudioRow("Auto zoom", description: "The camera zooms into where you click and follows the cursor while you work there.") {
                StudioToggle(isOn: $options.autoZoom)
            }
            StudioField("Zoom level") {
                StudioSlider(value: $options.zoomLevel, in: 1.2...3, step: 0.1,
                             resetValue: Self.defaults.zoomLevel) { String(format: "%.1f×", $0) }
            }
            .disabled(!options.autoZoom)
            .opacity(options.autoZoom ? 1 : 0.4)
        }
        StudioSection {
            StudioField("Motion blur", description: "Cinematic blur while the screen zooms or pans and the cursor moves.") {
                StudioSlider(value: $options.motionBlur, in: 0...1, step: 0.05,
                             resetValue: Self.defaults.motionBlur) { String(format: "%.0f%%", $0 * 100) }
            }
        }
        StudioSection(isLast: true) {
            StudioField("Background music", description: "A music track from your Mac, mixed under the export. It loops when shorter than the recording; the exported video carries the sound.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        StudioButton(options.backgroundAudioPath == nil ? "Choose music…" : "Change music…",
                                     icon: "music.note", kind: .secondary,
                                     wide: options.backgroundAudioPath == nil) {
                            chooseAudio()
                        }
                        if options.backgroundAudioPath != nil {
                            StudioButton("Remove", icon: "xmark", kind: .secondary) {
                                options.backgroundAudioPath = nil
                            }
                        }
                    }
                    if let path = options.backgroundAudioPath {
                        Text((path as NSString).lastPathComponent)
                            .font(Studio.label)
                            .foregroundStyle(Studio.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            StudioField("Music volume") {
                StudioSlider(value: $options.backgroundAudioVolume, in: 0...1, step: 0.05,
                             resetValue: Self.defaults.backgroundAudioVolume) { String(format: "%.0f%%", $0 * 100) }
            }
            .disabled(options.backgroundAudioPath == nil)
            .opacity(options.backgroundAudioPath == nil ? 0.4 : 1)
        }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.backgroundAudioPath = url.path
    }

    // MARK: - Timeline

    private var timeline: some View {
        StudioTimeline(duration: max(transport.duration, 0.1),
                       time: transport.time,
                       zoomWindows: CameraRig.zoomWindows(events: events, duration: transport.duration),
                       zoomLevel: options.zoomLevel,
                       zoomEnabled: options.autoZoom,
                       masks: options.masks,
                       showMasks: !options.masks.isEmpty || editMode == .mask,
                       selectedMaskID: selectedMaskID,
                       onSeek: { t in transport.seek(to: t) },
                       onPreview: { t in transport.previewSeek(to: t) },
                       onPreviewEnd: { transport.endPreview() },
                       onSelectMask: { selectMask($0) },
                       onMoveMask: { id, start, end in
                           updateMask(id) { $0.start = start; $0.end = end }
                       })
    }

    // MARK: - History & presets

    private func recordHistory(_ new: RecordingExportOptions) {
        guard !restoringHistory else { return }
        let now = Date()
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if now.timeIntervalSince(lastEdit) < 0.8, history.count > 1 {
            history[history.count - 1] = new
        } else {
            history.append(new)
        }
        historyIndex = history.count - 1
        lastEdit = now
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        restore(history[historyIndex])
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        restore(history[historyIndex])
    }

    private func restore(_ value: RecordingExportOptions) {
        restoringHistory = true
        options = value
        lastEdit = .distantPast
        DispatchQueue.main.async { restoringHistory = false }
    }

    private func applyPreset(_ preset: Preset) {
        var next = options
        preset.apply(&next)
        lastEdit = .distantPast
        withAnimation(.easeOut(duration: 0.2)) { options = next }
        if next.background.kind == .wallpaper,
           let w = WallpaperLibrary.shared.wallpaper(id: next.background.wallpaperID) {
            wallpaperCategory = w.category
        }
    }

    // MARK: - Delete & export

    private func deleteRecording() {
        transport.player.pause()
        let sidecar = ScreenRecordingService.sidecarURL(for: recording.videoURL)
        for url in [recording.videoURL, sidecar] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        NSApp.keyWindow?.close()
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
        transport.player.pause()
        transport.isPlaying = false

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

// MARK: - Cursor picker

/// The standard macOS pointers as selectable tiles, drawn from the same
/// NSCursor artwork the compositor renders.
private struct CursorKindGrid: View {
    @Binding var selection: CursorKind
    let tint: CursorTint

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(CursorKind.allCases) { kind in
                let selected = kind == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = kind }
                } label: {
                    let light = kind.isLight(under: tint)
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(light ? Color.black.opacity(0.7) : Color.white.opacity(0.9))
                        Image(nsImage: kind.nsCursor.image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .colorInvert(kind.needsInversion(for: tint))
                    }
                    .frame(height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Studio.primaryText : Color.white.opacity(0.08),
                                      lineWidth: selected ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(kind.label)
            }
        }
    }
}

private extension View {
    @ViewBuilder func colorInvert(_ on: Bool) -> some View {
        if on { self.colorInvert() } else { self }
    }
}

// MARK: - Wallpaper grid

/// Thumbnails of one wallpaper category, rendered off the main thread and
/// cached by the library.
private struct WallpaperGrid: View {
    let wallpapers: [WallpaperLibrary.Wallpaper]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(wallpapers) { wallpaper in
                WallpaperTile(wallpaper: wallpaper, selected: wallpaper.id == selectedID) {
                    onSelect(wallpaper.id)
                }
            }
        }
    }
}

private struct WallpaperTile: View {
    let wallpaper: WallpaperLibrary.Wallpaper
    let selected: Bool
    let action: () -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Studio.lighter
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Studio.primaryText : Color.white.opacity(0.08),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(wallpaper.name)
        .task(id: wallpaper.id) {
            let w = wallpaper
            let image = await Task.detached(priority: .utility) {
                WallpaperLibrary.shared.thumbnail(for: w)
            }.value
            thumbnail = image
        }
    }
}

// MARK: - Timeline

/// Screen Studio's timeline, reduced to what this editor drives: a ruler
/// with dot ticks, the clip track, the zoom track whose primary-colored
/// items are the ranges the camera zooms into, and a draggable playhead.
private struct StudioTimeline: View {
    let duration: Double
    let time: Double
    let zoomWindows: [(start: Double, end: Double)]
    let zoomLevel: Double
    let zoomEnabled: Bool
    let masks: [RecordingMask]
    let showMasks: Bool
    let selectedMaskID: UUID?
    let onSeek: (Double) -> Void
    let onPreview: (Double) -> Void
    let onPreviewEnd: () -> Void
    let onSelectMask: (UUID?) -> Void
    let onMoveMask: (UUID, Double, Double) -> Void

    private let rulerHeight: CGFloat = 22
    private let trackHeight: CGFloat = 46
    private let trackGap: CGFloat = 6
    private let itemRadius: CGFloat = 10
    private static let clipColor = Color(red: 1.0, green: 0.60, blue: 0.0)
    private static let maskColor = Color(red: 0x82 / 255, green: 0x34 / 255, blue: 0x5A / 255)

    private var trackCount: Int { showMasks ? 3 : 2 }
    private var totalHeight: CGFloat { rulerHeight + CGFloat(trackCount) * (trackGap + trackHeight) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: trackGap) {
                    ruler(width: width)
                    clipTrack(width: width)
                    zoomTrack(width: width)
                    if showMasks {
                        maskTrack(width: width)
                    }
                }
                playhead(width: width)
            }
            .contentShape(Rectangle())
            // Hover preview, like Screen Studio: while paused, the preview
            // follows the pointer without moving the real playhead, and
            // snaps back to it when the pointer leaves the timeline.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let f = min(max(location.x / width, 0), 1)
                    onPreview(f * duration)
                case .ended:
                    onPreviewEnd()
                }
            }
            // Click or drag commits the playhead to that position.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(max(value.location.x / width, 0), 1)
                        onSeek(f * duration)
                    }
            )
        }
        .frame(height: totalHeight)
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(max(t / duration, 0), 1)) * width
    }

    private var tickStep: Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60]
        return candidates.first(where: { duration / $0 <= 16 }) ?? 60
    }

    private func ruler(width: CGFloat) -> some View {
        let step = tickStep
        let count = Int((duration / (step / 2)).rounded(.down))
        return ZStack(alignment: .bottomLeading) {
            ForEach(0...max(count, 0), id: \.self) { i in
                let t = Double(i) * step / 2
                let major = i % 2 == 0
                VStack(spacing: 3) {
                    if major, i > 0 {
                        Text(label(for: t))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Studio.textTertiary)
                            .fixedSize()
                    }
                    Circle()
                        .fill(Color.white.opacity(major ? 0.35 : 0.18))
                        .frame(width: major ? 3 : 2, height: major ? 3 : 2)
                }
                .frame(width: 40)
                .offset(x: x(for: t, width: width) - 20)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .bottomLeading)
        .clipped()
    }

    private func label(for t: Double) -> String {
        // Sub-second ticks (short recordings) get tenths so labels stay unique.
        if tickStep < 1 {
            let whole = Int(t)
            let tenths = Int(((t - Double(whole)) * 10).rounded())
            return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
        }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func clipTrack(width: CGFloat) -> some View {
        trackItem(color: Self.clipColor, width: width, head: "Clip") {
            HStack(spacing: 10) {
                Label(clipDuration, systemImage: "clock")
                Label("1×", systemImage: "speedometer")
            }
        }
        .frame(width: width, height: trackHeight)
    }

    private var clipDuration: String {
        duration < 10 ? String(format: "%.1fs", duration) : String(format: "%.0fs", duration)
    }

    private func zoomTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: itemRadius)
                .fill(Studio.lighter)
            if zoomEnabled, !zoomWindows.isEmpty {
                ForEach(Array(zoomWindows.enumerated()), id: \.offset) { _, window in
                    let x0 = x(for: window.start, width: width)
                    let x1 = x(for: min(window.end, duration), width: width)
                    trackItem(color: Studio.primary, width: max(x1 - x0, 24), head: "Zoom") {
                        HStack(spacing: 10) {
                            Label(String(format: "%.1f×", zoomLevel), systemImage: "magnifyingglass")
                            Label("Auto", systemImage: "computermouse.fill")
                        }
                    }
                    .offset(x: x0)
                }
            } else {
                Text(zoomEnabled ? "No clicks recorded — nothing to zoom into" : "Auto zoom is off")
                    .font(Studio.label)
                    .foregroundStyle(Studio.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width, height: trackHeight)
    }

    private func maskTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: itemRadius)
                .fill(Studio.lighter)
            if masks.isEmpty {
                Text("Drag on the video to create a mask")
                    .font(Studio.label)
                    .foregroundStyle(Studio.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(masks) { mask in
                MaskTrackItem(mask: mask,
                              duration: duration,
                              width: width,
                              height: trackHeight,
                              radius: itemRadius,
                              color: Self.maskColor,
                              selected: mask.id == selectedMaskID,
                              onSelect: { onSelectMask(mask.id) },
                              onMove: { start, end in onMoveMask(mask.id, start, end) })
            }
        }
        .frame(width: width, height: trackHeight)
    }

    private func trackItem<Info: View>(color: Color, width: CGFloat, head: String,
                                       @ViewBuilder info: () -> Info) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: itemRadius)
                .fill(LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: itemRadius)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            VStack(spacing: 2) {
                Text(head)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                info()
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .labelStyle(StudioTrackLabelStyle())
            }
            .padding(.horizontal, 10)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: trackHeight)
        .clipped()
    }

    private func playhead(width: CGFloat) -> some View {
        let px = x(for: time, width: width)
        return VStack(spacing: 0) {
            Circle()
                .fill(Studio.primaryText)
                .frame(width: 10, height: 10)
            Rectangle()
                .fill(Studio.primaryText)
                .frame(width: 2)
        }
        .frame(height: totalHeight)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .offset(x: px - 5)
        .allowsHitTesting(false)
    }
}

/// A mask on the timeline: click to select, drag the body to move, drag an
/// edge to trim (minimum 1 s), like Screen Studio's track items.
private struct MaskTrackItem: View {
    let mask: RecordingMask
    let duration: Double
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let color: Color
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (Double, Double) -> Void

    private enum Grab { case body, start, end }
    @State private var grab: Grab?
    @State private var initial: (start: Double, end: Double)?

    private var x0: CGFloat { CGFloat(mask.start / duration) * width }
    private var x1: CGFloat { CGFloat(min(mask.end, duration) / duration) * width }

    var body: some View {
        let w = max(x1 - x0, 24)
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? Color.white.opacity(0.9) : Color.white.opacity(0.28),
                                  lineWidth: selected ? 1.5 : 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .opacity(mask.isDisabled ? 0.45 : 1)
            VStack(spacing: 2) {
                Text("Mask")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                Label(mask.kind.label, systemImage: mask.kind == .sensitiveData ? "eye.slash.fill" : "rectangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .labelStyle(StudioTrackLabelStyle())
            }
            .padding(.horizontal, 10)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // Trim grips at both edges (visible on selection).
            HStack {
                Capsule().fill(Color.white.opacity(selected ? 0.9 : 0)).frame(width: 3, height: height * 0.45)
                Spacer()
                Capsule().fill(Color.white.opacity(selected ? 0.9 : 0)).frame(width: 3, height: height * 0.45)
            }
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
        }
        .frame(width: w, height: height)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .offset(x: x0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if grab == nil {
                        onSelect()
                        initial = (mask.start, mask.end)
                        let localX = value.startLocation.x
                        grab = localX < 10 ? .start : (localX > w - 10 ? .end : .body)
                    }
                    guard let grab, let initial else { return }
                    let dt = Double(value.translation.width / width) * duration
                    let minDur = RecordingMask.minDuration
                    switch grab {
                    case .body:
                        let length = initial.end - initial.start
                        var start = initial.start + dt
                        start = min(max(start, 0), max(duration - length, 0))
                        onMove(start, start + length)
                    case .start:
                        let start = min(max(initial.start + dt, 0), initial.end - minDur)
                        onMove(start, initial.end)
                    case .end:
                        let end = max(min(initial.end + dt, duration), initial.start + minDur)
                        onMove(initial.start, end)
                    }
                }
                .onEnded { _ in
                    grab = nil
                    initial = nil
                }
        )
        .help(mask.kind.label)
    }
}

private struct StudioTrackLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .semibold)).opacity(0.85)
            configuration.title
        }
    }
}

// MARK: - Color bridging

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}
