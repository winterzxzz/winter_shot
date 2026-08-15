import SwiftUI

/// The app's Settings window: appearance, storage location, and the global
/// capture hotkey.
struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared

    private var capturesFolder: URL {
        DIContainer.shared.screenshotRepository.storageDirectory
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
