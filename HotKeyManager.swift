import Cocoa
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onTrigger: (() -> Void)?

    init() {}

    func registerCurrent() {
        guard let combo = SettingsManager.shared.hotkeyCombo else {
            unregister()
            AppLog.log("ℹ️ Global hotkey disabled.")
            return
        }
        register(keyCode: combo.keyCode, modifiers: combo.modifiers)
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        let hotKeyID = EventHotKeyID(signature: OSType(0x57485350), id: 1) // "WHSP"
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                HotKeyManager.shared.onTrigger?()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            AppLog.log("⚠️ Failed to register hotkey (\(KeyCombo(keyCode: keyCode, modifiers: modifiers).displayString)): OSStatus \(status)")
        } else {
            AppLog.log("✅ Hotkey registered: \(KeyCombo(keyCode: keyCode, modifiers: modifiers).displayString)")
        }
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
