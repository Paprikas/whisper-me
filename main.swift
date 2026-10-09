import Cocoa
import ApplicationServices

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Accessibility is required for global paste injection (CGEvent Cmd+V).
if !AXIsProcessTrustedWithOptions([
    kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
] as CFDictionary) {
    print("⚠️ Accessibility permission not granted — text injection will not work. Grant access in System Settings → Privacy & Security → Accessibility.")
}

app.run()
