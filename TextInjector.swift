import Cocoa
import ApplicationServices

/// Text insertion at cursor — two-tier strategy:
///
///   Tier 1: Accessibility — direct assignment of kAXSelectedTextAttribute on
///           the focused UI element. Bypasses pasteboard, inserts byte-for-byte
///           without losing spaces or racing pasteboard listeners.
///           Read-back verification is required since some apps report success without inserting.
///   Tier 2: Synthesized Cmd+V via pasteboard — universal fallback
///           (for terminal emulators and non-AX editable apps).
class TextInjector {
    static let shared = TextInjector()

    /// Terminal apps: lack editable AX text element — fall back to paste directly.
    private static let forcePasteBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    func inject(text: String) {
        guard !text.isEmpty else { return }
        if insertViaAX(text, verify: true) { return }
        pasteViaKeyboard(text)
    }

    /// Appends text at the cursor (used by streaming mode — called every few words).
    func injectTextAppending(_ text: String) {
        guard !text.isEmpty else { return }
        if insertViaAX(text, verify: true) { return }
        pasteViaKeyboard(text)
    }

    // MARK: - Tier 1: Accessibility

    /// Direct AX insertion with read-back verification. Returns false if the element
    /// does not support AX insertion (or value was unchanged) — falls back to paste.
    private func insertViaAX(_ text: String, verify: Bool) -> Bool {
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.forcePasteBundles.contains(bundle) {
            return false
        }

        let system = AXUIElementCreateSystemWide()
        // Prevent unresponsive target apps from blocking the thread: 1.5s timeout.
        AXUIElementSetMessagingTimeout(system, 1.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // Never inject text into secure password fields.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           (roleRef as? String) == "AXSecureTextField" {
            return false
        }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        let before = verify ? stringValue(of: element) : nil
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return false
        }

        // Read-back verification: some apps report success without updating the field.
        if verify, let before = before {
            var landed = false
            for _ in 0..<3 {
                if let after = stringValue(of: element), after != before {
                    landed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.04)
            }
            if !landed { return false }
        }
        return true
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    // MARK: - Tier 2: pasteboard + Cmd+V

    private func pasteViaKeyboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to let system register clipboard content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulatePaste()
        }
    }

    private func simulatePaste() {
        // Single paste event: CGEvent Cmd+V (requires Accessibility permission).
        // NOTE: previously an AppleScript fallback ran here too, causing double paste.
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // 9 = 'V'
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
