import Foundation

enum ProviderType: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case groq = "groq"
    case local = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI Whisper"
        case .groq: return "Groq Whisper"
        case .local: return "Local (WhisperKit)"
        }
    }
}

protocol TranscriptionProvider {
    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String
}

enum TranscriptionError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case emptyResponse
    case apiError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API key not configured"
        case .invalidResponse: return "Invalid response from server"
        case .emptyResponse: return "No transcription returned"
        case .apiError(let message): return "API error: \(message)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}
