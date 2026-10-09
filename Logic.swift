import Foundation
import Carbon

// Pure domain logic extracted for unit testability.
// Tests: Tests/Tests.swift (./tests/run.sh).

/// WhisperMe hotkey combination: virtual keyCode and modifiers mask (cmdKey, optionKey, controlKey, shiftKey).
/// Maintained in Logic.swift for headless unit testing without AppKit.
struct KeyCombo: Equatable, Hashable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default shortcut combination: Cmd + Shift + D
    static let `default` = KeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Migration helper from legacy popup indices (0..3)
    static func fromLegacyIndex(_ index: Int) -> KeyCombo {
        switch index {
        case 0: // Cmd + Shift + D
            return KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey))
        case 1: // Option + Space
            return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case 2: // Cmd + Shift + V
            return KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        case 3: // Ctrl + Space
            return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))
        default:
            return .default
        }
    }

    /// Formats modifier symbols: ⌘, ⌥, ⌃, ⇧
    static func modifierSymbols(modifiers: UInt32) -> String {
        var s = ""
        if (modifiers & UInt32(cmdKey)) != 0 { s += "⌘" }
        if (modifiers & UInt32(optionKey)) != 0 { s += "⌥" }
        if (modifiers & UInt32(controlKey)) != 0 { s += "⌃" }
        if (modifiers & UInt32(shiftKey)) != 0 { s += "⇧" }
        return s
    }

    /// Checks whether the key code is a function key (F1..F20)
    static func isFunctionKey(keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }

    /// Formats key name from its virtual key code.
    static func keyName(keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Keypad0: return "Num0"
        case kVK_ANSI_Keypad1: return "Num1"
        case kVK_ANSI_Keypad2: return "Num2"
        case kVK_ANSI_Keypad3: return "Num3"
        case kVK_ANSI_Keypad4: return "Num4"
        case kVK_ANSI_Keypad5: return "Num5"
        case kVK_ANSI_Keypad6: return "Num6"
        case kVK_ANSI_Keypad7: return "Num7"
        case kVK_ANSI_Keypad8: return "Num8"
        case kVK_ANSI_Keypad9: return "Num9"
        case kVK_ANSI_KeypadClear: return "Clear"
        case kVK_ANSI_KeypadEquals: return "Num="
        case kVK_ANSI_KeypadMultiply: return "Num*"
        case kVK_ANSI_KeypadDivide: return "Num/"
        case kVK_ANSI_KeypadPlus: return "Num+"
        case kVK_ANSI_KeypadMinus: return "Num-"
        case kVK_ANSI_KeypadDecimal: return "Num."
        case kVK_Help: return "Help"
        default:
            if let translated = translateKeyWithLayout(keyCode: keyCode) {
                return translated
            }
            if let fallback = fallbackANSIKeyName(keyCode: keyCode) {
                return fallback
            }
            return "Key(\(keyCode))"
        }
    }

    /// Translates key code through the active macOS ASCII-capable layout.
    static func translateKeyWithLayout(keyCode: UInt32) -> String? {
        guard let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(asciiSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let dataRef = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let ptr = CFDataGetBytePtr(dataRef) else { return nil }
        let layout = ptr.withMemoryRebound(to: CoreServices.UCKeyboardLayout.self, capacity: 1) { $0 }
        var deadKeys: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CoreServices.UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(CoreServices.kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit),
            &deadKeys,
            4,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).uppercased()
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fallback dictionary for standard ANSI keyboard keys.
    static func fallbackANSIKeyName(keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Grave: return "`"
        default: return nil
        }
    }

    /// User-facing formatted shortcut string: "⌘⇧D", "⌥Space", "F8"
    var displayString: String {
        Self.modifierSymbols(modifiers: modifiers) + Self.keyName(keyCode: keyCode)
    }

    /// Validates whether the shortcut is safe for global registration.
    /// Must include at least one primary modifier (Cmd, Option, Control), or be a function key (F1..F20).
    var isValid: Bool {
        if Self.isFunctionKey(keyCode: keyCode) { return true }
        let hasPrimary = (modifiers & UInt32(cmdKey | optionKey | controlKey)) != 0
        return hasPrimary
    }
}

/// In-app language preference: system (auto-detected), en, or ru.
enum AppLanguage: String, CaseIterable, Codable {
    case system = "system"
    case en = "en"
    case ru = "ru"

    func title(for isRussian: Bool) -> String {
        switch self {
        case .system:
            return isRussian ? "Системный (авто)" : "System (Auto)"
        case .en:
            return "English"
        case .ru:
            return "Русский"
        }
    }

    /// Resolves preferred language into concrete code ("ru" or "en").
    static func resolveLanguage(preference: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch preference {
        case .en: return "en"
        case .ru: return "ru"
        case .system:
            let first = preferredLanguages.first?.prefix(2).lowercased() ?? "en"
            return (first == "ru" || first == "uk" || first == "be") ? "ru" : "en"
        }
    }
}

/// Speech recognition model option in UI.
struct ModelOption: Equatable {
    let id: String
    let title: String
    let liveId: String?

    init(id: String, title: String, liveId: String? = nil) {
        self.id = id
        self.title = title
        self.liveId = liveId
    }
}

/// Speech transcription provider.
enum TranscriptionProvider: String, CaseIterable {
    case gemini
    case openrouter

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Whether real-time bidirectional streaming is supported.
    var supportsStreaming: Bool { self == .gemini }

    /// Custom vocabulary / prompt parameter support.
    var supportsVocab: Bool { self == .gemini }

    /// Dedicated UserDefaults slots per provider.
    var apiKeyDefaultsKey: String { "\(rawValue)_api_key" }
    var modelDefaultsKey: String { "\(rawValue)_model" }

    /// Fallback .env variable name.
    var apiKeyEnvName: String {
        self == .gemini ? "GEMINI_API_KEY" : "OPENROUTER_API_KEY"
    }

    /// URL for obtaining the API key.
    var keyPageURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")
        }
    }

    /// Default placeholder in API key field.
    var keyPlaceholder: String {
        switch self {
        case .gemini: return "Enter Google AI Studio key"
        case .openrouter: return "Enter OpenRouter key (sk-or-…)"
        }
    }

    /// Built-in models known to the app.
    var builtinModels: [ModelOption] {
        switch self {
        case .gemini:
            return [
                ModelOption(id: "gemini-3.5-transcribe",
                            title: "Gemini 3.5 Transcribe",
                            liveId: "gemini-3.5-transcribe-live"),
                ModelOption(id: "gemini-3.1-flash-lite",
                            title: "Gemini 3.1 Flash Lite",
                            liveId: "gemini-3.1-flash-lite-live"),
            ]
        case .openrouter:
            return []
        }
    }

    /// Default model ID for the provider.
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.5-transcribe"
        case .openrouter: return "openai/whisper-large-v3-turbo"
        }
    }

    /// Returns corresponding live streaming model ID if supported.
    func liveModel(for model: String) -> String? {
        builtinModels.first { $0.id == model }?.liveId
    }
}

/// Transcription errors with user-facing descriptions.
enum TranscriptionError: LocalizedError {
    case missingAPIKey(provider: TranscriptionProvider)
    case http(status: Int, message: String?)
    case invalidResponse
    case allModelsFailed

    func localizedDescription(isRussian: Bool) -> String {
        switch self {
        case .missingAPIKey(let provider):
            return isRussian
                ? "API ключ \(provider.title) не настроен — откройте Настройки."
                : "API key for \(provider.title) is not configured — open Settings."
        case .http(let status, let message):
            return message ?? (isRussian ? "Ошибка HTTP \(status)" : "HTTP Error \(status)")
        case .invalidResponse:
            return isRussian
                ? "Не удалось разобрать ответ сервиса."
                : "Failed to parse service response."
        case .allModelsFailed:
            return isRussian
                ? "Все модели завершились с ошибкой."
                : "All models failed."
        }
    }

    var errorDescription: String? {
        localizedDescription(isRussian: false)
    }
}

/// Pure helpers for OpenRouter STT: URLs, payloads, and response parsing.
/// Tested headlessly in tests/Tests.swift.
enum OpenRouterAPI {
    static let baseURL = "https://openrouter.ai/api/v1"
    /// Batch transcription endpoint: base64 audio → {"text": ...}.
    static let transcriptionsURL = baseURL + "/audio/transcriptions"
    /// Catalog of models supporting speech-to-text modality.
    static let modelsURL = baseURL + "/models?output_modalities=transcription"

    /// Builds the transcription request payload.
    static func transcriptionPayload(model: String, base64Audio: String) -> [String: Any] {
        [
            "model": model,
            "input_audio": ["data": base64Audio, "format": "wav"],
        ]
    }

    /// Extracts transcript text from response. Returns nil if empty or invalid.
    static func transcriptText(from json: [String: Any]) -> String? {
        guard let raw = json["text"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts error message from response: {"error": {"message": ...}}.
    static func errorMessage(from json: [String: Any]) -> String? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        if let message = error["message"] as? String, !message.isEmpty { return message }
        if let code = error["code"] as? Int { return "HTTP \(code)" }
        return nil
    }

    /// Parses STT models list from /models response.
    static func modelOptions(from json: [String: Any]) -> [ModelOption] {
        guard let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return ModelOption(id: id, title: (entry["name"] as? String) ?? id)
        }
    }
}

/// URL builder for Gemini Live WebSocket endpoint.
enum WSURL {
    static func make(apiKey: String) -> URL? {
        guard var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent") else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = items
        return components.url
    }
}

/// Computes interim text deltas for real-time progressive word insertion.
enum InterimDelta {
    struct Result {
        /// Text slice to insert, with trailing space separator.
        let delta: String
        /// Full list of words in new interim state.
        let words: [String]
        /// Range of previously inserted words that recognizer revised.
        let revisedRange: Range<Int>?
    }

    static func next(previous: [String], fullTextSoFar: String) -> Result? {
        let words = fullTextSoFar.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > previous.count else { return nil }

        let common = zip(previous, words).prefix { $0 == $1 }.count
        var revisedRange: Range<Int>? = nil
        if common < previous.count {
            revisedRange = common..<previous.count
        }

        var delta = words.suffix(words.count - previous.count).joined(separator: " ")
        delta += " "   // trailing separator: next delta pastes right after it
        return Result(delta: delta, words: words, revisedRange: revisedRange)
    }
}

/// Session transcript tracking segment-based Gemini Live model.
/// Finals commit authoritative segments, while interim provides live progressive overlay.
struct SessionTranscript {
    private(set) var committed = ""
    private(set) var segment = ""

    /// Full session transcript: committed finals + active interim segment.
    var text: String {
        if committed.isEmpty { return segment }
        if segment.isEmpty { return committed }
        let sep = committed.hasSuffix(" ") ? "" : " "
        return committed + sep + segment
    }

    mutating func onInterim(_ chunk: String) {
        segment = chunk
    }

    /// Commits authoritative segment and clears interim buffer for next segment.
    mutating func onFinal(_ chunk: String) {
        if committed.isEmpty || committed.hasSuffix(" ") || chunk.hasPrefix(" ") {
            committed += chunk
        } else {
            committed += " " + chunk
        }
        segment = ""
    }
}
