import SwiftUI

/// The app's Settings window: storage location and the global hotkey map.
struct SettingsView: View {
    private var capturesFolder: URL {
        DIContainer.shared.screenshotRepository.storageDirectory
    }

    var body: some View {
        Form {
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

            Section("Global Hotkeys") {
                ForEach(CaptureMode.allCases.filter { $0.hotkeyNumber != nil }) { mode in
                    LabeledContent(mode.label) {
                        Text("⌘⇧\(String(mode.hotkeyNumber!))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Other features are available from the menu bar icon.")
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
