import SwiftUI

// Design system for the recording editor, mirroring Screen Studio's editor
// chrome: its palette (#08090D window / #13151B panels / #4D2FF5 primary),
// its control geometry (32–38 pt controls with 6 pt corners, 10 pt on media
// and segmented items, pills for switches) and its typography (13 pt copy,
// 12 pt labels at 40 % white for section titles).

enum Studio {
    // MARK: Colors
    static let background = Color(red: 0x08 / 255, green: 0x09 / 255, blue: 0x0D / 255)
    static let panel = Color(red: 0x13 / 255, green: 0x15 / 255, blue: 0x1B / 255)
    static let primary = Color(red: 0x4D / 255, green: 0x2F / 255, blue: 0xF5 / 255)
    /// Screen Studio's `primary.activeText` — the lighter tint used for
    /// active icons, slider thumbs and outlines.
    static let primaryText = Color(red: 0x8F / 255, green: 0x7C / 255, blue: 0xFF / 255)
    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.4)
    static let lighter = Color.white.opacity(0.05)
    static let hover = Color.white.opacity(0.08)
    static let active = Color.white.opacity(0.14)
    static let border = Color.white.opacity(0.18)
    static let separator = Color.white.opacity(0.06)

    // MARK: Geometry
    static let radius: CGFloat = 6
    static let panelRadius: CGFloat = 8
    static let mediaRadius: CGFloat = 10
    static let controlHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 38

    // MARK: Type
    static let copy = Font.system(size: 13)
    static let controlCopy = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 12)
    static let title = Font.system(size: 13, weight: .semibold)
}

// MARK: - Sections & fields

/// A titled group of fields; consecutive sections are separated by a hairline.
struct StudioSection<Content: View>: View {
    let title: String?
    let isLast: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, isLast: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isLast = isLast
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(Studio.label)
                    .foregroundStyle(Studio.textTertiary)
                    .padding(.bottom, -4)
            }
            content()
            if !isLast {
                Rectangle()
                    .fill(Studio.separator)
                    .frame(height: 1)
                    .padding(.vertical, 8)
            }
        }
    }
}

/// Name (+ optional description) above a full-width control.
struct StudioField<Content: View>: View {
    let name: String
    let description: String?
    @ViewBuilder let content: () -> Content

    init(_ name: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.name = name
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Studio.copy).foregroundStyle(Studio.text)
                if let description {
                    Text(description).font(Studio.label).foregroundStyle(Studio.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }
}

/// Name (+ optional description) with a compact control on the trailing side.
struct StudioRow<Content: View>: View {
    let name: String
    let description: String?
    @ViewBuilder let content: () -> Content

    init(_ name: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.name = name
        self.description = description
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Studio.copy).foregroundStyle(Studio.text)
                if let description {
                    Text(description).font(Studio.label).foregroundStyle(Studio.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            content()
        }
    }
}

// MARK: - Slider

/// Screen Studio's slider: a 3 pt track that thickens on hover, a primary
/// fill, a 20 pt thumb, a value pill under the thumb while hovering, and an
/// optional Reset button once the value leaves its default.
struct StudioSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let format: (Double) -> String
    let resetValue: Double?

    @State private var hovering = false
    @State private var dragging = false

    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double? = nil,
         resetValue: Double? = nil,
         format: @escaping (Double) -> String = { String(format: "%.2f", $0) }) {
        _value = value
        self.range = range
        self.step = step
        self.resetValue = resetValue
        self.format = format
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let thumb: CGFloat = 20
                let usable = max(width - thumb, 1)
                let x = thumb / 2 + usable * fraction
                let trackHeight: CGFloat = (hovering || dragging) ? 5 : 3
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(dragging ? Studio.active : (hovering ? Studio.hover : Studio.hover.opacity(0.7)))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(Studio.primary)
                        .frame(width: max(x, 0), height: trackHeight)
                    Circle()
                        .fill(Studio.primaryText)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: x - thumb / 2)
                        .overlay(alignment: .top) {
                            if hovering || dragging {
                                Text(format(value))
                                    .font(Studio.label.monospacedDigit())
                                    .foregroundStyle(Studio.text)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Studio.panel, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Studio.border, lineWidth: 1))
                                    .fixedSize()
                                    .offset(x: x - thumb / 2, y: thumb + 4)
                                    .transition(.opacity)
                            }
                        }
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            let f = min(max((drag.location.x - thumb / 2) / usable, 0), 1)
                            var v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                            if let step, step > 0 { v = (v / step).rounded() * step }
                            value = min(max(v, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 20)
            .onHover { hovering = $0 }
            .zIndex(1)

            if let resetValue, abs(value - resetValue) > 1e-9 {
                StudioButton("Reset", kind: .secondary, size: .small) {
                    withAnimation(.easeOut(duration: 0.15)) { value = resetValue }
                }
            }
        }
    }
}

// MARK: - Toggle

/// 44 × 25 pill switch: translucent with a hairline when off, primary when on.
struct StudioToggle: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Studio.primary : (hovering ? Studio.hover : Studio.lighter))
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : Studio.border, lineWidth: 1))
                Circle()
                    .fill(Color.white)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.27), radius: 1, y: 2)
                    .padding(3)
            }
            .frame(width: 44, height: 25)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Segmented picker

struct StudioSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Studio.controlCopy)
                        .foregroundStyle(active ? Studio.text : Studio.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(active ? Studio.active : Studio.lighter, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(active ? Studio.primaryText.opacity(0.33) : Color.clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Horizontal category chips (Screen Studio's wallpaper pack picker):
/// pill-ish items on the translucent surface, the active one outlined.
struct StudioChips<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    let active = option.value == selection
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(Studio.controlCopy)
                            .foregroundStyle(active ? Studio.text : Studio.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(active ? Studio.active : Studio.lighter, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(active ? Studio.primaryText.opacity(0.33) : Color.clear, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Buttons

struct StudioButton: View {
    enum Kind { case primary, secondary, transparent }
    enum Size { case small, regular }

    let title: String
    let icon: String?
    let kind: Kind
    let size: Size
    let wide: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, icon: String? = nil, kind: Kind = .secondary, size: Size = .regular,
         wide: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.size = size
        self.wide = wide
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(Studio.controlCopy)
            }
            .foregroundStyle(Studio.text)
            .padding(.horizontal, size == .small ? 10 : 12)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: size == .small ? 28 : Studio.controlHeight)
            .background(background, in: RoundedRectangle(cornerRadius: Studio.radius))
            .overlay(RoundedRectangle(cornerRadius: Studio.radius)
                .strokeBorder(kind == .secondary ? Studio.border : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Studio.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        switch kind {
        case .primary: return hovering ? Studio.primary.opacity(0.85) : Studio.primary
        case .secondary: return hovering ? Studio.hover : Studio.lighter
        case .transparent: return hovering ? Studio.hover : .clear
        }
    }
}

/// Square icon-only control (toolbar buttons, transport buttons).
struct StudioIconButton: View {
    let icon: String
    var size: CGFloat = Studio.toolbarHeight
    var iconSize: CGFloat = 16
    var isActive = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isActive ? Studio.primaryText : Studio.text.opacity(0.85))
                .frame(width: size, height: size)
                .background(hovering ? Studio.hover : Color.clear, in: RoundedRectangle(cornerRadius: Studio.radius))
                .contentShape(RoundedRectangle(cornerRadius: Studio.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// The vertical tool rail between the video and the sidebar: 40 pt icon
/// buttons with a 4 pt primary dot marking the open section.
struct StudioRailButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isActive ? Studio.primaryText : Studio.text.opacity(0.75))
                    .frame(width: 40, height: 40)
                    .background(hovering ? Studio.hover : Color.clear, in: RoundedRectangle(cornerRadius: Studio.radius))
                Circle()
                    .fill(Studio.primaryText)
                    .frame(width: 4, height: 4)
                    .offset(x: -5)
                    .opacity(isActive ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Studio.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}
