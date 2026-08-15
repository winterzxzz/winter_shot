import AppKit
import Carbon.HIToolbox

/// System-wide capture hotkey via Carbon RegisterEventHotKey. One shortcut
/// (user-configurable, default ⌘⇧4) opens the area selector, which also picks
/// whole windows on hover; every other feature is triggered from the menu
/// bar. No special permissions required. If macOS's own ⌘⇧4 shortcut is
/// still enabled both will fire; users can turn the system one off in
/// System Settings → Keyboard → Keyboard Shortcuts → Screenshots.
final class GlobalHotkeyService {
    /// Called on the main thread when the capture hotkey fires.
    var onTrigger: ((CaptureMode) -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = {
        // 'WSHT' as a four-char code.
        var result: OSType = 0
        for byte in "WSHT".utf8 { result = (result << 8) | OSType(byte) }
        return result
    }()

    deinit {
        unregister()
    }

    /// Registers (or re-registers) the capture hotkey. Call again with a new
    /// value when the user changes the shortcut.
    func register(_ hotkey: CaptureHotkey) {
        installHandlerIfNeeded()
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }

        let hotkeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.carbonModifiers,
                                         hotkeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotkeyRef)
        if result == noErr {
            NSLog("WinterShot: registered capture hotkey %@", hotkey.displayString)
        } else {
            NSLog("WinterShot: could not register capture hotkey %@ (%d)",
                  hotkey.displayString, result)
        }
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onTrigger?(.area)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
        if status != noErr {
            NSLog("WinterShot: hotkey handler install failed (%d)", status)
        }
    }
}
