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

/// The footprint of the post-capture thumbnail card shown at the
/// bottom-left of the screen.
enum CapturePreviewSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// 10:7 card; medium matches the original fixed footprint.
    var cardSize: NSSize {
        switch self {
        case .small: return NSSize(width: 220, height: 154)
        case .medium: return NSSize(width: 300, height: 210)
        case .large: return NSSize(width: 380, height: 266)
        }
    }
}

/// UserDefaults-backed user preferences: theme, capture hotkey, capture
/// preview card size and auto-hide delay, and the first-launch onboarding
/// flag. Observable so Settings and onboarding UI update live.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Keys {
        static let theme = "theme"
        static let hotkeyKeyCode = "captureHotkeyKeyCode"
        static let hotkeyModifiers = "captureHotkeyModifiers"
        static let onboardingDone = "hasCompletedOnboarding"
        static let previewSize = "capturePreviewSize"
        static let previewAutoHide = "capturePreviewAutoHideSeconds"
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

    @Published var previewSize: CapturePreviewSize {
        didSet { defaults.set(previewSize.rawValue, forKey: Keys.previewSize) }
    }

    /// Seconds a capture preview card stays on screen before sliding away.
    @Published var previewAutoHideSeconds: Double {
        didSet { defaults.set(previewAutoHideSeconds, forKey: Keys.previewAutoHide) }
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
        previewSize = CapturePreviewSize(rawValue: defaults.string(forKey: Keys.previewSize) ?? "") ?? .medium
        // Default matches a stop on the Settings slider so the displayed
        // value and the actual delay agree out of the box.
        let storedAutoHide = defaults.double(forKey: Keys.previewAutoHide)
        previewAutoHideSeconds = storedAutoHide > 0 ? storedAutoHide : 5
    }

    /// Pushes the chosen theme onto every window; call once at launch and on
    /// every change.
    func applyTheme() {
        NSApp.appearance = theme.appearance
    }
}
