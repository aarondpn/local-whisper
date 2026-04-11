import AppKit
import Foundation

/// Owns the audio-capture lifecycle: hotkey wiring, accidental-tap filtering, microphone
/// start/stop, system-audio muting, HUD coordination, and the minimum-duration filter. Once
/// a recording clears all of those gates, it hands the captured audio (plus contextual
/// metadata captured at key-up time) off to `onReadyToTranscribe`.
@MainActor
final class RecordingSession {
    private static let tapThreshold: TimeInterval = 0.22
    private static let stopDelay: Duration = .milliseconds(200)
    private static let recordingStartDelay: Duration = .milliseconds(150)

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
    private var isBusy = false
    private var overlayShowTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var keyDownTime: Date?
    private var recordingStartInstant: Date?
    private var lastAudibleInstant: Date?

    /// Invoked once a recording has been captured, trimmed, and passed the minimum-duration
    /// filter. The session awaits this callback before clearing its busy flag so a new
    /// press can't race an in-flight transcription.
    var onReadyToTranscribe: ((Data, String?, String?) async -> Void)?

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
                await self?.handleKeyUp()
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
        guard !isBusy else { return }
        isBusy = true
        keyDownTime = Date()
        stopTask?.cancel()
        stopTask = nil
        overlayShowTask?.cancel()

        // Defer the overlay so accidental taps never flash it on screen.
        overlayShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.tapThreshold))
            guard let self, !Task.isCancelled, self.appState.isRecording else { return }
            self.overlayPanel.showOverlay()
        }

        if appState.selectedProvider == .local && appState.localModelState != .ready {
            appState.reportError("Local model not ready. Please download it in Settings first.")
            Log.coordinator.error("Local model not ready, blocking recording")
            SoundFeedback.playErrorSound()
            overlayShowTask?.cancel()
            overlayShowTask = nil
            isBusy = false
            return
        }

        guard await PermissionChecker.checkMicrophonePermission() else {
            appState.reportError("Microphone permission required")
            Log.coordinator.error("Microphone permission denied")
            overlayShowTask?.cancel()
            overlayShowTask = nil
            isBusy = false
            return
        }

        let shouldMuteAudio = appState.muteSystemAudioDuringRecording
        let shouldBoostInput = appState.boostInputVolumeDuringRecording

        do {
            SoundFeedback.playStartSound()
            appState.isRecording = true
            appState.clearError()

            if shouldMuteAudio {
                systemAudioMuter.mute()
            }
            if shouldBoostInput {
                inputVolumeBooster.boost()
            }

            // Delay recording start so the start sound isn't captured.
            try await Task.sleep(for: Self.recordingStartDelay)

            // The user may have released during the delay; respect the cancel.
            guard appState.isRecording else { return }

            recordingStartInstant = Date()
            lastAudibleInstant = Date()
            appState.silentInputWarning = false

            try audioRecorder.startRecording { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    self.appState.audioLevel = level
                    self.evaluateSilentInput(level: level)
                }
            }
            Log.coordinator.info("Recording started")
        } catch {
            if shouldMuteAudio {
                systemAudioMuter.unmute()
            }
            if shouldBoostInput {
                inputVolumeBooster.restore()
            }
            overlayShowTask?.cancel()
            overlayShowTask = nil
            appState.isRecording = false
            overlayPanel.hideOverlay()
            isBusy = false
            appState.reportError("Recording failed: \(error.localizedDescription)")
            Log.coordinator.error("Recording failed: \(error)")
        }
    }

    private func handleKeyUp() async {
        guard appState.isRecording else { return }

        let pressDuration = Date().timeIntervalSince(keyDownTime ?? Date())
        if pressDuration < Self.tapThreshold {
            cancelShortPress()
            return
        }

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
            guard let self, !Task.isCancelled else { return }
            await self.finishStop(frontmostBundleID: frontmostBundleID, capturedContext: capturedContext)
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

    private func finishStop(frontmostBundleID: String?, capturedContext: String?) async {
        let rawAudio = audioRecorder.stopRecording()
        systemAudioMuter.unmute()
        inputVolumeBooster.restore()
        appState.isRecording = false
        appState.silentInputWarning = false
        recordingStartInstant = nil
        lastAudibleInstant = nil
        SoundFeedback.playStopSound()
        Log.coordinator.info("Recording stopped, \(rawAudio.count) bytes")

        // Trimming is CPU-bound and must not block the main actor.
        let audioData = await Task.detached {
            AudioProcessor.trimSilence(from: rawAudio)
        }.value

        // 16kHz mono 16-bit = 32000 bytes/sec + 44 byte WAV header
        let audioBytes = max(0, audioData.count - 44)
        let durationSec = Double(audioBytes) / 32000.0
        let minDuration = max(Self.absoluteMinDuration, appState.minRecordingDuration)

        if durationSec < minDuration {
            Log.coordinator.info("Recording too short (\(String(format: "%.2f", durationSec))s < \(String(format: "%.2f", minDuration))s), skipping")
            overlayPanel.hideOverlay()
            isBusy = false
            return
        }

        // Only flip to the transcribing state once we know we'll actually transcribe.
        appState.isTranscribing = true
        await onReadyToTranscribe?(audioData, frontmostBundleID, capturedContext)
        isBusy = false
    }

    private func handleEscape() {
        // Case 1: recording in flight — abort capture, never transcribe.
        if appState.isRecording {
            Log.coordinator.info("ESC pressed during recording, canceling")
            stopTask?.cancel()
            stopTask = nil
            _ = audioRecorder.stopRecording()
            systemAudioMuter.unmute()
            inputVolumeBooster.restore()
            appState.isRecording = false
            appState.isTranscribing = false
            appState.audioLevel = 0
            appState.silentInputWarning = false
            recordingStartInstant = nil
            lastAudibleInstant = nil
            overlayShowTask?.cancel()
            overlayShowTask = nil
            overlayPanel.hideOverlay()
            isBusy = false
            SoundFeedback.playStopSound()
            return
        }
        // Case 2: transcription in flight — cancel the provider task.
        if appState.isTranscribing {
            Log.coordinator.info("ESC pressed during transcription, canceling")
            appState.cancelCurrentTranscription?()
        }
    }

    private func cancelShortPress() {
        Log.coordinator.info("Press shorter than tap threshold, canceling recording")
        overlayShowTask?.cancel()
        overlayShowTask = nil
        stopTask?.cancel()
        stopTask = nil

        // Discard any audio captured so far. stopRecording is safe to call even
        // if the engine never started — the tap-state flag handles it.
        _ = audioRecorder.stopRecording()
        systemAudioMuter.unmute()
        inputVolumeBooster.restore()

        appState.isRecording = false
        appState.isTranscribing = false
        appState.audioLevel = 0
        appState.silentInputWarning = false
        recordingStartInstant = nil
        lastAudibleInstant = nil
        overlayPanel.hideOverlay()

        isBusy = false
    }
}
