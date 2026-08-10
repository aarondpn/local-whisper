import Foundation

/// One-shot transcription through the parakeet.cpp engine (used when live
/// transcription is disabled or the streaming session failed mid-utterance).
/// `prompt` is ignored, matching `LocalWhisperProvider`.
final class ParakeetProvider: TranscriptionProvider {
    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String {
        guard await ParakeetEngine.shared.isLoaded else {
            throw TranscriptionError.apiError("Model not downloaded. Please download it in Settings first.")
        }
        let floats = Self.wavDataToFloatArray(audioData)
        do {
            let text = try await ParakeetEngine.shared.transcribe(samples: floats, language: language)
            guard !text.isEmpty else { throw TranscriptionError.emptyResponse }
            return text
        } catch let error as ParakeetError {
            throw TranscriptionError.apiError(error.localizedDescription)
        }
    }

    /// Convert 16-bit PCM WAV Data → [Float] (16 kHz mono, the app's own format).
    static func wavDataToFloatArray(_ data: Data) -> [Float] {
        let pcmData = data.dropFirst(44)
        let sampleCount = pcmData.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floats[i] = Float(int16s[i]) / Float(Int16.max)
            }
        }
        return floats
    }
}
