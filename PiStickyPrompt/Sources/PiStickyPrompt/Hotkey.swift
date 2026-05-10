import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey via Carbon's RegisterEventHotKey.
/// macOS still supports this for menu-bar / accessory apps and does not
/// require Accessibility permissions for hotkey-only registration.
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private let handler: () -> Void
    private static var instances: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        self.handler = handler
        let id = GlobalHotkey.nextID
        GlobalHotkey.nextID += 1
        GlobalHotkey.instances[id] = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x70695062 /* 'piPb' */), id: id)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let inst = GlobalHotkey.instances[hkID.id] {
                DispatchQueue.main.async { inst.handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)

        RegisterEventHotKey(keyCode, GlobalHotkey.carbonModifiers(modifiers),
                            hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command)  { m |= UInt32(cmdKey) }
        if flags.contains(.option)   { m |= UInt32(optionKey) }
        if flags.contains(.shift)    { m |= UInt32(shiftKey) }
        if flags.contains(.control)  { m |= UInt32(controlKey) }
        return m
    }
}
