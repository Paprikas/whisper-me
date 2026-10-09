import Foundation

/// Batch transcription via OpenRouter STT
/// (`POST /api/v1/audio/transcriptions`).
///
/// Unlike Gemini, OpenRouter does not provide a bidirectional streaming API,
/// so transcription runs as a single batch request after recording stops.
///
///   request:  {"model": "...", "input_audio": {"data": <base64 wav>, "format": "wav"}}
///   response: {"text": "...", "usage": {...}}
///   error:    {"error": {"message": "..."}}
final class OpenRouterTranscriber {
    private let session = URLSession(configuration: .default)

    /// Batch audio is sent as a whole, so timeout is generous for longer recordings.
    private static let requestTimeout: TimeInterval = 60.0
    private static let modelsTimeout: TimeInterval = 10.0

    func transcribe(apiKey: String, model: String, audioData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(TranscriptionError.missingAPIKey(provider: .openrouter)))
            return
        }
        guard let url = URL(string: OpenRouterAPI.transcriptionsURL) else {
            completion(.failure(TranscriptionError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeout

        let payload = OpenRouterAPI.transcriptionPayload(model: model,
                                                          base64Audio: audioData.base64EncodedString())
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.invalidResponse))
                return
            }
            if let message = OpenRouterAPI.errorMessage(from: json) {
                completion(.failure(TranscriptionError.http(status: status, message: message)))
                return
            }
            guard (200..<300).contains(status) else {
                completion(.failure(TranscriptionError.http(status: status, message: nil)))
                return
            }
            // Empty text ({"text": ""}) is normal when no speech was detected.
            completion(.success(OpenRouterAPI.transcriptText(from: json) ?? ""))
        }.resume()
    }

    /// Fetches available STT models dynamically from OpenRouter API.
    static func fetchModels(apiKey: String = "", completion: @escaping (Result<[ModelOption], Error>) -> Void) {
        guard let url = URL(string: OpenRouterAPI.modelsURL) else {
            completion(.failure(TranscriptionError.invalidResponse))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = modelsTimeout

        URLSession(configuration: .default).dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.invalidResponse))
                return
            }
            if let message = OpenRouterAPI.errorMessage(from: json) {
                completion(.failure(TranscriptionError.http(status: status, message: message)))
                return
            }
            guard (200..<300).contains(status) else {
                completion(.failure(TranscriptionError.http(status: status, message: nil)))
                return
            }
            let models = OpenRouterAPI.modelOptions(from: json)
            guard !models.isEmpty else {
                completion(.failure(TranscriptionError.invalidResponse))
                return
            }
            completion(.success(models))
        }.resume()
    }
}
