import Foundation

final class OpenAIWhisperProvider: TranscriptionProvider {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: SettingsKeys.openAIAPIKey),
              !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        return try await WhisperHTTPClient.transcribe(
            endpoint: endpoint,
            apiKey: apiKey,
            model: "whisper-1",
            audioData: audioData,
            language: language,
            prompt: prompt
        )
    }
}
