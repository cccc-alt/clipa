import AppKit
import Carbon.HIToolbox

struct HotkeySpec: Equatable {
    let name: String
    let keyCode: Int
    let modifiers: Int
}

extension HotkeySpec {

    static let panelToggle = HotkeySpec(
        name: "⌃⌘V",
        keyCode: kVK_ANSI_V,
        modifiers: cmdKey | controlKey
    )
}

final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private struct Registration {
        var hotKeyRef: EventHotKeyRef
        var handler: () -> Void
    }

    private let signature: OSType = OSType(0x434C_5041)
    private var eventHandlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1

    private init() {
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKey
            )

            if status == noErr,
               hotKey.signature == GlobalHotkey.shared.signature {
                GlobalHotkey.shared.registrations[hotKey.id]?.handler()
            }
            return noErr
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
        if installStatus != noErr {
            NSLog("Clipa global hotkey handler install failed")
        }
    }

    @discardableResult
    func register(
        spec: HotkeySpec,
        handler: @escaping () -> Void
    ) -> UInt32? {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(spec.keyCode),
            UInt32(spec.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            NSLog("Clipa hotkey registration failed (\(spec.name))")
            return nil
        }
        registrations[id] = Registration(hotKeyRef: hotKeyRef, handler: handler)
        return id
    }

    func unregister(_ token: UInt32) {
        guard let registration = registrations.removeValue(forKey: token) else {
            return
        }
        UnregisterEventHotKey(registration.hotKeyRef)
    }

    @discardableResult
    func register(
        keyCode: Int,
        modifiers: Int,
        handler: @escaping () -> Void
    ) -> Bool {
        register(
            spec: HotkeySpec(
                name: "custom(keyCode=\(keyCode), modifiers=\(modifiers))",
                keyCode: keyCode,
                modifiers: modifiers
            ),
            handler: handler
        ) != nil
    }
}
