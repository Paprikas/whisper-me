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

        switch provider {
        case .gemini:
            gemini.transcribe(apiKey: apiKey, model: model, audioData: audioData, completion: completion)
        case .openrouter:
            openRouter.transcribe(apiKey: apiKey, model: model, audioData: audioData, completion: completion)
        }
    }
}
