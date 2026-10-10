import AppKit
import Carbon.HIToolbox

/// One global hotkey definition.
///
/// Named and centralised so the app and the self-test agree on what is
/// actually registered, and so a combination that collides with a system
/// shortcut is visible in one place instead of buried in a call site.
struct HotkeySpec: Equatable {
    let name: String
    let keyCode: Int
    let modifiers: Int
}

extension HotkeySpec {
    /// The app's only global hotkey: ⌃⌘V opens / closes the clipboard panel.
    ///
    /// ⌘⇧V and ⌃V used to be registered as well; they were dropped so Clipa
    /// takes exactly one combination away from the rest of the system (⌃V in
    /// particular stole Control-V from every app while Clipa ran).
    static let panelToggle = HotkeySpec(
        name: "⌃⌘V",
        keyCode: kVK_ANSI_V,
        modifiers: cmdKey | controlKey
    )
}

/// Registers global hotkeys. Each registration gets its own id and handler, so
/// the app could hold more than one; today it registers exactly one (⌃⌘V).
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private struct Registration {
        var hotKeyRef: EventHotKeyRef
        var handler: () -> Void
    }

    private let signature: OSType = OSType(0x434C_5041) // 'CLPA'
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
            // Both halves of the identity are checked. Matching on the id alone
            // would dispatch a hotkey that belongs to some other signature
            // straight into this app's table.
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

    /// Registers `spec`, returning a token for `unregister(_:)` or `nil` when
    /// the system refused it (already taken by another app).
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

    /// Releases a registration, so a preference that turns a shortcut off can
    /// take effect without relaunching the app.
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
