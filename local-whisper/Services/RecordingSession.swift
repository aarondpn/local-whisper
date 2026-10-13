import AppKit
import Foundation

/// Owns the audio-capture lifecycle: hotkey wiring, accidental-tap filtering, microphone
/// start/stop, system-audio muting, HUD coordination, and the minimum-duration filter. Once
/// a recording clears all of those gates, it hands the captured audio (plus contextual
/// metadata captured at key-up time) off to `onReadyToTranscribe`.
///
/// Which press a key event, ESC, or resumed async step belongs to is decided by
/// `PressLifecycle`; this type only performs the side effects. Every await in the start
/// and stop paths re-checks its press token afterwards, so a press that was released,
/// escaped, or superseded while suspended can never start or adopt a recording.
@MainActor
final class RecordingSession {
    private static let tapThreshold: TimeInterval = 0.22
    private static let stopDelay: Duration = .milliseconds(200)
    private static let recordingStartDelay: Duration = .milliseconds(150)

    /// Hold watchdog cadence. Two consecutive "key is up" readings trigger a synthesized
    /// release, so a missed key-up ends the recording within ~0.5 s while a real key-up
    /// (which lands within milliseconds) always wins the race.
    private static let holdCheckInterval: Duration = .milliseconds(250)
    private static let holdCheckMissesBeforeRelease = 2

    private static let silentInputThreshold: Float = 0.02
    private static let silentInputGracePeriod: TimeInterval = 2.0

    /// Hard floor that guards against settings races (e.g. UserDefaults read before
    /// registerDefaults) and against the trim stage stripping the whole clip down to
    /// its WAV header. Whisper APIs reject clips shorter than this anyway.
    private static let absoluteMinDuration: TimeInterval = 0.25

    private let appState: AppState
    private let overlayPanel: RecordingOverlayPanel
    private let hotkeyService = HotkeyService()
    private let audioRecorder = AudioRecorder()
    private let systemAudioMuter = SystemAudioMuter()
    private let inputVolumeBooster = InputVolumeBooster()
    private var settingsObserver: Any?
    private var lifecycle = PressLifecycle(tapThreshold: RecordingSession.tapThreshold)
    private var overlayShowTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var holdWatchdog: Task<Void, Never>?
    private var recordingStartInstant: Date?
    private var lastAudibleInstant: Date?
    private var liveController: LiveTranscriptionController?

    /// Invoked once a recording has been captured, trimmed, and passed the minimum-duration
    /// filter. The session awaits this callback before accepting the next press so it
    /// can't race an in-flight transcription.
    var onReadyToTranscribe: ((TranscriptionRequest) async -> Void)?

    init(appState: AppState, overlayPanel: RecordingOverlayPanel) {
        self.appState = appState
        self.overlayPanel = overlayPanel
    }

    func start() {
        hotkeyService.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.handleKeyDown()
            }
        }
        hotkeyService.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.handleKeyUp()
            }
        }
        hotkeyService.onEscape = { [weak self] in
            Task { @MainActor in
                self?.handleEscape()
            }
        }
        hotkeyService.start()

        // Re-load hotkey config whenever UserDefaults change (e.g. shortcut changed in Settings)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hotkeyService.reloadConfiguration()
            }
        }
    }

    func stop() {
        hotkeyService.stop()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func handleKeyDown() async {
        // Claim the press before the first suspension point: from here on a key-up or ESC
        // sees `.starting` and cancels, instead of slipping through before capture begins.
        guard let token = lifecycle.press(at: Date()) else { return }
        startHoldWatchdog()

        // Defer the overlay so accidental taps never flash it on screen.
        overlayShowTask?.cancel()
        overlayShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.tapThreshold))
            guard let self, !Task.isCancelled, self.appState.isRecording else { return }
            self.overlayPanel.showOverlay()
        }

        if appState.selectedProvider == .local && appState.localModelState != .ready {
            Log.coordinator.error("Local model not ready, blocking recording")
            failStart(token, message: "Local model not ready. Please download it in Settings first.")
            SoundFeedback.playErrorSound()
            return
        }

        // Only a first-run permission prompt actually suspends here.
        let micAllowed: Bool
        switch PermissionChecker.microphonePermissionStatus {
        case .granted: micAllowed = true
        case .denied: micAllowed = false
        case .notDetermined: micAllowed = await PermissionChecker.checkMicrophonePermission()
        }
        guard micAllowed else {
            Log.coordinator.error("Microphone permission denied")
            failStart(token, message: "Microphone permission required")
            return
        }
        // Released (or ESC) while the permission prompt was up.
        guard lifecycle.isCurrent(token, in: .starting) else { return }

        // Live-transcription arming decision. The per-app profile is resolved at
        // key-down (the frontmost app is known now); the one-shot path keeps its
        // key-up resolution, so a mid-recording app switch at worst shows live
        // text for a session a profile would have routed elsewhere.
        let frontmostAtKeyDown = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let resolvedAtKeyDown = appState.profileManager.resolveSettings(
            for: frontmostAtKeyDown,
            globalProvider: appState.selectedProvider,
            globalLanguage: appState.language
        )
        let liveEligible = resolvedAtKeyDown.provider == .local
            && LocalModelCatalog.selected.streamingCapable
            && appState.liveTranscriptionEnabled
            && appState.hudEnabled
            && appState.localModelState == .ready

        SoundFeedback.playStartSound()
        appState.isRecording = true
        appState.clearError()

        if appState.muteSystemAudioDuringRecording {
            systemAudioMuter.mute()
        }
        if appState.boostInputVolumeDuringRecording {
            inputVolumeBooster.boost()
        }

        // Arm the streaming session concurrently with the start-sound delay so
        // stream_begin costs no extra latency. A failed start leaves the session
        // inert — recording proceeds exactly as with live mode off.
        var armingController: LiveTranscriptionController?
        var armingTask: Task<Bool, Never>?
        if liveEligible {
            let language = resolvedAtKeyDown.language == "auto" ? nil : resolvedAtKeyDown.language
            let controller = LiveTranscriptionController(appState: appState, language: language)
            armingController = controller
            armingTask = Task { await controller.start() }
        }

        // Delay recording start so the start sound isn't captured.
        try? await Task.sleep(for: Self.recordingStartDelay)
        let armed = await armingTask?.value ?? false

        // Released, escaped, or superseded during the delay: the cancel path already tore
        // down everything above; only the stream armed here is still ours to drop.
        guard lifecycle.isCurrent(token, in: .starting) else {
            if armed, let armingController {
                Task { await armingController.cancel() }
            }
            return
        }

        if armed, let armingController {
            // Adopt before the engine start so a cancel during it also cancels the stream.
            liveController = armingController
        }

        recordingStartInstant = Date()
        lastAudibleInstant = Date()
        appState.silentInputWarning = false

        do {
            try await audioRecorder.startRecording(
                onLevelUpdate: { [weak self] level in
                    guard let self else { return }
                    Task { @MainActor in
                        // Late buffers from a canceled or finished press must not touch the HUD.
                        guard self.lifecycle.isCurrent(token, in: .recording) else { return }
                        self.appState.audioLevel = level
                        self.evaluateSilentInput(level: level)
                    }
                },
                onPCMFrames: liveController.map { controller in
                    { @Sendable [weak controller] frames in controller?.ingest(frames) }
                }
            )
        } catch {
            // A cancel during the start already discarded the recorder and reset state.
            guard lifecycle.isCurrent(token, in: .starting) else { return }
            Log.coordinator.error("Recording failed: \(error)")
            failStart(token, message: "Recording failed: \(error.localizedDescription)")
            return
        }

        // Released or escaped while the engine was starting. The cancel path enqueued a
        // discard behind this start on the recorder queue, so the mic is already closing.
        guard lifecycle.captureBegan(token) else { return }

        if liveController != nil {
            appState.liveTranscript = AppState.LiveTranscript()
        }
        Log.coordinator.info("Recording started\(liveController != nil ? " (live transcription armed)" : "")")
    }

    private func handleKeyUp() {
        switch lifecycle.release(at: Date()) {
        case .ignore:
            return
        case .cancel:
            Log.coordinator.info("Released before capture began or within tap threshold, canceling recording")
            tearDownCapture()
        case .stop(let token):
            beginStop(token)
        }
    }

    private func beginStop(_ token: PressLifecycle.Token) {
        stopHoldWatchdog()

        // Capture the frontmost app and its context now, before any UI changes.
        // Reading AX after the stop delay is risky — focus can shift if the user
        // switches apps during the 200 ms tail.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmost?.bundleIdentifier
        let frontmostAppName = frontmost?.localizedName
        let capturedContext = ContextProvider.captureDynamicContext()

        appState.lastContextAppBundleID = frontmostBundleID
        appState.lastContextAppName = frontmostAppName

        // Brief delay so trailing audio isn't clipped.
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stopDelay)
            guard let self, self.lifecycle.beginProcessing(token) else { return }
            self.stopTask = nil
            await self.finishStop(token, frontmostBundleID: frontmostBundleID, capturedContext: capturedContext)
        }
    }

    private func evaluateSilentInput(level: Float) {
        if level >= Self.silentInputThreshold {
            lastAudibleInstant = Date()
            if appState.silentInputWarning {
                appState.silentInputWarning = false
            }
            return
        }
        guard let start = recordingStartInstant else { return }
        let elapsedSinceStart = Date().timeIntervalSince(start)
        guard elapsedSinceStart >= Self.silentInputGracePeriod else { return }
        let elapsedSinceAudible = Date().timeIntervalSince(lastAudibleInstant ?? start)
        if elapsedSinceAudible >= Self.silentInputGracePeriod, !appState.silentInputWarning {
            appState.silentInputWarning = true
            Log.coordinator.warning("Silent input detected for \(elapsedSinceAudible)s")
        }
    }

    private func finishStop(_ token: PressLifecycle.Token, frontmostBundleID: String?, capturedContext: String?) async {
        let rawAudio = await audioRecorder.stopRecording()
        systemAudioMuter.unmute()
        inputVolumeBooster.restore()
        appState.isRecording = false
        appState.audioLevel = 0
        appState.silentInputWarning = false
        recordingStartInstant = nil
        lastAudibleInstant = nil
        SoundFeedback.playStopSound()
        Log.coordinator.info("Recording stopped, \(rawAudio.count) bytes")

        let controller = liveController
        liveController = nil

        // Finalize the live stream concurrently with the (CPU-bound, detached) trim:
        // the trimmed WAV is still needed for fallback, replay, and the duration
        // filter, which stays authoritative for "too short, skip".
        let finalizeStart = ContinuousClock.now
        async let liveFinish = controller?.finish()
        let audioData = await Task.detached {
            AudioProcessor.trimSilence(from: rawAudio)
        }.value
        let liveText = (await liveFinish) ?? nil
        if controller != nil {
            let elapsed = ContinuousClock.now - finalizeStart
            Log.parakeet.info("Live finalize drained in \(elapsed)")
        }

        if lifecycle.isProcessingCancelled {
            Log.coordinator.info("Canceled before transcription started, discarding recording")
            endProcessing(token)
            return
        }

        // 16kHz mono 16-bit = 32000 bytes/sec + 44 byte WAV header
        let audioBytes = max(0, audioData.count - 44)
        let durationSec = Double(audioBytes) / 32000.0
        let minDuration = max(Self.absoluteMinDuration, appState.minRecordingDuration)

        if durationSec < minDuration {
            Log.coordinator.info("Recording too short (\(String(format: "%.2f", durationSec))s < \(String(format: "%.2f", minDuration))s), skipping")
            endProcessing(token)
            return
        }

        // Only flip to the transcribing state once we know we'll actually transcribe.
        appState.isTranscribing = true
        await onReadyToTranscribe?(TranscriptionRequest(
            audioData: audioData,
            frontmostBundleID: frontmostBundleID,
            capturedContext: capturedContext,
            liveText: liveText
        ))
        lifecycle.finish(token)
    }

    /// Ends a session that never reached the transcription hand-off.
    private func endProcessing(_ token: PressLifecycle.Token) {
        appState.liveTranscript = nil
        overlayPanel.hideOverlay()
        lifecycle.finish(token)
    }

    private func handleEscape() {
        switch lifecycle.escape() {
        case .ignore:
            return
        case .abortCapture:
            Log.coordinator.info("ESC pressed during recording, canceling")
            tearDownCapture()
            SoundFeedback.playStopSound()
        case .cancelProcessing:
            // Before the hand-off, `isProcessingCancelled` makes finishStop discard the clip.
            if appState.isTranscribing {
                Log.coordinator.info("ESC pressed during transcription, canceling")
                appState.cancelCurrentTranscription?()
            }
        }
    }

    /// The early-exit path of `handleKeyDown`: reports the error and undoes whatever the
    /// start path set up. No-op if the press was already canceled meanwhile.
    private func failStart(_ token: PressLifecycle.Token, message: String) {
        guard lifecycle.isCurrent(token, in: .starting) else { return }
        tearDownCapture()
        appState.reportError(message)
    }

    /// Single teardown for every way a capture ends without transcription: short press,
    /// release before the mic opened, ESC, and start failures. Every step is idempotent
    /// and safe for resources that were never acquired, so callers don't need to know how
    /// far the start path got.
    private func tearDownCapture() {
        lifecycle.abort()
        stopHoldWatchdog()
        overlayShowTask?.cancel()
        overlayShowTask = nil
        stopTask?.cancel()
        stopTask = nil

        if let controller = liveController {
            liveController = nil
            Task { await controller.cancel() }
        }
        appState.liveTranscript = nil
        // Enqueued behind any in-flight start, so it also stops an engine still starting.
        audioRecorder.discardRecording()
        systemAudioMuter.unmute()
        inputVolumeBooster.restore()

        appState.isRecording = false
        appState.isTranscribing = false
        appState.audioLevel = 0
        appState.silentInputWarning = false
        recordingStartInstant = nil
        lastAudibleInstant = nil
        overlayPanel.hideOverlay()
    }

    // MARK: - Hold watchdog

    /// Backstop for a key-up that never arrives (event tap disabled by a main-thread stall,
    /// tap recreated after wake, …): polls the hardware key state while the press is live
    /// and synthesizes the release through `HotkeyService`, which then takes the normal
    /// key-up path. Inert when the hardware state couldn't be verified at key-down.
    private func startHoldWatchdog() {
        holdWatchdog?.cancel()
        holdWatchdog = Task { @MainActor [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.holdCheckInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.lifecycle.phase == .starting || self.lifecycle.phase == .recording else { return }
                misses = self.hotkeyService.hasMissedRelease ? misses + 1 : 0
                if misses >= Self.holdCheckMissesBeforeRelease {
                    self.hotkeyService.reconcileHeldKey()
                    return
                }
            }
        }
    }

    private func stopHoldWatchdog() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
    }
}
