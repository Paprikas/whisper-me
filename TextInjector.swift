import Cocoa
import ApplicationServices

/// Serializes insertion jobs so two streaming chunks cannot share a clipboard.
final class TextInjector {
    static let shared = TextInjector()
    private struct Job { let text: String; let pid: pid_t }
    private var jobs: [Job] = []
    private var busy = false
    private let axQueue = DispatchQueue(label: "com.whisperme.accessibility")
    private static let forcePasteBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty"
    ]

    func inject(text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !text.isEmpty, let app = NSWorkspace.shared.frontmostApplication else { return }
        jobs.append(Job(text: text, pid: app.processIdentifier))
        drain()
    }

    func injectTextAppending(_ text: String) { inject(text: text) }

    private func drain() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        let job = jobs.removeFirst()
        guard isTarget(job) else { finish(); return }
        let forcePaste = Self.forcePasteBundles.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        axQueue.async {
            let result = self.insertViaAX(job.text, pid: job.pid, forcePaste: forcePaste)
            DispatchQueue.main.async {
                switch result {
                case .inserted, .blocked: self.finish()
                case .paste:
                    guard self.isTarget(job) else { self.finish(); return }
                    self.paste(job)
                }
            }
        }
    }

    private func isTarget(_ job: Job) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == job.pid
    }

    enum AXResult: Equatable { case inserted, paste, blocked }

    /// A timed-out IPC may already have applied the write. Never paste twice.
    static func resultOfAXWrite(_ status: AXError) -> AXResult {
        switch status {
        case .success: return .inserted
        case .cannotComplete: return .blocked
        default: return .paste
        }
    }

    /// Run AX IPC off the UI/audio threads. Secure fields block BOTH tiers.
    private func insertViaAX(_ text: String, pid: pid_t, forcePaste: Bool) -> AXResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return .paste }
        let element = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               value as? String == "AXSecureTextField" { return .blocked }
        }
        guard !forcePaste else { return .paste }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return .paste }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        // Read-back can lag a successful write; it is not safe evidence for retry.
        return Self.resultOfAXWrite(status)
    }

    private func paste(_ job: Job) {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        board.clearContents()
        board.setString(job.text, forType: .string)
        let change = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.isTarget(job), board.changeCount == change else {
                self.restore(saved, ifUnchanged: change)
                self.finish()
                return
            }
            self.simulatePaste()
            // Allow target to consume Cmd+V before restoring or starting next job.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.restore(saved, ifUnchanged: change)
                self.finish()
            }
        }
    }

    private func restore(_ items: [NSPasteboardItem], ifUnchanged count: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return } // preserve a newer user copy
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    private func finish() { busy = false; drain() }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
