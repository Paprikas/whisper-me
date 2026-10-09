import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("WhisperMeAppLanguageDidChange")
}

/// UI localization helper
enum L10n {
    static var isRussian: Bool {
        SettingsManager.shared.isRussian
    }

    static func tr(_ ru: String, _ en: String) -> String {
        isRussian ? ru : en
    }
}

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    /// Selected app language: system (follows macOS), en, or ru.
    var language: AppLanguage {
        get {
            let raw = defaults.string(forKey: "app_language") ?? AppLanguage.system.rawValue
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            defaults.set(newValue.rawValue, forKey: "app_language")
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    /// Effective language ("ru" or "en") considering macOS system settings
    var effectiveLanguage: String {
        AppLanguage.resolveLanguage(preference: language)
    }

    var isRussian: Bool {
        effectiveLanguage == "ru"
    }

    /// Active transcription provider. Key and model are stored per provider.
    var provider: TranscriptionProvider {
        get {
            TranscriptionProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .gemini
        }
        set {
            defaults.set(newValue.rawValue, forKey: "provider")
        }
    }

    /// API key for the currently active provider.
    var apiKey: String {
        get { apiKey(for: provider) }
        set { setAPIKey(newValue, for: provider) }
    }

    /// Provider-specific API key: checked first in UserDefaults, then in .env.
    func apiKey(for provider: TranscriptionProvider) -> String {
        if let fromDefaults = defaults.string(forKey: provider.apiKeyDefaultsKey), !fromDefaults.isEmpty {
            return fromDefaults
        }
        return Self.envValue(provider.apiKeyEnvName) ?? ""
    }

    func setAPIKey(_ key: String, for provider: TranscriptionProvider) {
        defaults.set(key, forKey: provider.apiKeyDefaultsKey)
    }

    /// Reads a variable from a .env file. Looks in the project root (next to Sources
    /// or the repo root) regardless of the current working directory, so launching
    /// from Finder also works.
    private static func envValue(_ name: String) -> String? {
        var candidates: [URL] = []

        // Repo root: walk up from the executable / bundle location
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent(".env"))
            dir = dir.deletingLastPathComponent()
        }

        // Bundle location (build/WhisperMe.app/Contents/MacOS → up to repo root)
        var bundleDir = Bundle.main.bundleURL
        for _ in 0..<5 {
            bundleDir = bundleDir.deletingLastPathComponent()
            candidates.append(bundleDir.appendingPathComponent(".env"))
        }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                for line in content.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return nil
    }

    /// Recognition model for the active provider.
    var model: String {
        get { model(for: provider) }
        set { setModel(newValue, for: provider) }
    }

    /// Model for a specific provider; defaults to provider.defaultModel.
    func model(for provider: TranscriptionProvider) -> String {
        defaults.string(forKey: provider.modelDefaultsKey) ?? provider.defaultModel
    }

    func setModel(_ model: String, for provider: TranscriptionProvider) {
        defaults.set(model, forKey: provider.modelDefaultsKey)
    }

    /// Active shortcut combination. nil means global hotkey is disabled.
    var hotkeyCombo: KeyCombo? {
        get {
            if defaults.bool(forKey: "hotkey_disabled") {
                return nil
            }
            if defaults.object(forKey: "hotkey_key_code") != nil {
                let code = UInt32(defaults.integer(forKey: "hotkey_key_code"))
                let mods = UInt32(defaults.integer(forKey: "hotkey_modifiers"))
                return KeyCombo(keyCode: code, modifiers: mods)
            }
            if defaults.object(forKey: "hotkey_index") != nil {
                return KeyCombo.fromLegacyIndex(defaults.integer(forKey: "hotkey_index"))
            }
            return KeyCombo.default
        }
        set {
            if let combo = newValue {
                defaults.set(false, forKey: "hotkey_disabled")
                defaults.set(Int(combo.keyCode), forKey: "hotkey_key_code")
                defaults.set(Int(combo.modifiers), forKey: "hotkey_modifiers")
            } else {
                defaults.set(true, forKey: "hotkey_disabled")
                defaults.removeObject(forKey: "hotkey_key_code")
                defaults.removeObject(forKey: "hotkey_modifiers")
            }
        }
    }

    /// Backward compatibility for legacy popup indices (0..3)
    var hotkeyIndex: Int {
        get {
            defaults.integer(forKey: "hotkey_index")
        }
        set {
            defaults.set(newValue, forKey: "hotkey_index")
            hotkeyCombo = KeyCombo.fromLegacyIndex(newValue)
        }
    }

    var playSounds: Bool {
        get {
            if defaults.object(forKey: "play_sounds") == nil { return true }
            return defaults.bool(forKey: "play_sounds")
        }
        set {
            defaults.set(newValue, forKey: "play_sounds")
        }
    }

    /// Automatically filters hesitations and filler sounds ("ээ", "мм", "а-а", "uh", "um").
    var cleanFillerWords: Bool {
        get {
            if defaults.object(forKey: "clean_filler_words") == nil { return true }
            return defaults.bool(forKey: "clean_filler_words")
        }
        set {
            defaults.set(newValue, forKey: "clean_filler_words")
        }
    }

    /// Text insertion strategy:
    /// false = Real-time streaming (words stream as you speak),
    /// true  = After recording stops (entire text injected once).
    var insertAfterStop: Bool {
        get {
            defaults.bool(forKey: "insert_after_stop")
        }
        set {
            defaults.set(newValue, forKey: "insert_after_stop")
        }
    }

    /// Custom vocabulary / proper names prompt (Gemini batch).
    var customVocab: String {
        get { defaults.string(forKey: "custom_vocab") ?? "" }
        set { defaults.set(newValue, forKey: "custom_vocab") }
    }

    /// Launch at login (SMAppService).
    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: "launch_at_login") == nil { return false }
            return defaults.bool(forKey: "launch_at_login")
        }
        set {
            defaults.set(newValue, forKey: "launch_at_login")
        }
    }

    /// History of transcribed utterances.
    var history: [String] {
        get { defaults.stringArray(forKey: "history") ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: "history") }
    }
}
