import AppKit
import SwiftUI

/// A click-to-record shortcut field for the global capture hotkey. Click it,
/// press a combo containing ⌘, ⌥, or ⌃, and the new shortcut is saved (the
/// Carbon registration refreshes via AppPreferences). Esc or clicking again
/// cancels; the reset arrow restores ⌘⇧4.
struct HotkeyRecorderView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press shortcut…" : preferences.captureHotkey.displayString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 110)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.4),
                                          lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            if preferences.captureHotkey != .default {
                Button {
                    stopRecording()
                    preferences.captureHotkey = .default
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(CaptureHotkey.default.displayString)")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        DIContainer.shared.pauseGlobalHotkey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            guard let hotkey = CaptureHotkey(event: event) else {
                NSSound.beep()
                return nil
            }
            stopRecording()
            preferences.captureHotkey = hotkey
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        DIContainer.shared.resumeGlobalHotkey()
    }
}
