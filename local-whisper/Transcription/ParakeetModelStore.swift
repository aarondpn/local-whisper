import Foundation
import Hub

/// Downloads GGUF weights for parakeet-engine models from Hugging Face and loads
/// them into `ParakeetEngine`. Mirrors `LocalWhisperModelStore`'s state driving:
/// `.downloading(progress:)` → `.loading` → `.ready` / `.error`.
actor ParakeetModelStore {
    static let shared = ParakeetModelStore()

    private var isLoading = false

    /// Local path the GGUF lands at — same `~/Documents/huggingface` root the
    /// WhisperKit models use, so the user has a single models directory.
    static func modelPath(for descriptor: LocalModelDescriptor) -> URL? {
        guard let repo = descriptor.hfRepo, let filename = descriptor.hfFilename else { return nil }
        return HubApi().localRepoLocation(Hub.Repo(id: repo)).appendingPathComponent(filename)
    }

    static func isDownloaded(_ descriptor: LocalModelDescriptor) -> Bool {
        guard let path = modelPath(for: descriptor) else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    func downloadAndLoad(descriptor: LocalModelDescriptor, appState: AppState) async {
        guard let repo = descriptor.hfRepo, let filename = descriptor.hfFilename else {
            await MainActor.run { appState.localModelState = .error("Model has no download source") }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if !Self.isDownloaded(descriptor) {
                await MainActor.run { appState.localModelState = .downloading(progress: 0) }
                // Isolated HubApi usage (transitive dependency via WhisperKit); if the
                // API shifts on a WhisperKit bump, swap for a URLSessionDownloadTask.
                let hub = HubApi()
                _ = try await hub.snapshot(from: Hub.Repo(id: repo), matching: filename) { progress in
                    Task { @MainActor in
                        appState.localModelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            }
            guard let path = Self.modelPath(for: descriptor) else {
                throw ParakeetError.loadFailed("could not resolve model path")
            }
            await MainActor.run { appState.localModelState = .loading }
            try await ParakeetEngine.shared.load(modelPath: path.path)
            await MainActor.run { appState.localModelState = .ready }
        } catch {
            Log.parakeet.error("Download/load failed: \(error.localizedDescription)")
            await MainActor.run { appState.localModelState = .error(error.localizedDescription) }
        }
    }
}
