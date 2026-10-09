import Foundation

/// Batch transcription via Gemini. Models containing `transcribe` use
/// the Interactions API; flash models use generateContent with custom vocabulary support.
final class GeminiTranscriber {
    private let fallbackModels = ["gemini-3.1-flash-lite"]

    func transcribe(apiKey: String, model: String, audioData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(TranscriptionError.missingAPIKey(provider: .gemini)))
            return
        }

        let base64Audio = audioData.base64EncodedString()

        if model.contains("transcribe") {
            // Use Interactions API for transcribe models
            callInteractionsAPI(model: model, base64Audio: base64Audio, apiKey: apiKey) { result in
                switch result {
                case .success(let text):
                    if !text.isEmpty {
                        completion(.success(text))
                    } else {
                        // Fallback to generateContent models
                        AppLog.log("⚠️ Model \(model) returned empty transcription. Trying fallback...")
                        self.tryGenerateContentChain(models: self.fallbackModels, base64Audio: base64Audio, apiKey: apiKey, completion: completion)
                    }
                case .failure(let error):
                    AppLog.log("⚠️ Interactions API error (\(model)): \(error.localizedDescription). Switching to fallback...")
                    self.tryGenerateContentChain(models: self.fallbackModels, base64Audio: base64Audio, apiKey: apiKey, completion: completion)
                }
            }
        } else {
            // Use generateContent for flash models
            tryGenerateContentChain(models: [model] + fallbackModels, base64Audio: base64Audio, apiKey: apiKey, completion: completion)
        }
    }

    // MARK: - Interactions API (for gemini-3.5-transcribe)
    // Endpoint: POST /v1beta/interactions
    // Response format: { "steps": [{ "content": [{ "text": "...", "type": "text" }], "type": "model_output" }] }

    private func callInteractionsAPI(model: String, base64Audio: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            completion(.failure(NSError(domain: "WhisperMe", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 25.0

        let payload: [String: Any] = [
            "model": model,
            "input": [
                [
                    "type": "audio",
                    "data": base64Audio,
                    "mime_type": "audio/wav"
                ]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession(configuration: .default).dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "WhisperMe", code: 500, userInfo: [NSLocalizedDescriptionKey: "Empty response"])))
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                        completion(.failure(NSError(domain: "WhisperMe", code: 500, userInfo: [NSLocalizedDescriptionKey: msg])))
                        return
                    }
                    // Parse steps[].content[].text
                    if let steps = json["steps"] as? [[String: Any]] {
                        for step in steps {
                            if let contentArr = step["content"] as? [[String: Any]] {
                                for item in contentArr {
                                    if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
                completion(.success(""))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - GenerateContent API (for flash models)

    private func tryGenerateContentChain(models: [String], base64Audio: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let currentModel = models.first else {
            completion(.failure(TranscriptionError.allModelsFailed))
            return
        }
        let remaining = Array(models.dropFirst().filter { $0 != currentModel })

        callGenerateContent(model: currentModel, base64Audio: base64Audio, apiKey: apiKey) { result in
            switch result {
            case .success(let text):
                if !text.isEmpty {
                    completion(.success(text))
                } else if !remaining.isEmpty {
                    AppLog.log("⚠️ \(currentModel): empty response. Trying \(remaining.first!)...")
                    self.tryGenerateContentChain(models: remaining, base64Audio: base64Audio, apiKey: apiKey, completion: completion)
                } else {
                    completion(.success(""))
                }
            case .failure(let error):
                if !remaining.isEmpty {
                    AppLog.log("⚠️ \(currentModel): \(error.localizedDescription). Trying \(remaining.first!)...")
                    self.tryGenerateContentChain(models: remaining, base64Audio: base64Audio, apiKey: apiKey, completion: completion)
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func callGenerateContent(model: String, base64Audio: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            completion(.failure(NSError(domain: "WhisperMe", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25.0

        let vocab = SettingsManager.shared.customVocab
        let clean = SettingsManager.shared.cleanFillerWords
        let baseInstruction = clean
            ? "Transcribe the audio accurately into clean text. Omit non-lexical hesitation sounds (such as 'ээ', 'мм', 'а-а', 'um', 'uh'). Preserve the meaning, ordinary words, names, numbers, and deliberately quoted sounds. Do not summarize or paraphrase. "
            : "Transcribe the audio verbatim. "
        let prompt: String
        if vocab.isEmpty {
            prompt = "\(baseInstruction)Output only the text without quotes."
        } else {
            prompt = "\(baseInstruction)Specific terms/names: \(vocab). Output only the text without quotes."
        }

        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": "audio/wav", "data": base64Audio]]
                ]
            ]],
            "generationConfig": ["temperature": 0.0]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession(configuration: .default).dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "WhisperMe", code: 500, userInfo: [NSLocalizedDescriptionKey: "Empty response"])))
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                        completion(.failure(NSError(domain: "WhisperMe", code: 500, userInfo: [NSLocalizedDescriptionKey: msg])))
                        return
                    }
                    if let candidates = json["candidates"] as? [[String: Any]],
                       let content = candidates.first?["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                                return
                            }
                        }
                    }
                }
                completion(.success(""))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
