import SwiftUI

/// The app's Settings window: appearance, capture preview card options,
/// storage location, and the global capture hotkey.
struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared

    private var capturesFolder: URL {
        DIContainer.shared.screenshotRepository.storageDirectory
    }

    /// The auto-hide slider snaps across these stops (seconds); a linear
    /// 2s–5min slider would make the short durations impossible to hit.
    private static let autoHideStops: [Double] = [2, 5, 10, 15, 30, 60, 120, 300]

    /// Bridges the seconds preference to a stop index for the slider,
    /// snapping any stored in-between value to the nearest stop.
    private var autoHideStopIndex: Binding<Double> {
        Binding(
            get: {
                let current = preferences.previewAutoHideSeconds
                let nearest = Self.autoHideStops.enumerated()
                    .min { abs($0.element - current) < abs($1.element - current) }
                return Double(nearest?.offset ?? 0)
            },
            set: { preferences.previewAutoHideSeconds = Self.autoHideStops[Int($0)] }
        )
    }

    private func durationLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds) / 60)m"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Capture Preview") {
                Picker("Thumbnail size", selection: $preferences.previewSize) {
                    ForEach(CapturePreviewSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Auto-hide after") {
                    HStack(spacing: 8) {
                        Slider(value: autoHideStopIndex,
                               in: 0...Double(Self.autoHideStops.count - 1),
                               step: 1)
                            .frame(width: 140)
                        Text(durationLabel(Self.autoHideStops[Int(autoHideStopIndex.wrappedValue)]))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Text("Captures appear at the bottom-left of the screen; new ones stack upward in a column.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Captures folder") {
                    HStack(spacing: 8) {
                        Text(capturesFolder.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Open") {
                            NSWorkspace.shared.open(capturesFolder)
                        }
                    }
                }
            }

            Section("Global Hotkey") {
                LabeledContent("Capture Area") {
                    HotkeyRecorderView()
                }
                Text("Click the shortcut to record a new one (must include ⌘, ⌥, or ⌃). Other features are available from the menu bar icon.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
