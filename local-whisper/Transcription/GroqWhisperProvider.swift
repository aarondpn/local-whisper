import Foundation

final class GroqWhisperProvider: TranscriptionProvider {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: SettingsKeys.groqAPIKey),
              !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        return try await WhisperHTTPClient.transcribe(
            endpoint: endpoint,
            apiKey: apiKey,
            model: "whisper-large-v3-turbo",
            audioData: audioData,
            language: language,
            prompt: prompt
        )
    }
}
