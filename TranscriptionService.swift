import Foundation

/// Unified entry point for batch transcription: reads provider, API key, and
/// model from settings and delegates to the appropriate implementation.
/// The caller (AppDelegate) remains decoupled from the specific provider.
final class TranscriptionService {
    static let shared = TranscriptionService()

    private let gemini = GeminiTranscriber()
    private let openRouter = OpenRouterTranscriber()

    func transcribe(audioData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        let settings = SettingsManager.shared
        let provider = settings.provider
        let apiKey = settings.apiKey
        let model = settings.model

        guard !apiKey.isEmpty else {
            completion(.failure(TranscriptionError.missingAPIKey(provider: provider)))
            return
        }

        let cleaningMode = settings.cleaningMode
        let wrappedCompletion: (Result<String, Error>) -> Void = { result in
            switch result {
            case .success(let text):
                // If manual mode is selected, run local TextCleaner regex.
                // In smart mode, cleaning was done natively by the model/API.
                // In disabled mode, text is untouched.
                let cleaned = TextCleaner.prepare(text, enabled: cleaningMode.usesManualCleaner)
                completion(.success(cleaned))
            case .failure(let error):
                completion(.failure(error))
            }
        }

        switch provider {
        case .gemini:
            gemini.transcribe(apiKey: apiKey, model: model, audioData: audioData, completion: wrappedCompletion)
        case .openrouter:
            openRouter.transcribe(apiKey: apiKey, model: model, audioData: audioData, completion: wrappedCompletion)
        }
    }
}
