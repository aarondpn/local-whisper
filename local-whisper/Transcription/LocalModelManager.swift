import Foundation

/// Engine-dispatching facade over the two local model stores. All download/load/
/// reset entry points in the UI go through here so the WhisperKit and parakeet
/// paths stay interchangeable behind the `localModelName` selection.
enum LocalModelManager {
    static func downloadAndLoadSelectedModel(appState: AppState) async {
        let descriptor = LocalModelCatalog.selected
        switch descriptor.engine {
        case .whisperKit:
            await LocalWhisperModelStore.shared.downloadAndLoad(modelName: descriptor.id, appState: appState)
        case .parakeet:
            await ParakeetModelStore.shared.downloadAndLoad(descriptor: descriptor, appState: appState)
        }
    }

    /// Called when the selected model changes: unload whatever is resident so a
    /// ~1 GB model doesn't linger in RAM alongside the new one.
    static func resetLoadedModels() async {
        await LocalWhisperModelStore.shared.reset()
        await ParakeetEngine.shared.unload()
    }

    /// Load (never download) the selected model if its files are already on disk.
    /// Called at launch so local transcription works without a Settings visit.
    static func loadSelectedModelIfDownloaded(appState: AppState) async {
        let descriptor = LocalModelCatalog.selected
        switch descriptor.engine {
        case .whisperKit:
            // Only when the model folder already exists — WhisperKit's download
            // helper would otherwise fetch gigabytes unprompted at launch.
            let folder = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(descriptor.id)")
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            await LocalWhisperModelStore.shared.downloadAndLoad(modelName: descriptor.id, appState: appState)
        case .parakeet:
            guard ParakeetModelStore.isDownloaded(descriptor) else { return }
            await ParakeetModelStore.shared.downloadAndLoad(descriptor: descriptor, appState: appState)
        }
    }
}
