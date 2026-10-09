import Cocoa
import AVFoundation
import UserNotifications
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var historyMenu: NSMenu!
    private var history: [String] = []
    private var currentState = "idle"

    private let recorder = AudioRecorder()
    private var streamer: StreamingTranscriber?
    private var isRecording = false

    /// Asynchronous processing in flight (batch fallback or awaiting final chunk).
    /// Hotkey triggers are ignored in this state to avoid overlapping injection sessions.
    private var isProcessing = false
    /// Guard against duplicate concurrent batch requests.
    private var isBatchRunning = false

    /// Words already injected during the current streaming session.
    /// Tracked by actual words to safely handle recognizer prefix revisions.
    private var injectedWords: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Load persisted history from previous sessions.
        history = SettingsManager.shared.history
        updateHistoryMenu()

        // Listen for language changes in settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )

        // Request microphone permission on startup
        recorder.requestMicrophoneAccess { granted in
            if !granted {
                AppLog.log("⚠️ " + L10n.tr("Доступ к микрофону не предоставлен.", "Microphone access not granted."))
            }
        }

        // Setup Carbon Global HotKey
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleRecording()
        }
        HotKeyManager.shared.registerCurrent()

        AppLog.log("🚀 WhisperMe started in menu bar.")
    }

    @objc private func languageDidChange() {
        historyItem?.title = L10n.tr("История", "History")
        settingsItem?.title = L10n.tr("Настройки…", "Settings…")
        quitItem?.title = L10n.tr("Завершить WhisperMe", "Quit WhisperMe")
        updateHistoryMenu()
        updateStatusUI(state: currentState)
    }

    // MARK: - Status bar & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusUI(state: "idle")

        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: L10n.tr("Начать запись", "Start Recording"), action: #selector(toggleRecording), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        historyItem = NSMenuItem(title: L10n.tr("История", "History"), action: nil, keyEquivalent: "")
        historyMenu = NSMenu()
        historyItem.submenu = historyMenu
        updateHistoryMenu()
        menu.addItem(historyItem)

        settingsItem = NSMenuItem(title: L10n.tr("Настройки…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        quitItem = NSMenuItem(title: L10n.tr("Завершить WhisperMe", "Quit WhisperMe"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// SF Symbol template image adapting to system light/dark appearance.
    /// Supports fallback symbol names for backward compatibility with older macOS versions.
    private func statusIcon(_ name: String, fallbacks: [String] = []) -> NSImage? {
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "WhisperMe")
        if image == nil {
            for fallback in fallbacks {
                if let fallbackImage = NSImage(systemSymbolName: fallback, accessibilityDescription: "WhisperMe") {
                    image = fallbackImage
                    break
                }
            }
        }
        guard let validImage = image else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let sized = validImage.withSymbolConfiguration(config) ?? validImage
        sized.isTemplate = true
        return sized
    }

    @objc func toggleRecording() {
        // Prevent re-triggering while processing in flight
        guard !isProcessing else { return }
        if !isRecording {
            startStreaming()
        } else {
            stopStreaming()
        }
    }

    // MARK: - Streaming mode (text appears at cursor while speaking)

    private func startStreaming() {
        guard !isRecording else { return }

        let provider = SettingsManager.shared.provider
        let apiKey = SettingsManager.shared.apiKey
        guard !apiKey.isEmpty else {
            AppLog.log("❌ API key for \(provider.title) not configured — open Settings.")
            NSSound(named: "Basso")?.play()
            openSettings()
            return
        }

        // Concurrently record audio to file for fallback if streaming drops.
        recorder.start()

        isRecording = true
        isProcessing = false
        isBatchRunning = false
        injectedWords = []

        if SettingsManager.shared.playSounds {
            NSSound(named: "Tink")?.play()
        }
        updateStatusUI(state: "recording")

        // Check if provider supports real-time streaming
        guard let streamModel = provider.liveModel(for: SettingsManager.shared.model) else {
            AppLog.log("🎙️ \(provider.title): streaming not available — batch recording, text inserted after stop.")
            return
        }

        let s = StreamingTranscriber(apiKey: apiKey, model: streamModel)
        s.onInterim = { [weak self] fullTextSoFar in
            guard let self, !SettingsManager.shared.insertAfterStop else { return }
            self.injectInterimDelta(fullTextSoFar: fullTextSoFar)
        }
        s.onFinal = { [weak self] finalChunk in
            guard let self, !SettingsManager.shared.insertAfterStop else { return }
            self.injectInterimDelta(fullTextSoFar: finalChunk)
            self.injectedWords = []
        }
        s.onError = { [weak self] message in
            AppLog.log("❌ Live stream error: \(message) — falling back to batch recognition")
            self?.fallbackToBatch()
        }
        streamer = s

        do {
            try s.start()
            AppLog.log("\n🟢 [Gemini Live Stream] Speak now — text will appear at cursor...")
        } catch {
            AppLog.log("❌ Failed to start streaming: \(error.localizedDescription) — falling back to batch")
            fallbackToBatch()
        }
    }

    /// Falls back to batch transcription using the recorded audio file.
    private func fallbackToBatch() {
        isRecording = false
        isProcessing = true
        streamer = nil
        injectedWords = []
        updateStatusUI(state: "transcribing")
        transcribeRecordedAudio()
    }

    /// Injects the tail of the interim text that hasn't been typed yet.
    /// Gemini interim = full text of the CURRENT segment (from the last
    /// final); AppDelegate resets injectedWords on each final, so this diff
    /// always works within one segment.
    /// If the recognizer REVISES already-injected words (prefix breaks),
    /// the old versions stay in the field — we can't un-inject; the prefix
    /// guard ensures revised words are never duplicated. Divergence is
    /// logged for diagnostics.
    ///
    /// Each injected piece carries a TRAILING space. A leading space can be
    /// swallowed by some apps' paste handling, while a trailing space inside
    /// the pasted string survives everywhere.
    private func injectInterimDelta(fullTextSoFar: String) {
        guard let result = InterimDelta.next(previous: injectedWords, fullTextSoFar: fullTextSoFar) else { return }

        // Revision diagnostics: recognizer amended previously injected words.
        if let range = result.revisedRange {
            AppLog.log("⚠️ Interim revised words \(range.lowerBound + 1)–\(range.upperBound) — earlier version remains in text field")
        }

        injectedWords = result.words
        let delta = result.delta
        DispatchQueue.main.async {
            TextInjector.shared.injectTextAppending(delta)
        }
    }

    private func stopStreaming() {
        guard isRecording else { return }
        isRecording = false
        AppLog.log("⏹ stopStreaming: begin (isProcessing=\(isProcessing))")

        if SettingsManager.shared.playSounds {
            NSSound(named: "Pop")?.play()
        }

        // Asynchronous stop: awaits final chunk from server (up to 2s) to preserve sentence endings.
        updateStatusUI(state: "transcribing")
        let streamer = self.streamer
        self.streamer = nil
        guard let streamer else {
            // No streamer: provider is batch-only (e.g. OpenRouter) or failed before stop.
            AppLog.log("⏹ stopStreaming: no streaming session — batch fallback path")
            finishStreaming(fullText: "")
            return
        }
        isProcessing = true

        // Watchdog backstop: if stop completion drops, prevent isProcessing from permanently locking.
        var finished = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            AppLog.log("⏱ watchdog: stop() completion timeout after 4s — emergency batch fallback")
            self.isProcessing = false
            self.finishStreaming(fullText: streamer.text)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: watchdog)

        streamer.stop(timeout: 2.0) { [weak self] fullText in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                watchdog.cancel()
                self?.finishStreaming(fullText: fullText)
            }
        }
    }

    private func finishStreaming(fullText: String) {
        isProcessing = false
        AppLog.log("⏹ finishStreaming: text=\(fullText.isEmpty ? "<empty>" : "<\(fullText.count) chars>")")
        if !fullText.isEmpty {
            AppLog.log("✨ [Stream result]: \"\(fullText)\"")
            addToHistory(text: fullText)
            // In insertAfterStop mode, inject the full text once when stopping.
            if SettingsManager.shared.insertAfterStop {
                TextInjector.shared.inject(text: fullText)
            }
            _ = recorder.stop()
            updateStatusUI(state: "idle")
        } else {
            // Stream produced no text (connection dropped or no speech): fall back to batch.
            AppLog.log("⚠️ No streaming text — attempting batch fallback")
            updateStatusUI(state: "transcribing")
            transcribeRecordedAudio()
        }
    }

    /// Transcribes recorded audio via batch API.
    private func transcribeRecordedAudio() {
        guard !isBatchRunning else {
            AppLog.log("⚠️ Batch transcription already running — skipping duplicate request")
            return
        }
        guard let audioData = recorder.stop() else {
            AppLog.log("⚠️ No audio data recorded.")
            isProcessing = false
            updateStatusUI(state: "idle")
            showNotification(title: "WhisperMe", body: L10n.tr("Аудио не записано — проверьте доступ к микрофону", "No audio recorded — check microphone permissions"))
            return
        }
        isBatchRunning = true

        let startTime = Date()
        TranscriptionService.shared.transcribe(audioData: audioData) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isProcessing = false
                self.isBatchRunning = false
                self.updateStatusUI(state: "idle")

                switch result {
                case .success(let text):
                    let elapsed = Date().timeIntervalSince(startTime)
                    if !text.isEmpty {
                        AppLog.log("✨ [Transcribed (\(String(format: "%.2f", elapsed))s)]: \"\(text)\"")
                        self.addToHistory(text: text)
                        TextInjector.shared.inject(text: text)
                    } else {
                        AppLog.log("⚠️ No speech detected.")
                        self.showNotification(title: "WhisperMe", body: L10n.tr("Речь не обнаружена", "No speech detected"))
                    }
                case .failure(let error):
                    let msg: String
                    if let terr = error as? TranscriptionError {
                        msg = terr.localizedDescription(isRussian: L10n.isRussian)
                    } else {
                        msg = error.localizedDescription
                    }
                    AppLog.log("❌ Transcription error: \(msg)")
                    self.showNotification(title: "WhisperMe", body: msg)
                    if SettingsManager.shared.playSounds {
                        NSSound(named: "Basso")?.play()
                    }
                }
            }
        }
    }

    /// Delivers notification to the user.
    private func showNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    private func updateStatusUI(state: String) {
        currentState = state
        guard let button = statusItem.button else { return }
        switch state {
        case "recording":
            button.image = statusIcon("waveform", fallbacks: ["waveform.path", "circle.fill"])
            button.title = button.image == nil ? "🔴" : ""
            toggleMenuItem?.title = L10n.tr("Остановить запись", "Stop Recording")
        case "transcribing":
            button.image = statusIcon("ellipsis", fallbacks: ["ellipsis.circle"])
            button.title = button.image == nil ? "⏳" : ""
            toggleMenuItem?.title = L10n.tr("Обработка…", "Processing…")
        default:
            button.image = statusIcon("mic", fallbacks: ["mic.fill", "microphone"])
            button.title = button.image == nil ? "🎙️" : ""
            toggleMenuItem?.title = L10n.tr("Начать запись", "Start Recording")
        }
    }

    private func addToHistory(text: String) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
        SettingsManager.shared.history = history
        updateHistoryMenu()
    }

    private func updateHistoryMenu() {
        historyMenu.removeAllItems()
        if history.isEmpty {
            let empty = NSMenuItem(title: L10n.tr("Пока нет записей", "No history yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }

        for text in history {
            let preview = text.count > 35 ? String(text.prefix(35)) + "…" : text
            let item = NSMenuItem(title: preview, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = text
            historyMenu.addItem(item)
        }
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
