import Cocoa
import Carbon
import ServiceManagement

extension KeyCombo {
    /// Converts NSEvent modifier flags to Carbon bitmask
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}

/// Interactive shortcut recorder control (similar to native macOS / Raycast / ShortcutRecorder).
/// Displays active shortcut (e.g. ⌘⇧D), enters recording mode on click, captures
/// modifier keys in real time, validates the combination, and updates the value.
/// Includes an embedded clear button (✕).
final class ShortcutRecorderControl: NSView {
    var combo: KeyCombo? {
        didSet {
            updateUI()
        }
    }

    var onChange: ((KeyCombo?) -> Void)?

    private(set) var isRecording = false
    private var recordedModifiers: UInt32 = 0
    private var eventMonitor: Any?

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var clearButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear hotkey")
        button.contentTintColor = .tertiaryLabelColor
        button.target = self
        button.action = #selector(clearClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        stopRecording()
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        addSubview(titleLabel)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        updateUI()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        if isRecording {
            cancelRecording()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && isRecording {
            cancelRecording()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateUI()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isRecording {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clearButton.frame.contains(point) && !clearButton.isHidden {
            super.mouseDown(with: event)
            return
        }

        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordedModifiers = 0
        window?.makeFirstResponder(self)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            return self.handleRecordingEvent(event)
        }

        updateUI()
    }

    func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        recordedModifiers = 0
        updateUI()
        window?.invalidateCursorRects(for: self)
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
            recordedModifiers = mods
            updateUI()
            return nil
        }

        if event.type == .keyDown {
            let keyCode = UInt32(event.keyCode)
            let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)

            // Esc without modifiers: cancel recording without changing
            if keyCode == UInt32(kVK_Escape) && mods == 0 {
                cancelRecording()
                return nil
            }

            // Backspace / Delete without modifiers: clear hotkey
            if (keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete)) && mods == 0 {
                combo = nil
                onChange?(nil)
                stopRecording()
                return nil
            }

            let candidate = KeyCombo(keyCode: keyCode, modifiers: mods)
            if candidate.isValid {
                combo = candidate
                onChange?(candidate)
                stopRecording()
                return nil
            } else {
                NSSound.beep()
                shake()
                return nil
            }
        }

        return event
    }

    @objc private func clearClicked() {
        if isRecording {
            cancelRecording()
        } else {
            combo = nil
            onChange?(nil)
        }
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.25
        animation.values = [-5.0, 5.0, -3.0, 3.0, -1.0, 1.0, 0.0]
        layer?.add(animation, forKey: "shake")
    }

    func updateUI() {
        if isRecording {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor

            if recordedModifiers != 0 {
                titleLabel.stringValue = KeyCombo.modifierSymbols(modifiers: recordedModifiers) + "…"
            } else {
                titleLabel.stringValue = L10n.tr("Нажмите клавиши…", "Press keys…")
            }
            titleLabel.textColor = .controlAccentColor
            clearButton.isHidden = false
            clearButton.contentTintColor = .controlAccentColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

            if let combo = combo {
                titleLabel.stringValue = combo.displayString
                titleLabel.textColor = .controlTextColor
                clearButton.isHidden = false
                clearButton.contentTintColor = .tertiaryLabelColor
            } else {
                titleLabel.stringValue = L10n.tr("Не задано (нажмите для записи)", "Not set (click to record)")
                titleLabel.textColor = .placeholderTextColor
                clearButton.isHidden = true
            }
        }
        clearButton.toolTip = L10n.tr("Очистить горячую клавишу", "Clear hotkey")
    }
}

/// WhisperMe settings window controller (Auto Layout NSStackView).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Cache of OpenRouter models catalog to prevent frequent network refetches.
    private static var openRouterModelCache: [ModelOption] = []

    private var providerHeader: NSTextField!
    private var providerLabel: NSTextField!
    private var providerPopup: NSPopUpButton!

    private var keyHeader: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var revealButton: NSButton!
    private var keyHint: NSTextField!
    private var getKeyButton: NSButton!

    private var recognitionHeader: NSTextField!
    private var modelLabel: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var modelHint: NSTextField!

    private var hotkeyLabel: NSTextField!
    private var hotkeyRecorder: ShortcutRecorderControl!
    private var resetHotkeyButton: NSButton!
    private var hotkeyHint: NSTextField!

    private var insertModeLabel: NSTextField!
    private var insertModePopup: NSPopUpButton!
    private var insertModeHint: NSTextField!

    private var soundsLabel: NSTextField!
    private var soundsCheck: NSButton!

    private var cleanFillerLabel: NSTextField!
    private var cleanModePopup: NSPopUpButton!

    private var vocabLabel: NSTextField!
    private var vocabField: NSTextField!
    private var vocabHint: NSTextField!

    private var appHeader: NSTextField!
    private var languageLabel: NSTextField!
    private var languagePopup: NSPopUpButton!

    private var launchAtLoginCheck: NSButton!
    private var accessibilityLabel: NSTextField!
    private var accessibilityButton: NSButton!

    private var cancelButton: NSButton!
    private var saveButton: NSButton!

    private var initialLanguage: AppLanguage = .system
    private var displayedProvider: TranscriptionProvider?
    private var draftKeys: [TranscriptionProvider: APIKeyDraft] = [:]
    private var draftModels: [TranscriptionProvider: String] = [:]
    private var saved = false

    private func captureProviderDraft() {
        guard let provider = displayedProvider else { return }
        draftKeys[provider]?.value = apiKeyField.stringValue
        if modelOptions.indices.contains(modelPopup.indexOfSelectedItem) {
            draftModels[provider] = modelOptions[modelPopup.indexOfSelectedItem].id
        }
    }

    /// Models shown in modelPopup for the selected provider.
    private var modelOptions: [ModelOption] = []
    /// Sequence counter to discard out-of-order model list responses when switching providers.
    private var modelsRequestID = 0

    /// Provider currently selected in the popup.
    private var selectedProvider: TranscriptionProvider {
        let all = TranscriptionProvider.allCases
        let index = max(0, min(providerPopup.indexOfSelectedItem, all.count - 1))
        return all[index]
    }

    private let contentWidth: CGFloat = 460

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth + 40, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.tr("Настройки WhisperMe", "WhisperMe Settings")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let settings = SettingsManager.shared

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // --- Provider ---
        providerHeader = header(L10n.tr("Провайдер", "Provider"))

        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: TranscriptionProvider.allCases.map(\.title))
        providerPopup.selectItem(at: TranscriptionProvider.allCases.firstIndex(of: settings.provider) ?? 0)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        let (providerRow, pLabel) = labeledRow(L10n.tr("Провайдер:", "Provider:"), providerPopup)
        providerLabel = pLabel

        // --- Ключ API ---
        keyHeader = header(L10n.tr("Ключ API", "API Key"))

        apiKeyField = NSSecureTextField()
        apiKeyField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false

        revealButton = iconButton(systemName: "eye", action: #selector(toggleKeyVisibility))

        let keyRow = NSStackView(views: [apiKeyField, revealButton])
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 8
        keyRow.translatesAutoresizingMaskIntoConstraints = false

        keyHint = smallLabel("")
        getKeyButton = linkButton(L10n.tr("Получить ключ…", "Get API key…"), action: #selector(openKeyPage))

        let hintRow = NSStackView(views: [keyHint, getKeyButton])
        hintRow.orientation = .horizontal
        hintRow.alignment = .firstBaseline
        hintRow.spacing = 8
        hintRow.translatesAutoresizingMaskIntoConstraints = false

        // --- Распознавание ---
        recognitionHeader = header(L10n.tr("Распознавание", "Recognition"))

        modelPopup = NSPopUpButton()
        let (modelRow, mLabel) = labeledRow(L10n.tr("Модель:", "Model:"), modelPopup)
        modelLabel = mLabel
        modelHint = smallLabel("")

        hotkeyRecorder = ShortcutRecorderControl()
        hotkeyRecorder.combo = settings.hotkeyCombo
        hotkeyRecorder.translatesAutoresizingMaskIntoConstraints = false

        resetHotkeyButton = NSButton(title: L10n.tr("По умолчанию", "Default"), target: self, action: #selector(resetHotkeyToDefault))
        resetHotkeyButton.bezelStyle = .rounded
        resetHotkeyButton.font = .systemFont(ofSize: 11)
        resetHotkeyButton.translatesAutoresizingMaskIntoConstraints = false

        let hotkeyStack = NSStackView(views: [hotkeyRecorder, resetHotkeyButton])
        hotkeyStack.orientation = .horizontal
        hotkeyStack.alignment = .centerY
        hotkeyStack.spacing = 8
        hotkeyStack.translatesAutoresizingMaskIntoConstraints = false

        let (hotkeyRow, hLabel) = labeledRow(L10n.tr("Горячая клавиша:", "Hotkey:"), hotkeyStack)
        hotkeyLabel = hLabel
        hotkeyHint = smallLabel(L10n.tr("Нажмите на поле и зажмите клавиши (требуется ⌘, ⌥ или ⌃). Esc — отмена.", "Click the box and press keys (requires ⌘, ⌥, or ⌃). Esc to cancel."))

        insertModePopup = NSPopUpButton()
        insertModePopup.addItems(withTitles: [
            L10n.tr("В реальном времени", "Real-time"),
            L10n.tr("После окончания записи", "After recording stops")
        ])
        insertModePopup.selectItem(at: settings.insertAfterStop ? 1 : 0)
        let (insertModeRow, imLabel) = labeledRow(L10n.tr("Вставка текста:", "Text insertion:"), insertModePopup)
        insertModeLabel = imLabel
        insertModeHint = smallLabel("")

        soundsCheck = NSButton(checkboxWithTitle: L10n.tr("Звуковые сигналы", "Sound effects"), target: nil, action: nil)
        soundsCheck.state = settings.playSounds ? .on : .off
        let (soundsRow, sLabel) = labeledRow(L10n.tr("Звук:", "Sound:"), soundsCheck)
        soundsLabel = sLabel

        cleanModePopup = NSPopUpButton()
        for mode in CleaningMode.allCases {
            cleanModePopup.addItem(withTitle: mode.title(for: settings.isRussian))
        }
        if let idx = CleaningMode.allCases.firstIndex(of: settings.cleaningMode) {
            cleanModePopup.selectItem(at: idx)
        }
        let (cleanFillerRow, cfLabel) = labeledRow(L10n.tr("Очистка речи:", "Clean Speech:"), cleanModePopup)
        cleanFillerLabel = cfLabel

        // --- Словарь ---
        vocabField = NSTextField(string: settings.customVocab)
        vocabField.placeholderString = L10n.tr("имена, термины — через запятую", "names, terms — comma-separated")
        let (vocabRow, vLabel) = labeledRow(L10n.tr("Словарь:", "Vocabulary:"), vocabField)
        vocabLabel = vLabel
        vocabHint = smallLabel("")

        // --- Приложение ---
        appHeader = header(L10n.tr("Приложение", "Application"))

        languagePopup = NSPopUpButton()
        for lang in AppLanguage.allCases {
            languagePopup.addItem(withTitle: lang.title(for: settings.isRussian))
        }
        if let idx = AppLanguage.allCases.firstIndex(of: settings.language) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let (languageRow, lLabel) = labeledRow(L10n.tr("Язык интерфейса:", "Language:"), languagePopup)
        languageLabel = lLabel

        launchAtLoginCheck = NSButton(checkboxWithTitle: L10n.tr("Запускать при входе в систему", "Launch at system login"), target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLoginCheck.state = SettingsManager.shared.launchAtLogin ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginCheck.state = .off
        }

        let axGranted = AXIsProcessTrusted()
        accessibilityLabel = NSTextField(labelWithString: axGranted ? L10n.tr("Универсальный доступ: разрешён ✓", "Accessibility: Granted ✓") : L10n.tr("Универсальный доступ: не разрешён — вставка не будет работать", "Accessibility: Not granted — text injection won't work"))
        accessibilityLabel.font = .systemFont(ofSize: 11)
        accessibilityLabel.textColor = axGranted ? .secondaryLabelColor : .systemRed
        accessibilityButton = linkButton(L10n.tr("Открыть Системные настройки", "Open System Settings"), action: #selector(openAccessibilitySettings))
        accessibilityButton.isHidden = axGranted
        let axRow = NSStackView(views: [accessibilityLabel, accessibilityButton])
        axRow.orientation = .horizontal
        axRow.alignment = .firstBaseline
        axRow.spacing = 8
        axRow.translatesAutoresizingMaskIntoConstraints = false

        // --- Кнопки ---
        cancelButton = NSButton(title: L10n.tr("Отмена", "Cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton = NSButton(title: L10n.tr("Сохранить", "Save"), target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.distribution = .fill
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let rows: [NSView] = [providerRow, keyRow, hintRow, modelRow, modelHint, hotkeyRow, hotkeyHint,
                              insertModeRow, insertModeHint, soundsRow, cleanFillerRow, vocabRow, vocabHint,
                              languageRow, axRow, buttonRow]
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        apiKeyField.widthAnchor.constraint(equalTo: keyRow.widthAnchor, constant: -34).isActive = true
        vocabField.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        modelPopup.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        cleanModePopup.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        hotkeyStack.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        resetHotkeyButton.setContentHuggingPriority(.required, for: .horizontal)
        hotkeyRecorder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        insertModePopup.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        languagePopup.widthAnchor.constraint(equalToConstant: contentWidth - 130).isActive = true
        soundsRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
        cleanFillerRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
        buttonRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for row in rows {
            row.setContentCompressionResistancePriority(.required, for: .vertical)
            row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let order: [NSView] = [
            providerHeader, providerRow, separator(),
            keyHeader, keyRow, hintRow, separator(),
            recognitionHeader, modelRow, modelHint, hotkeyRow, hotkeyHint, insertModeRow, insertModeHint,
            soundsRow, cleanFillerRow, vocabRow, vocabHint, separator(),
            appHeader, languageRow, axRow, launchAtLoginCheck, separator(),
            buttonRow,
        ]
        for view in order { stack.addArrangedSubview(view) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        // Size window to fit content fitting size.
        window?.setContentSize(NSSize(width: contentWidth + 40,
                                      height: stack.fittingSize.height + 40))

        updateLocalizedTexts()
    }

    // MARK: - View Factories

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> (NSStackView, NSTextField) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 118).isActive = true
        return (row, label)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func iconButton(systemName: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: systemName,
                               accessibilityDescription: "Toggle API key visibility")
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        return button
    }

    // MARK: - Localization

    @objc private func languageChanged() {
        let index = languagePopup.indexOfSelectedItem
        if AppLanguage.allCases.indices.contains(index) {
            SettingsManager.shared.language = AppLanguage.allCases[index]
            updateLocalizedTexts()
        }
    }

    private func updateLocalizedTexts() {
        let isRu = SettingsManager.shared.isRussian
        window?.title = L10n.tr("Настройки WhisperMe", "WhisperMe Settings")

        providerHeader.stringValue = L10n.tr("Провайдер", "Provider")
        providerLabel.stringValue = L10n.tr("Провайдер:", "Provider:")

        recognitionHeader.stringValue = L10n.tr("Распознавание", "Recognition")
        modelLabel.stringValue = L10n.tr("Модель:", "Model:")
        hotkeyLabel.stringValue = L10n.tr("Горячая клавиша:", "Hotkey:")
        resetHotkeyButton.title = L10n.tr("По умолчанию", "Default")
        hotkeyHint.stringValue = L10n.tr("Нажмите на поле и зажмите клавиши (требуется ⌘, ⌥ или ⌃). Esc — отмена.", "Click the box and press keys (requires ⌘, ⌥, or ⌃). Esc to cancel.")

        insertModeLabel.stringValue = L10n.tr("Вставка текста:", "Text insertion:")
        let currentInsertSel = insertModePopup.indexOfSelectedItem
        insertModePopup.removeAllItems()
        insertModePopup.addItems(withTitles: [
            L10n.tr("В реальном времени", "Real-time"),
            L10n.tr("После окончания записи", "After recording stops")
        ])
        insertModePopup.selectItem(at: max(0, min(currentInsertSel, 1)))

        soundsLabel.stringValue = L10n.tr("Звук:", "Sound:")
        soundsCheck.title = L10n.tr("Звуковые сигналы", "Sound effects")

        cleanFillerLabel.stringValue = L10n.tr("Очистка речи:", "Clean Speech:")
        let currentCleanSel = cleanModePopup.indexOfSelectedItem
        cleanModePopup.removeAllItems()
        for mode in CleaningMode.allCases {
            cleanModePopup.addItem(withTitle: mode.title(for: isRu))
        }
        if currentCleanSel >= 0 && currentCleanSel < CleaningMode.allCases.count {
            cleanModePopup.selectItem(at: currentCleanSel)
        } else if let idx = CleaningMode.allCases.firstIndex(of: SettingsManager.shared.cleaningMode) {
            cleanModePopup.selectItem(at: idx)
        }

        vocabLabel.stringValue = L10n.tr("Словарь:", "Vocabulary:")
        vocabField.placeholderString = L10n.tr("имена, термины — через запятую", "names, terms — comma-separated")

        appHeader.stringValue = L10n.tr("Приложение", "Application")
        languageLabel.stringValue = L10n.tr("Язык интерфейса:", "Language:")
        let currentLang = SettingsManager.shared.language
        languagePopup.removeAllItems()
        for lang in AppLanguage.allCases {
            languagePopup.addItem(withTitle: lang.title(for: isRu))
        }
        if let idx = AppLanguage.allCases.firstIndex(of: currentLang) {
            languagePopup.selectItem(at: idx)
        }

        launchAtLoginCheck.title = L10n.tr("Запускать при входе в систему", "Launch at system login")

        let axGranted = AXIsProcessTrusted()
        accessibilityLabel.stringValue = axGranted
            ? L10n.tr("Универсальный доступ: разрешён ✓", "Accessibility: Granted ✓")
            : L10n.tr("Универсальный доступ: не разрешён — вставка не будет работать", "Accessibility: Not granted — text injection won't work")
        accessibilityButton.title = L10n.tr("Открыть Системные настройки", "Open System Settings")

        cancelButton.title = L10n.tr("Отмена", "Cancel")
        saveButton.title = L10n.tr("Сохранить", "Save")
        getKeyButton.title = L10n.tr("Получить ключ…", "Get API key…")

        applyProvider(selectedProvider)
        hotkeyRecorder.updateUI()
    }

    // MARK: - Provider

    @objc private func providerChanged() {
        applyProvider(selectedProvider)
    }

    /// Reconfigures form fields for the selected provider.
    private func applyProvider(_ provider: TranscriptionProvider) {
        window?.makeFirstResponder(nil)
        captureProviderDraft()
        displayedProvider = provider
        keyHeader.stringValue = L10n.tr("Ключ API — \(provider.title)", "API Key — \(provider.title)")
        apiKeyField.placeholderString = provider == .gemini
            ? L10n.tr("Вставьте ключ Google AI Studio", "Enter Google AI Studio key")
            : L10n.tr("Вставьте ключ OpenRouter (sk-or-…)", "Enter OpenRouter key (sk-or-…)")
        if draftKeys[provider] == nil {
            draftKeys[provider] = APIKeyDraft(value: SettingsManager.shared.apiKey(for: provider))
        }
        apiKeyField.stringValue = draftKeys[provider]?.value ?? ""
        keyHint.stringValue = L10n.tr(
            "Ключ хранится только на этом Mac (Keychain или \(provider.apiKeyEnvName) в .env).",
            "Key is stored locally on this Mac (Keychain or \(provider.apiKeyEnvName) in .env)."
        )

        let streaming = provider.supportsStreaming
        insertModePopup.isEnabled = streaming
        insertModeHint.stringValue = streaming
            ? L10n.tr("«В реальном времени» — через Live-стриминг, текст появляется по ходу речи.", "Real-time: text appears at cursor as you speak via Live API.")
            : L10n.tr("\(provider.title): потоковой транскрипции нет — текст вставится целиком после остановки записи.", "\(provider.title): streaming not available — text inserted after recording ends.")

        vocabField.isEnabled = provider.supportsVocab
        vocabHint.stringValue = provider.supportsVocab
            ? L10n.tr("Только для режима batch (flash-модели): в Live-стриминге словарь не применяется.", "Batch mode only: vocabulary is not used in Live streaming.")
            : L10n.tr("\(provider.title): в API нет поля prompt — словарь здесь не применяется.", "\(provider.title): API lacks prompt field — vocabulary not supported.")

        modelHint.stringValue = provider == .gemini
            ? L10n.tr("Live-стриминг использует ту же модель в режиме -live.", "Live streaming uses the same model with -live suffix.")
            : L10n.tr("Список подгружается с OpenRouter — модели с распознаванием речи.", "List fetched from OpenRouter — speech recognition models.")

        reloadModelList(for: provider)
    }

    /// Reloads model choices for the selected provider.
    private func reloadModelList(for provider: TranscriptionProvider) {
        modelsRequestID += 1
        let requestID = modelsRequestID
        let saved = draftModels[provider] ?? SettingsManager.shared.model(for: provider)

        switch provider {
        case .gemini:
            fillModelPopup(with: provider.builtinModels, selecting: saved)

        case .openrouter:
            if !Self.openRouterModelCache.isEmpty {
                fillModelPopup(with: Self.openRouterModelCache, selecting: saved)
                return
            }
            modelOptions = []
            modelPopup.removeAllItems()
            modelPopup.addItem(withTitle: L10n.tr("Загрузка моделей…", "Loading models…"))
            modelPopup.isEnabled = false
            OpenRouterTranscriber.fetchModels(apiKey: draftKeys[provider]?.value ?? SettingsManager.shared.apiKey(for: provider)) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, requestID == self.modelsRequestID else { return }
                    switch result {
                    case .success(let options):
                        Self.openRouterModelCache = options
                        self.fillModelPopup(with: options, selecting: saved)
                    case .failure(let error):
                        AppLog.log("⚠️ Failed to load OpenRouter models: \(error.localizedDescription)")
                        self.fillModelPopup(with: [ModelOption(id: saved, title: saved)], selecting: saved)
                    }
                }
            }
        }
    }

    private func fillModelPopup(with options: [ModelOption], selecting modelID: String) {
        var choices = options
        if !modelID.isEmpty, !choices.contains(where: { $0.id == modelID }) {
            choices.insert(ModelOption(id: modelID, title: modelID), at: 0)
        }
        modelOptions = choices
        modelPopup.removeAllItems()
        for option in choices { modelPopup.addItem(withTitle: option.title) }
        if let index = choices.firstIndex(where: { $0.id == modelID }) {
            modelPopup.selectItem(at: index)
        }
        modelPopup.isEnabled = !choices.isEmpty
    }

    // MARK: - Actions

    @objc private func toggleKeyVisibility() {
        window?.makeFirstResponder(nil)
        let value = apiKeyField.stringValue
        let font = apiKeyField.font
        let placeholder = apiKeyField.placeholderString
        let willHide = !(apiKeyField.cell is NSSecureTextFieldCell)
        if willHide {
            apiKeyField.cell = NSSecureTextFieldCell(textCell: "")
        } else {
            apiKeyField.cell = NSTextFieldCell(textCell: "")
        }
        apiKeyField.stringValue = value
        apiKeyField.font = font
        apiKeyField.placeholderString = placeholder
        apiKeyField.isEditable = true
        apiKeyField.isSelectable = true
        apiKeyField.isBezeled = true
        apiKeyField.drawsBackground = true
        revealButton.image = NSImage(systemSymbolName: willHide ? "eye" : "eye.slash",
                                     accessibilityDescription: willHide ? "Show API key" : "Hide API key")
    }

    @objc private func openKeyPage() {
        guard let url = selectedProvider.keyPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            let settings = SettingsManager.shared
            saved = false
            initialLanguage = settings.language
            draftKeys.removeAll()
            draftModels.removeAll()
            displayedProvider = nil
            modelsRequestID += 1
            providerPopup.selectItem(at: TranscriptionProvider.allCases.firstIndex(of: settings.provider) ?? 0)
            apiKeyField.cell = NSSecureTextFieldCell(textCell: "")
            apiKeyField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            apiKeyField.isEditable = true
            apiKeyField.isSelectable = true
            revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show API key")
            applyProvider(settings.provider)
            hotkeyRecorder?.cancelRecording()
            hotkeyRecorder?.combo = settings.hotkeyCombo
            insertModePopup.selectItem(at: settings.insertAfterStop ? 1 : 0)
            soundsCheck.state = settings.playSounds ? .on : .off
            cleanModePopup.selectItem(at: CleaningMode.allCases.firstIndex(of: settings.cleaningMode) ?? 0)
            vocabField.stringValue = settings.customVocab
            languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: settings.language) ?? 0)
            launchAtLoginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
            updateLocalizedTexts()
        }
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        modelsRequestID += 1
        hotkeyRecorder.cancelRecording()
        if !saved, SettingsManager.shared.language != initialLanguage {
            SettingsManager.shared.language = initialLanguage
        }
        draftKeys.removeAll()
        draftModels.removeAll()
        displayedProvider = nil
        apiKeyField.stringValue = ""
    }

    @objc private func resetHotkeyToDefault() {
        hotkeyRecorder.cancelRecording()
        hotkeyRecorder.combo = KeyCombo.default
    }

    @objc private func toggleLaunchAtLogin() {
        // Applied on Save, just like the other controls.
    }

    @objc private func saveClicked() {
        let settings = SettingsManager.shared
        let provider = selectedProvider

        window?.makeFirstResponder(nil)
        captureProviderDraft()
        do {
            for (provider, draft) in draftKeys {
                if let key = draft.valueToSave { try settings.setAPIKey(key, for: provider) }
            }
            let enabled = launchAtLoginCheck.state == .on
            if enabled != (SMAppService.mainApp.status == .enabled) {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            settings.launchAtLogin = enabled
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Не удалось сохранить настройки", "Unable to save settings")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        settings.provider = provider
        for (provider, model) in draftModels { settings.setModel(model, for: provider) }
        settings.hotkeyCombo = hotkeyRecorder.combo
        if provider.supportsStreaming {
            settings.insertAfterStop = insertModePopup.indexOfSelectedItem == 1
        }
        settings.playSounds = soundsCheck.state == .on
        let cleanIdx = cleanModePopup.indexOfSelectedItem
        if cleanIdx >= 0 && cleanIdx < CleaningMode.allCases.count {
            settings.cleaningMode = CleaningMode.allCases[cleanIdx]
        }
        settings.customVocab = vocabField.stringValue.trimmingCharacters(in: .whitespaces)
        HotKeyManager.shared.registerCurrent()
        saved = true
        window?.close()
    }

    @objc private func cancelClicked() {
        if SettingsManager.shared.language != initialLanguage {
            SettingsManager.shared.language = initialLanguage
        }
        hotkeyRecorder.cancelRecording()
        hotkeyRecorder.combo = SettingsManager.shared.hotkeyCombo
        window?.close()
    }
}
