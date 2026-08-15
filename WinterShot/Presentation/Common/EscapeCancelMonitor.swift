import AppKit
import Carbon.HIToolbox

/// Cancels a capture overlay on Esc. A local event monitor handles the case
/// where the app is active, but a hotkey-triggered overlay often appears while
/// another app stays frontmost (macOS 14+ can deny background activation), so
/// a temporary Carbon hotkey on the bare Esc key covers that case too — it
/// fires regardless of focus and needs no accessibility permission. The
/// hotkey exists only while the overlay is up; stop() releases Esc back to
/// the system.
@MainActor
final class EscapeCancelMonitor {
    private var localMonitor: Any?
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onCancel: (() -> Void)?

    private static let signature: OSType = {
        // 'WESC' as a four-char code.
        var result: OSType = 0
        for byte in "WESC".utf8 { result = (result << 8) | OSType(byte) }
        return result
    }()

    deinit {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func start(onCancel: @escaping () -> Void) {
        stop()
        self.onCancel = onCancel

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.fire()
                return nil
            }
            return event
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let monitor = Unmanaged<EscapeCancelMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.fire() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
        guard status == noErr else {
            NSLog("WinterShot: Esc handler install failed (%d)", status)
            return
        }

        let hotkeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Escape),
                                         0,
                                         hotkeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotkeyRef)
        if result != noErr {
            NSLog("WinterShot: could not register Esc cancel hotkey (%d)", result)
        }
    }

    func stop() {
        onCancel = nil
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func fire() {
        // Both the local monitor and the Carbon hotkey can fire for one press;
        // clearing the callback first makes the cancel one-shot.
        guard let onCancel else { return }
        stop()
        onCancel()
    }
}
