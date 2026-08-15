import AppKit
import Carbon.HIToolbox

/// System-wide capture hotkey via Carbon RegisterEventHotKey: ⌘⇧4 opens the
/// area selector (which also picks whole windows on hover). Every other
/// feature is triggered from the menu bar, so it gets no hotkey.
/// No special permissions required. If macOS's own ⌘⇧4 shortcut is still
/// enabled both will fire; users can turn the system one off in
/// System Settings → Keyboard → Keyboard Shortcuts → Screenshots.
final class GlobalHotkeyService {
    struct Hotkey {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let mode: CaptureMode
    }

    /// Called on the main thread when a capture hotkey fires.
    var onTrigger: ((CaptureMode) -> Void)?

    private let hotkeys: [Hotkey] = [
        Hotkey(id: 1, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), mode: .area),
    ]

    private var hotkeyRefs: [EventHotKeyRef?] = []
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

    func register() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &hotkeyID)
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                service.handle(id: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
        guard status == noErr else {
            NSLog("WinterShot: hotkey handler install failed (%d)", status)
            return
        }

        for hotkey in hotkeys {
            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: Self.signature, id: hotkey.id)
            let result = RegisterEventHotKey(hotkey.keyCode,
                                             hotkey.modifiers,
                                             hotkeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if result == noErr {
                hotkeyRefs.append(ref)
            } else {
                NSLog("WinterShot: could not register hotkey for %@ (%d)",
                      hotkey.mode.rawValue, result)
            }
        }
        NSLog("WinterShot: registered %d global hotkeys", hotkeyRefs.count)
    }

    func unregister() {
        hotkeyRefs.forEach { ref in
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotkeyRefs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func handle(id: UInt32) {
        guard let hotkey = hotkeys.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?(hotkey.mode)
        }
    }
}
