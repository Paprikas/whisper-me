import Foundation
import Carbon

// WhisperMe pure domain logic tests (Logic.swift).
// Run with: ./tests/run.sh

var failures: [String] = []
var passed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
    } else {
        failures.append(name)
        print("❌ FAIL: \(name)")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want {
        passed += 1
    } else {
        failures.append(name)
        print("❌ FAIL: \(name)\n   got:  \(got)\n   want: \(want)")
    }
}

func parseEnvLine(_ line: String) -> (String, String)? {
    let parts = line.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return (parts[0].trimmingCharacters(in: .whitespaces),
            parts[1].trimmingCharacters(in: .whitespaces))
}

@main
struct TestRunner {
    static func main() {
        testWSURL()
        testInterimDelta()
        testSessionTranscript()
        testEnvParsing()
        testProviders()
        testOpenRouterPayload()
        testOpenRouterResponses()
        testTranscriptionErrors()
        testHotKeyCombo()
        testAppLanguage()

        print("\n\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("Failed: \(failures.joined(separator: ", "))")
            exit(1)
        }
        print("✅ All tests passed")
    }

    // MARK: - WSURL

    static func testWSURL() {
        let plainURL = WSURL.make(apiKey: "AIzaTest123")
        check("WSURL: builds valid URL with key", plainURL != nil)
        if let url = plainURL {
            check("WSURL: wss scheme", url.scheme == "wss")
            check("WSURL: Live API host", url.host == "generativelanguage.googleapis.com")
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            checkEqual("WSURL: exactly one key parameter",
                       comps?.queryItems?.filter { $0.name == "key" }.count ?? 0, 1)
            checkEqual("WSURL: key value matches input",
                       comps?.queryItems?.first { $0.name == "key" }?.value, "AIzaTest123")
        }

        let weirdKey = "abc def+ghi/jkl=?&"
        if let weirdURL = WSURL.make(apiKey: weirdKey) {
            let comps = URLComponents(url: weirdURL, resolvingAgainstBaseURL: false)
            checkEqual("WSURL: special characters properly escaped and decoded",
                       comps?.queryItems?.first { $0.name == "key" }?.value, weirdKey)
            check("WSURL: no raw space in URL", !weirdURL.absoluteString.contains(" "))
        } else {
            check("WSURL: special characters properly escaped and decoded", false)
        }

        check("WSURL: empty key does not crash URL creation", WSURL.make(apiKey: "") != nil)
    }

    // MARK: - InterimDelta

    static func testInterimDelta() {
        var injected: [String] = []
        if let r1 = InterimDelta.next(previous: injected, fullTextSoFar: "hello") {
            checkEqual("Interim: first word delta", r1.delta, "hello ")
            injected = r1.words
        } else { check("Interim: first word delta", false) }

        if let r2 = InterimDelta.next(previous: injected, fullTextSoFar: "hello how are") {
            checkEqual("Interim: appending words delta", r2.delta, "how are ")
            check("Interim: no revision during normal append", r2.revisedRange == nil)
            injected = r2.words
        } else { check("Interim: appending words delta", false) }

        check("Interim: shrinking phrase yields nil delta",
              InterimDelta.next(previous: injected, fullTextSoFar: "hello how") == nil)
        check("Interim: identical text yields nil delta",
              InterimDelta.next(previous: injected, fullTextSoFar: "hello how are") == nil)

        if let r3 = InterimDelta.next(previous: injected, fullTextSoFar: "greetings how are today") {
            checkEqual("Interim: revision does not duplicate previously injected words", r3.delta, "today ")
            checkEqual("Interim: revised range", r3.revisedRange, 0..<3)
        } else {
            check("Interim: revision does not duplicate previously injected words", false)
        }

        check("Interim: empty string yields nil delta",
              InterimDelta.next(previous: [], fullTextSoFar: "") == nil)

        if let r = InterimDelta.next(previous: [], fullTextSoFar: "  two   words  ") {
            checkEqual("Interim: collapses multiple spaces", r.delta, "two words ")
        } else {
            check("Interim: collapses multiple spaces", false)
        }
    }

    // MARK: - SessionTranscript

    static func testSessionTranscript() {
        var t = SessionTranscript()
        t.onInterim("hello how are")
        checkEqual("Transcript: interim before final", t.text, "hello how are")
        t.onFinal("Hello, how are you?")
        checkEqual("Transcript: final replaces current segment",
                   t.text, "Hello, how are you?")
        t.onInterim("today")
        checkEqual("Transcript: new interim overlays next segment",
                   t.text, "Hello, how are you? today")
        t.onFinal("Today.")
        checkEqual("Transcript: second final committed on top",
                   t.text, "Hello, how are you? Today.")

        var d = SessionTranscript()
        let seg = "Here is the first sentence. And now we check the second one."
        d.onInterim("Here is the first sentence. And now we check the second one")
        d.onFinal(seg)
        checkEqual("Transcript: final revision does not duplicate segment", d.text, seg)
        checkEqual("Transcript: segment appears exactly once",
                   d.text.components(separatedBy: seg).count - 1, 1)

        var long = SessionTranscript()
        let segs = ["First sentence here,", "second sentence follows,",
                    "third part continues.", "Fourth segment here.",
                    "Fifth and final segment."]
        for s in segs {
            long.onInterim(String(s.dropLast(1)))
            long.onFinal(s)
        }
        checkEqual("Transcript: long multi-segment session",
                   long.text, segs.joined(separator: " "))

        var e = SessionTranscript()
        checkEqual("Transcript: empty session", e.text, "")
        e.onFinal("one")
        checkEqual("Transcript: final without interim", e.text, "one")
        var e2 = SessionTranscript()
        e2.onInterim("one")
        checkEqual("Transcript: interim without final", e2.text, "one")
        var e3 = SessionTranscript()
        e3.onFinal("one ")
        e3.onInterim("two")
        checkEqual("Transcript: trailing space in final does not duplicate spaces",
                   e3.text, "one  two".replacingOccurrences(of: "  ", with: " "))
    }

    // MARK: - Environment parsing

    static func testEnvParsing() {
        checkEqual("env: standard line", parseEnvLine("GEMINI_API_KEY = abc123")?.1, "abc123")
        checkEqual("env: value containing equal sign", parseEnvLine("KEY=a=b=c")?.1, "a=b=c")
        check("env: line without equal sign ignored", parseEnvLine("just a comment") == nil)
        checkEqual("env: trims whitespace around key", parseEnvLine("  KEY  = v")?.0, "KEY")
    }

    // MARK: - Providers

    static func testProviders() {
        let gemini = TranscriptionProvider.gemini
        let openrouter = TranscriptionProvider.openrouter
        check("Provider: isolated defaults key for API keys",
              gemini.apiKeyDefaultsKey != openrouter.apiKeyDefaultsKey)
        check("Provider: isolated defaults key for models",
              gemini.modelDefaultsKey != openrouter.modelDefaultsKey)
        checkEqual("Provider: Gemini env variable name", gemini.apiKeyEnvName, "GEMINI_API_KEY")
        checkEqual("Provider: OpenRouter env variable name", openrouter.apiKeyEnvName, "OPENROUTER_API_KEY")
        checkEqual("Provider: rawValue roundtrip",
                   TranscriptionProvider(rawValue: "openrouter"), .openrouter)

        for provider in TranscriptionProvider.allCases {
            check("Provider \(provider.title): default model is non-empty",
                  !provider.defaultModel.isEmpty)
            check("Provider \(provider.title): key page URL is valid", provider.keyPageURL != nil)
            check("Provider \(provider.title): placeholder is non-empty",
                  !provider.keyPlaceholder.isEmpty)
        }

        check("Provider: Gemini supports streaming", gemini.supportsStreaming)
        check("Provider: OpenRouter does not support streaming", !openrouter.supportsStreaming)
        checkEqual("Provider: OpenRouter has no live model",
                   openrouter.liveModel(for: openrouter.defaultModel), nil)
        check("Provider: OpenRouter lacks vocabulary prompt support", !openrouter.supportsVocab)
        check("Provider: Gemini supports vocabulary prompt", gemini.supportsVocab)

        for option in gemini.builtinModels {
            checkEqual("Provider: live model for \(option.id)",
                       gemini.liveModel(for: option.id), option.liveId)
        }
        checkEqual("Provider: unknown model yields nil live model",
                   gemini.liveModel(for: "some-other-model"), nil)
        checkEqual("Provider: default Gemini model is in catalog",
                   gemini.builtinModels.first?.id, gemini.defaultModel)
    }

    // MARK: - OpenRouter: Payload

    static func testOpenRouterPayload() {
        checkEqual("OpenRouter: transcriptions URL",
                   OpenRouterAPI.transcriptionsURL,
                   "https://openrouter.ai/api/v1/audio/transcriptions")
        check("OpenRouter: models URL specifies transcription modality",
              OpenRouterAPI.modelsURL.contains("output_modalities=transcription"))
        check("OpenRouter: endpoints build valid URLs",
              URL(string: OpenRouterAPI.transcriptionsURL) != nil
              && URL(string: OpenRouterAPI.modelsURL) != nil)

        let payload = OpenRouterAPI.transcriptionPayload(model: "openai/whisper-1",
                                                         base64Audio: "QUJD")
        checkEqual("OpenRouter: model at top level",
                   payload["model"] as? String, "openai/whisper-1")
        guard let audio = payload["input_audio"] as? [String: Any] else {
            check("OpenRouter: input_audio present in payload", false)
            return
        }
        checkEqual("OpenRouter: base64 audio data", audio["data"] as? String, "QUJD")
        checkEqual("OpenRouter: audio format is wav", audio["format"] as? String, "wav")
        check("OpenRouter: no prompt in payload",
              payload["prompt"] == nil && audio["prompt"] == nil)

        check("OpenRouter: valid JSON serialization",
              JSONSerialization.isValidJSONObject(payload))
    }

    // MARK: - OpenRouter: Responses

    static func testOpenRouterResponses() {
        checkEqual("OpenRouter: transcript text extracted",
                   OpenRouterAPI.transcriptText(from: ["text": "  hello  "]), "hello")

        check("OpenRouter: empty text returns nil", OpenRouterAPI.transcriptText(from: ["text": ""]) == nil)
        check("OpenRouter: whitespace text returns nil",
              OpenRouterAPI.transcriptText(from: ["text": "   \n "]) == nil)
        check("OpenRouter: response missing text key returns nil",
              OpenRouterAPI.transcriptText(from: ["usage": ["total_tokens": 3]]) == nil)

        checkEqual("OpenRouter: error message extracted",
                   OpenRouterAPI.errorMessage(from: ["error": ["message": "No credits"]]),
                   "No credits")
        checkEqual("OpenRouter: error code fallback",
                   OpenRouterAPI.errorMessage(from: ["error": ["code": 402]]), "HTTP 402")
        check("OpenRouter: successful response yields nil error message",
              OpenRouterAPI.errorMessage(from: ["text": "hello"]) == nil)
        check("OpenRouter: non-dictionary error yields nil",
              OpenRouterAPI.errorMessage(from: ["error": "boom"]) == nil)

        let models = OpenRouterAPI.modelOptions(from: [
            "data": [
                ["id": "openai/whisper-1", "name": "OpenAI: Whisper"],
                ["id": "google/gemini-3.5-transcribe", "name": "Google: Gemini 3.5 Transcribe"],
            ]
        ])
        checkEqual("OpenRouter: models parsed", models.count, 2)
        checkEqual("OpenRouter: title derived from name", models.first?.title, "OpenAI: Whisper")

        let partial = OpenRouterAPI.modelOptions(from: [
            "data": [["id": "deepgram/nova-3"], ["name": "no id"], ["id": ""]]
        ])
        checkEqual("OpenRouter: id fallback when name is absent", partial.first?.title, "deepgram/nova-3")
        checkEqual("OpenRouter: entries without valid id discarded", partial.count, 1)
        check("OpenRouter: catalog model has nil live ID",
              partial.first?.liveId == nil)
        check("OpenRouter: unexpected catalog format yields empty list",
              OpenRouterAPI.modelOptions(from: ["error": ["message": "nope"]]).isEmpty)
    }

    // MARK: - Transcription errors

    static func testTranscriptionErrors() {
        let all: [TranscriptionError] = [
            .missingAPIKey(provider: .gemini),
            .missingAPIKey(provider: .openrouter),
            .http(status: 500, message: "boom"),
            .http(status: 401, message: nil),
            .invalidResponse,
            .allModelsFailed,
        ]
        for error in all {
            let text = error.errorDescription ?? ""
            check("Error \(error) has non-empty description", !text.isEmpty)
        }
        check("Error: names provider when key is missing",
              TranscriptionError.missingAPIKey(provider: .openrouter)
                .errorDescription?.contains("OpenRouter") == true)
        check("Error: HTTP code included in description",
              TranscriptionError.http(status: 401, message: nil)
                .errorDescription?.contains("401") == true)
    }

    // MARK: - KeyCombo

    static func testHotKeyCombo() {
        checkEqual("KeyCombo: default keyCode", KeyCombo.default.keyCode, UInt32(kVK_ANSI_D))
        checkEqual("KeyCombo: default modifiers", KeyCombo.default.modifiers, UInt32(cmdKey | shiftKey))
        checkEqual("KeyCombo: default displayString", KeyCombo.default.displayString, "⌘⇧D")
        check("KeyCombo: default is valid", KeyCombo.default.isValid)

        checkEqual("KeyCombo: legacy index 0 (Cmd+Shift+D)", KeyCombo.fromLegacyIndex(0), KeyCombo.default)
        checkEqual("KeyCombo: legacy index 1 (Option+Space)", KeyCombo.fromLegacyIndex(1).displayString, "⌥Space")
        checkEqual("KeyCombo: legacy index 2 (Cmd+Shift+V)", KeyCombo.fromLegacyIndex(2).displayString, "⌘⇧V")
        checkEqual("KeyCombo: legacy index 3 (Ctrl+Space)", KeyCombo.fromLegacyIndex(3).displayString, "⌃Space")
        checkEqual("KeyCombo: legacy out of bounds fallback", KeyCombo.fromLegacyIndex(99), KeyCombo.default)

        checkEqual("KeyCombo: modifier symbol ⌘", KeyCombo.modifierSymbols(modifiers: UInt32(cmdKey)), "⌘")
        checkEqual("KeyCombo: modifier symbol ⌥", KeyCombo.modifierSymbols(modifiers: UInt32(optionKey)), "⌥")
        checkEqual("KeyCombo: modifier symbol ⌃", KeyCombo.modifierSymbols(modifiers: UInt32(controlKey)), "⌃")
        checkEqual("KeyCombo: modifier symbol ⇧", KeyCombo.modifierSymbols(modifiers: UInt32(shiftKey)), "⇧")
        checkEqual("KeyCombo: modifier symbols ⌘⌥⌃⇧", KeyCombo.modifierSymbols(modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)), "⌘⌥⌃⇧")

        checkEqual("KeyCombo: keyName Space", KeyCombo.keyName(keyCode: UInt32(kVK_Space)), "Space")
        checkEqual("KeyCombo: keyName Return", KeyCombo.keyName(keyCode: UInt32(kVK_Return)), "↩")
        checkEqual("KeyCombo: keyName Tab", KeyCombo.keyName(keyCode: UInt32(kVK_Tab)), "⇥")
        checkEqual("KeyCombo: keyName Delete", KeyCombo.keyName(keyCode: UInt32(kVK_Delete)), "⌫")
        checkEqual("KeyCombo: keyName Escape", KeyCombo.keyName(keyCode: UInt32(kVK_Escape)), "⎋")
        checkEqual("KeyCombo: keyName F1", KeyCombo.keyName(keyCode: UInt32(kVK_F1)), "F1")
        checkEqual("KeyCombo: keyName F8", KeyCombo.keyName(keyCode: UInt32(kVK_F8)), "F8")
        checkEqual("KeyCombo: keyName D", KeyCombo.keyName(keyCode: UInt32(kVK_ANSI_D)), "D")
        checkEqual("KeyCombo: keyName V", KeyCombo.keyName(keyCode: UInt32(kVK_ANSI_V)), "V")

        check("KeyCombo: Cmd+Shift+D is valid", KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey)).isValid)
        check("KeyCombo: Option+Space is valid", KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).isValid)
        check("KeyCombo: Ctrl+Space is valid", KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)).isValid)
        check("KeyCombo: F8 without modifiers is valid", KeyCombo(keyCode: UInt32(kVK_F8), modifiers: 0).isValid)
        check("KeyCombo: Option+Escape is valid", KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey)).isValid)

        check("KeyCombo: bare key D is invalid", !KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: 0).isValid)
        check("KeyCombo: bare Space is invalid", !KeyCombo(keyCode: UInt32(kVK_Space), modifiers: 0).isValid)
        check("KeyCombo: bare Shift+D is invalid", !KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(shiftKey)).isValid)
        check("KeyCombo: bare Escape is invalid", !KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0).isValid)
    }

    // MARK: - AppLanguage & Localization

    static func testAppLanguage() {
        checkEqual("AppLanguage: explicit en", AppLanguage.resolveLanguage(preference: .en), "en")
        checkEqual("AppLanguage: explicit ru", AppLanguage.resolveLanguage(preference: .ru), "ru")

        checkEqual("AppLanguage: system with ru-RU", AppLanguage.resolveLanguage(preference: .system, preferredLanguages: ["ru-RU", "en-US"]), "ru")
        checkEqual("AppLanguage: system with en-US", AppLanguage.resolveLanguage(preference: .system, preferredLanguages: ["en-US", "ru-RU"]), "en")
        checkEqual("AppLanguage: system fallback on other lang", AppLanguage.resolveLanguage(preference: .system, preferredLanguages: ["fr-FR"]), "en")

        checkEqual("AppLanguage: title en", AppLanguage.en.title(for: true), "English")
        checkEqual("AppLanguage: title ru", AppLanguage.ru.title(for: false), "Русский")
        checkEqual("AppLanguage: title system (ru)", AppLanguage.system.title(for: true), "Системный (авто)")
        checkEqual("AppLanguage: title system (en)", AppLanguage.system.title(for: false), "System (Auto)")

        let err = TranscriptionError.missingAPIKey(provider: .gemini)
        check("Error: ru text contains key reference", err.localizedDescription(isRussian: true).contains("API ключ"))
        check("Error: en text contains key reference", err.localizedDescription(isRussian: false).contains("API key"))
    }
}
