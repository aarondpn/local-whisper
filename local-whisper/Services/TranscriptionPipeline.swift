import Foundation

/// Runs a captured audio clip through the selected provider, updates statistics, and
/// inserts the transcribed text into the focused field. Invoked by `RecordingSession`
/// once a recording has cleared the minimum-duration filter.
@MainActor
final class TranscriptionPipeline {
    private let appState: AppState
    private let overlayPanel: RecordingOverlayPanel
    private let textInsertionService = TextInsertionService()
    private var currentTask: Task<Void, Never>?

    init(appState: AppState, overlayPanel: RecordingOverlayPanel) {
        self.appState = appState
        self.overlayPanel = overlayPanel
        self.appState.cancelCurrentTranscription = { [weak self] in
            self?.currentTask?.cancel()
        }
    }

    func run(audioData: Data, frontmostBundleID: String?, capturedContext: String?) async {
        currentTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.execute(
                audioData: audioData,
                frontmostBundleID: frontmostBundleID,
                capturedContext: capturedContext
            )
        }
        currentTask = task
        await task.value
        currentTask = nil
    }

    private func execute(audioData: Data, frontmostBundleID: String?, capturedContext: String?) async {
        defer {
            Task { @MainActor in
                self.appState.isTranscribing = false
                self.overlayPanel.hideOverlay()
            }
        }

        let resolved = appState.profileManager.resolveSettings(
            for: frontmostBundleID,
            globalProvider: appState.selectedProvider,
            globalLanguage: appState.language
        )
        let provider = makeProvider(for: resolved.provider)
        let language = resolved.language
        let finalPrompt = ContextProvider.combine(
            basePrompt: resolved.prompt,
            dynamicContext: capturedContext
        )

        Log.coordinator.info("Profile prompt: \(resolved.prompt ?? "(none)")")
        Log.coordinator.info("Dynamic context (\(capturedContext?.utf8.count ?? 0) bytes): \(capturedContext ?? "(none)")")
        Log.coordinator.info("Final prompt (\(finalPrompt?.count ?? 0) chars, \(finalPrompt?.utf8.count ?? 0) bytes): \(finalPrompt ?? "(none)")")

        appState.lastPrompt = finalPrompt

        do {
            let startTime = Date()
            let text = try await provider.transcribe(audioData: audioData, language: language == "auto" ? nil : language, prompt: finalPrompt)
            try Task.checkCancellation()
            let latency = Date().timeIntervalSince(startTime)

            guard !text.isEmpty else {
                Log.coordinator.info("Transcription returned empty text")
                return
            }

            Log.coordinator.info("Transcribed: \(text)")

            // Record statistics
            let audioBytes = max(0, audioData.count - 44)
            let audioDuration = Double(audioBytes) / 32000.0
            let event = TranscriptionEvent(
                provider: resolved.provider.rawValue,
                audioDurationSeconds: audioDuration,
                transcriptionLatencySeconds: latency,
                wordCount: text.split(separator: " ").count,
                characterCount: text.count,
                targetAppBundleID: frontmostBundleID,
                text: text
            )
            StatisticsService.shared.record(event)

            self.appState.lastTranscription = text
            self.appState.lastAudioData = audioData

            await textInsertionService.insertText(text, pressEnterAfterPaste: appState.pressEnterAfterPaste)
        } catch is CancellationError {
            Log.coordinator.info("Transcription cancelled by user")
            SoundFeedback.playStopSound()
        } catch {
            if Task.isCancelled {
                Log.coordinator.info("Transcription cancelled (underlying error: \(error))")
                SoundFeedback.playStopSound()
                return
            }
            Log.coordinator.error("Transcription error: \(error)")
            self.appState.reportError(error.localizedDescription)
            SoundFeedback.playErrorSound()
        }
    }

    private func makeProvider(for type: ProviderType) -> TranscriptionProvider {
        switch type {
        case .openAI: return OpenAIWhisperProvider()
        case .groq: return GroqWhisperProvider()
        case .local: return LocalWhisperProvider(appState: appState)
        }
    }
}
