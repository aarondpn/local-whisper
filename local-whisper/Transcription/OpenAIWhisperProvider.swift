import Foundation

final class OpenAIWhisperProvider: TranscriptionProvider {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: SettingsKeys.openAIAPIKey),
              !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        var formData = MultipartFormData()
        formData.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        formData.addField(name: "model", value: "whisper-1")
        formData.addField(name: "response_format", value: "text")

        if let language, language != "auto" {
            formData.addField(name: "language", value: language)
        }

        if let prompt, !prompt.isEmpty {
            formData.addField(name: "prompt", value: prompt)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = formData.finalize()
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TranscriptionError.invalidResponse
        }
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResponse
        }

        return text
    }
}
