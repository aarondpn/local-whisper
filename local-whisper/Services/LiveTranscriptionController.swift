import Foundation

/// One live-transcription session: pipes 16 kHz mono PCM from the audio tap into
/// `ParakeetEngine`'s streaming API and publishes the accumulated finalized text
/// to `AppState.liveTranscript`, throttled so `@Observable` mutations stay ≤ ~12 Hz
/// while the overlay is visible.
///
/// Failure model: any engine error flips the session to `failed` — the pipe keeps
/// draining (and discarding) so the tap is never blocked, the card dims, and the
/// caller falls back to one-shot transcription of the WAV that `AudioRecorder`
/// accumulates in parallel regardless.
actor LiveTranscriptionController {
    private weak var appState: AppState?
    private let language: String?

    private let pipe: AsyncStream<[Float]>
    private let pipeContinuation: AsyncStream<[Float]>.Continuation

    private var consumerTask: Task<Void, Never>?
    private var settledText = ""
    private var failed = false
    private var finished = false

    /// Throttle state: at most one publish per interval, with a trailing publish
    /// so the last increment of a burst always lands.
    private static let publishInterval: Duration = .milliseconds(100)
    private var lastPublish: ContinuousClock.Instant = .now - .seconds(1)
    private var trailingPublishArmed = false

    init(appState: AppState, language: String?) {
        self.appState = appState
        self.language = language
        (pipe, pipeContinuation) = AsyncStream.makeStream(of: [Float].self)
    }

    /// Begin the engine stream. Returns false (inert session) when the engine
    /// can't stream — recording proceeds exactly as with live mode off.
    func start() async -> Bool {
        do {
            try await ParakeetEngine.shared.beginStream(language: language)
        } catch {
            Log.parakeet.error("stream_begin failed: \(error.localizedDescription)")
            failed = true
            return false
        }
        consumerTask = Task { await consume() }
        return true
    }

    /// Called from the audio tap thread; must never block.
    nonisolated func ingest(_ samples: [Float]) {
        pipeContinuation.yield(samples)
    }

    /// Drain the pipe in order, feeding the engine. parakeet buffers internally
    /// and decodes whenever a full encoder chunk is available, so tap-sized
    /// buffers (~256 ms) are fed as they come.
    private func consume() async {
        for await samples in pipe {
            guard !failed else { continue }  // keep draining so yields stay cheap
            let feedStart = ContinuousClock.now
            do {
                let increment = try await ParakeetEngine.shared.feed(samples)
                let feedElapsed = ContinuousClock.now - feedStart
                let realtime = Duration.seconds(Double(samples.count) / 16000.0)
                if feedElapsed > realtime * 2 {
                    Log.parakeet.warning("feed lagging: \(feedElapsed) for \(samples.count) samples")
                }
                if !increment.isEmpty {
                    settledText += increment
                    await publishThrottled()
                }
            } catch {
                Log.parakeet.error("stream_feed failed, falling back to one-shot: \(error.localizedDescription)")
                failed = true
                await ParakeetEngine.shared.abortStream()
                await markStreamFailed()
            }
        }
    }

    private func publishThrottled() async {
        let now = ContinuousClock.now
        if now - lastPublish >= Self.publishInterval {
            lastPublish = now
            await publish()
        } else if !trailingPublishArmed {
            trailingPublishArmed = true
            let wait = Self.publishInterval - (now - lastPublish)
            Task {
                try? await Task.sleep(for: wait)
                await self.firePendingPublish()
            }
        }
    }

    private func firePendingPublish() async {
        trailingPublishArmed = false
        lastPublish = .now
        await publish()
    }

    private func publish() async {
        guard !finished else { return }
        let text = settledText.trimmingCharacters(in: .whitespaces)
        await MainActor.run { [weak appState] in
            guard let appState, appState.liveTranscript != nil else { return }
            appState.liveTranscript?.settled = text
        }
    }

    private func markStreamFailed() async {
        await MainActor.run { [weak appState] in
            appState?.liveTranscript?.streamFailed = true
        }
    }

    /// End the session: drain remaining audio, flush the engine tail, and return
    /// the complete transcript — nil when the stream failed (callers fall back to
    /// one-shot transcription of the parallel WAV).
    func finish() async -> String? {
        finished = true
        pipeContinuation.finish()
        await consumerTask?.value
        guard !failed else { return nil }
        do {
            let tail = try await ParakeetEngine.shared.finalizeStream()
            settledText += tail
            return settledText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.parakeet.error("stream_finalize failed, falling back to one-shot: \(error.localizedDescription)")
            await ParakeetEngine.shared.abortStream()
            return nil
        }
    }

    /// Abandon the session (ESC, short press). Discards all text.
    func cancel() async {
        finished = true
        failed = true
        pipeContinuation.finish()
        await consumerTask?.value
        await ParakeetEngine.shared.abortStream()
    }
}
