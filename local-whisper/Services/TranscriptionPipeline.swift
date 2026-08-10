import Foundation

/// Everything `RecordingSession` hands off once a recording cleared its gates.
/// `liveText` is the completed streaming transcript when a live session produced
/// one — the pipeline then skips the provider round-trip entirely; nil means
/// transcribe `audioData` as before (live off, or the stream failed mid-utterance).
struct TranscriptionRequest {
    let audioData: Data
    let frontmostBundleID: String?
    let capturedContext: String?
    let liveText: String?
}

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

    func run(_ request: TranscriptionRequest) async {
        currentTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.execute(request)
        }
        currentTask = task
        await task.value
        currentTask = nil
    }

    private func execute(_ request: TranscriptionRequest) async {
        let audioData = request.audioData
        let frontmostBundleID = request.frontmostBundleID
        let capturedContext = request.capturedContext

        defer {
            Task { @MainActor in
                self.appState.isTranscribing = false
                self.appState.liveTranscript = nil
                self.overlayPanel.hideOverlay()
            }
        }

        // A completed live stream already produced the text — skip the provider
        // round-trip (and the prompt/empty-retry machinery) and share the tail:
        // statistics, last-transcription state, insertion.
        if let liveText = request.liveText {
            guard !liveText.isEmpty else {
                Log.coordinator.error("Live transcription returned empty text")
                self.appState.reportError(TranscriptionError.emptyResponse.errorDescription ?? "No transcription returned")
                SoundFeedback.playErrorSound()
                return
            }
            Log.coordinator.info("Live transcribed: \(liveText)")
            await deliver(text: liveText, audioData: audioData, latency: 0,
                          provider: .local, frontmostBundleID: frontmostBundleID)
            return
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
        let apiLanguage = language == "auto" ? nil : language

        func transcribeAllowingEmpty(prompt: String?) async throws -> String {
            do {
                return try await provider.transcribe(audioData: audioData, language: apiLanguage, prompt: prompt)
            } catch TranscriptionError.emptyResponse {
                return ""
            }
        }

        do {
            let startTime = Date()
            var text = try await transcribeAllowingEmpty(prompt: finalPrompt)
            try Task.checkCancellation()

            // Dynamic context can occasionally bias Whisper into returning nothing
            // (odd unicode, control chars, or adversarial snippets captured via AX).
            // Retry once with only the profile prompt so a poisoned context doesn't
            // swallow a valid recording.
            if text.isEmpty, capturedContext != nil {
                Log.coordinator.info("Empty result with dynamic context; retrying with profile prompt only")
                text = try await transcribeAllowingEmpty(prompt: resolved.prompt)
                try Task.checkCancellation()
            }

            let latency = Date().timeIntervalSince(startTime)

            guard !text.isEmpty else {
                Log.coordinator.error("Transcription returned empty text")
                self.appState.reportError(TranscriptionError.emptyResponse.errorDescription ?? "No transcription returned")
                SoundFeedback.playErrorSound()
                return
            }

            Log.coordinator.info("Transcribed: \(text)")

            await deliver(text: text, audioData: audioData, latency: latency,
                          provider: resolved.provider, frontmostBundleID: frontmostBundleID)
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

    /// Shared delivery tail for both the live and one-shot paths: statistics,
    /// last-transcription state, and insertion into the focused field.
    private func deliver(text: String, audioData: Data, latency: TimeInterval,
                         provider: ProviderType, frontmostBundleID: String?) async {
        let audioBytes = max(0, audioData.count - 44)
        let audioDuration = Double(audioBytes) / 32000.0
        let event = TranscriptionEvent(
            provider: provider.rawValue,
            audioDurationSeconds: audioDuration,
            transcriptionLatencySeconds: latency,
            wordCount: text.split(separator: " ").count,
            characterCount: text.count,
            targetAppBundleID: frontmostBundleID,
            text: text
        )
        StatisticsService.shared.record(event)

        appState.lastTranscription = text
        appState.lastAudioData = audioData

        await textInsertionService.insertText(text, pressEnterAfterPaste: appState.pressEnterAfterPaste)
    }

    private func makeProvider(for type: ProviderType) -> TranscriptionProvider {
        switch type {
        case .openAI: return OpenAIWhisperProvider()
        case .groq: return GroqWhisperProvider()
        case .local:
            switch LocalModelCatalog.selected.engine {
            case .whisperKit: return LocalWhisperProvider(appState: appState)
            case .parakeet: return ParakeetProvider()
            }
        }
    }
}
