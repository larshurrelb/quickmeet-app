import AppKit
import Carbon.HIToolbox

/// A single global shortcut, ⌥⌘R.
///
/// **`RegisterEventHotKey`, not a `CGEventTap`.** QuickTalk needs a tap because it watches
/// a modifier key being *held*, and that costs an Input Monitoring grant plus a relaunch to
/// pick it up. A meeting is started and stopped, not held, so an ordinary hot key does the
/// job — and a Carbon hot key needs no permission whatsoever. That is the entire reason
/// QuickMeet's permission list is two items long instead of four.
///
/// It also means nothing here ever sees a keystroke that is not this exact combination,
/// which is a far better position for an app that records audio to be in.
@MainActor
final class Hotkey {
    var onFire: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x514D5448)   // 'QMTH'

    func register() {
        guard reference == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard id.signature == Hotkey.signature else { return noErr }

                let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { hotkey.onFire?() } }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        if status == noErr {
            self.reference = reference
            Diagnostics.log("hotkey ⌥⌘R registered")
        } else {
            // Another app already owns the combination. Not fatal — the menu bar item is
            // the primary control and always works.
            Diagnostics.recordError("could not register ⌥⌘R (status \(status)) — menu bar still works")
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
