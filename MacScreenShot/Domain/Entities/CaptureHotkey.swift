import AppKit
import Carbon.HIToolbox

/// The user's global capture shortcut: a key plus Carbon modifier flags.
/// Defaults to ⌘⇧4. Stored in UserDefaults; changing it re-registers the
/// system-wide hotkey.
struct CaptureHotkey: Equatable, Codable {
    var keyCode: UInt32
    /// Carbon flags (cmdKey | shiftKey | optionKey | controlKey).
    var carbonModifiers: UInt32

    static let `default` = CaptureHotkey(keyCode: UInt32(kVK_ANSI_4),
                                         carbonModifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a hotkey from a keyDown event. Returns nil for combos too easy
    /// to hit by accident: at least one of ⌘⌃⌥ is required.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            return nil
        }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    // MARK: - Display

    /// Human-readable form, e.g. "⌘⇧4".
    var displayString: String {
        modifierSymbols + Self.keyName(for: keyCode)
    }

    private var modifierSymbols: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    // MARK: - NSMenuItem bridging

    /// Key-equivalent string for a menu item; empty when the key has no
    /// single-character form (the menu then simply shows no shortcut).
    var keyEquivalent: String {
        let name = Self.keyName(for: keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        return mask
    }

    // MARK: - Key naming

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return translatedName(for: keyCode) ?? "?"
        }
    }

    /// Layout-aware character for ordinary keys via UCKeyTranslate.
    private static func translatedName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        chars.count,
                                        &length,
                                        &chars)
            guard status == noErr, length > 0 else { return nil }
            let name = String(utf16CodeUnits: chars, count: length).uppercased()
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        }
    }
}
