import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted after the capture hotkey preference changes so the Carbon
    /// registration can be refreshed.
    static let winterShotHotkeyChanged = Notification.Name("winterShotHotkeyChanged")
}

/// The app's appearance override.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil follows the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// UserDefaults-backed user preferences: theme, capture hotkey, and the
/// first-launch onboarding flag. Observable so Settings and onboarding UI
/// update live.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Keys {
        static let theme = "theme"
        static let hotkeyKeyCode = "captureHotkeyKeyCode"
        static let hotkeyModifiers = "captureHotkeyModifiers"
        static let onboardingDone = "hasCompletedOnboarding"
    }

    private let defaults = UserDefaults.standard

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    @Published var captureHotkey: CaptureHotkey {
        didSet {
            defaults.set(Int(captureHotkey.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(captureHotkey.carbonModifiers), forKey: Keys.hotkeyModifiers)
            NotificationCenter.default.post(name: .winterShotHotkeyChanged, object: nil)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingDone) }
    }

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        if defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            captureHotkey = CaptureHotkey(keyCode: UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode)),
                                          carbonModifiers: UInt32(defaults.integer(forKey: Keys.hotkeyModifiers)))
        } else {
            captureHotkey = .default
        }
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingDone)
    }

    /// Pushes the chosen theme onto every window; call once at launch and on
    /// every change.
    func applyTheme() {
        NSApp.appearance = theme.appearance
    }
}
