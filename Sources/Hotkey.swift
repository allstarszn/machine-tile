import AppKit
import Carbon.HIToolbox

/// The system-wide ⌃⌥⌘M shortcut.
///
/// Carbon rather than a local event monitor, because the point of the shortcut is
/// that it works while another app is in front.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54494C), id: 1) // 'MTIL'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey | cmdKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
