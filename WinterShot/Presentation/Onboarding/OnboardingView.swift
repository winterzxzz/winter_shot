import AppKit
import SwiftUI

/// First-launch walkthrough: welcome → screen-recording permission → capture
/// hotkey. Finishing sets the onboarding flag so it never shows again; the
/// permission step polls TCC live and turns green once access is granted.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0
    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcomeStep
                case 1: PermissionStepView()
                default: hotkeyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            footer
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to WinterShot")
                .font(.system(size: 24, weight: .bold))
            Text("Screenshots, beautiful annotations, and Screen Studio-style recordings — all on-device. Two quick steps and you're set.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var hotkeyStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Your capture shortcut")
                .font(.system(size: 20, weight: .bold))
            Text("One shortcut does it all: drag to capture an area, or hover a window and click to capture it whole. Keep ⌘⇧4 or record your own.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HotkeyRecorderView()
                .padding(.top, 6)
            Text("If macOS's own ⌘⇧4 is enabled, both will fire — turn the system one off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots. You can change the shortcut anytime in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(step == lastStep ? "Get Started" : "Continue") {
                if step == lastStep {
                    onFinish()
                } else {
                    step += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }
}

/// Screen-recording permission step. CGPreflightScreenCaptureAccess is polled
/// once a second while visible so the status flips to granted without any
/// user action in this window.
private struct PermissionStepView: View {
    @State private var hasAccess = CGPreflightScreenCaptureAccess()
    @State private var didRequest = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasAccess ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(hasAccess ? Color.green : Color.accentColor)
            Text("Screen Recording access")
                .font(.system(size: 20, weight: .bold))
            Text("WinterShot needs macOS's Screen Recording permission to capture screenshots and record your screen. Nothing ever leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if hasAccess {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.top, 6)
            } else {
                HStack(spacing: 10) {
                    Button("Allow Screen Recording") {
                        didRequest = true
                        CGRequestScreenCaptureAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open System Settings") {
                        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        if let url = URL(string: pane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(.top, 6)
                if didRequest {
                    Text("After allowing, macOS may ask to quit and reopen WinterShot for the permission to take effect.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
        }
        .onReceive(poll) { _ in
            hasAccess = CGPreflightScreenCaptureAccess()
        }
    }
}
