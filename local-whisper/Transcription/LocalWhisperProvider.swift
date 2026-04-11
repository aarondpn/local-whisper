import Foundation
import WhisperKit

/// Serializes access to the loaded WhisperKit pipe so concurrent hotkey presses can't race
/// the model load/reset cycle. Previously held as `static var` on the provider — that let
/// transcribe() observe a half-loaded pipe while downloadAndLoadModel() was still writing.
actor LocalWhisperModelStore {
    static let shared = LocalWhisperModelStore()

    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var isLoading = false

    func currentPipe() -> WhisperKit? { whisperKit }

    func reset() {
        whisperKit = nil
        loadedModel = nil
    }

    func downloadAndLoad(modelName: String, appState: AppState) async {
        if whisperKit != nil, loadedModel == modelName {
            await MainActor.run { appState.localModelState = .ready }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await MainActor.run { appState.localModelState = .downloading(progress: 0) }

        do {
            let modelFolder = try await WhisperKit.download(
                variant: modelName,
                progressCallback: { progress in
                    Task { @MainActor in
                        appState.localModelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            await MainActor.run { appState.localModelState = .loading }
            let pipe = try await WhisperKit(modelFolder: modelFolder.path)
            whisperKit = pipe
            loadedModel = modelName
            await MainActor.run { appState.localModelState = .ready }
        } catch {
            await MainActor.run { appState.localModelState = .error(error.localizedDescription) }
        }
    }
}

final class LocalWhisperProvider: TranscriptionProvider {
    private let appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> String {
        guard let pipe = await LocalWhisperModelStore.shared.currentPipe() else {
            throw TranscriptionError.apiError("Model not downloaded. Please download it in Settings first.")
        }
        let floats = Self.wavDataToFloatArray(audioData)

        var options = DecodingOptions()
        if let language {
            options.language = language
        }

        let results = try await pipe.transcribe(audioArray: floats, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func downloadAndLoadModel(appState: AppState) async {
        let modelName = UserDefaults.standard.string(forKey: SettingsKeys.localModelName) ?? "large-v3_turbo"
        await LocalWhisperModelStore.shared.downloadAndLoad(modelName: modelName, appState: appState)
    }

    static func resetLoadedModel() async {
        await LocalWhisperModelStore.shared.reset()
    }

    /// Convert 16-bit PCM WAV Data → [Float] for WhisperKit
    private static func wavDataToFloatArray(_ data: Data) -> [Float] {
        let pcmData = data.dropFirst(44) // skip WAV header
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
