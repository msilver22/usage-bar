import AppKit
import Carbon.HIToolbox

enum ShortcutChoice: String, CaseIterable, Identifiable {
    case controlOptionU = "⌃⌥U"
    case commandShiftU = "⌘⇧U"
    case disabled = "Disabled"
    var id: String { rawValue }
    var modifiers: UInt32 { UInt32(self == .commandShiftU ? cmdKey | shiftKey : controlKey | optionKey) }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ choice: ShortcutChoice) -> Bool {
        if choice == .disabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            return true
        }
        guard handler != nil else { return false }
        nextID += 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_U), choice.modifiers,
                                        EventHotKeyID(signature: 0x55534252, id: nextID),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        return true
    }
}
