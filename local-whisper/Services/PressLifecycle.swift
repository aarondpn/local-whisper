import Foundation

/// Pure state machine for one hotkey press: key-down → mic start → recording → tail →
/// processing → idle. `RecordingSession` executes the side effects; every decision about
/// *whether* a key event, an ESC, or a resumed async step still applies lives here, so
/// the interleavings that matter (release before capture began, a stale start resuming
/// after a newer press, ESC mid-start) are decided synchronously and unit-testable.
///
/// Each accepted press gets a `Token`. Any async step that resumes after a suspension
/// must present its token; once the press was cancelled or superseded the token is stale
/// and the step must bail without touching shared state.
struct PressLifecycle {
    enum Phase: Equatable {
        case idle
        /// Key is down; permission check, start sound, live-stream arming, and engine start
        /// are in flight. No audio is being captured yet.
        case starting
        /// Microphone is capturing.
        case recording
        /// Key released after a real recording; the mic stays open for the trailing-audio delay.
        case stopping
        /// Mic closed; trimming, live finalize, and transcription are in flight.
        case processing
    }

    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    enum ReleaseDecision: Equatable {
        /// No press in flight, or it is already past the point a release matters.
        case ignore
        /// Released before capture began or within the tap threshold. State is already
        /// reset to idle; the caller tears down whatever the start path set up.
        case cancel
        /// A real recording: close it out after the tail delay.
        case stop(Token)
    }

    enum EscapeDecision: Equatable {
        case ignore
        /// Abort capture (starting/recording/stopping). State is already reset to idle.
        case abortCapture
        /// Mic already closed — the caller should cancel any in-flight transcription.
        /// `isProcessingCancelled` is now true so a not-yet-started hand-off is skipped.
        case cancelProcessing
    }

    let tapThreshold: TimeInterval
    private(set) var phase: Phase = .idle
    private(set) var isProcessingCancelled = false
    private var generation: UInt64 = 0
    private var pressStart: Date?

    init(tapThreshold: TimeInterval) {
        self.tapThreshold = tapThreshold
    }

    var isBusy: Bool { phase != .idle }

    /// Accepts a key-down. Returns nil while a previous press is still being handled.
    mutating func press(at now: Date) -> Token? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .starting
        pressStart = now
        isProcessingCancelled = false
        return Token(generation: generation)
    }

    /// True while `token` is the live press and still in `phase`.
    func isCurrent(_ token: Token, in phase: Phase) -> Bool {
        token.generation == generation && self.phase == phase
    }

    /// The start path finished opening the mic. Returns false when the press was
    /// cancelled or superseded meanwhile — the caller must not adopt the recording.
    mutating func captureBegan(_ token: Token) -> Bool {
        guard isCurrent(token, in: .starting) else { return false }
        phase = .recording
        return true
    }

    mutating func release(at now: Date) -> ReleaseDecision {
        switch phase {
        case .idle, .stopping, .processing:
            return .ignore
        case .starting:
            // The mic isn't open yet, so there is nothing to transcribe regardless of how
            // long the key was held. Cancelling here (instead of ignoring the release) is
            // what keeps a start that finishes later from recording with the key up.
            abort()
            return .cancel
        case .recording:
            let held = now.timeIntervalSince(pressStart ?? now)
            if held < tapThreshold {
                abort()
                return .cancel
            }
            phase = .stopping
            return .stop(Token(generation: generation))
        }
    }

    /// The trailing-audio delay elapsed. Returns false if ESC aborted during the tail.
    mutating func beginProcessing(_ token: Token) -> Bool {
        guard isCurrent(token, in: .stopping) else { return false }
        phase = .processing
        return true
    }

    mutating func escape() -> EscapeDecision {
        switch phase {
        case .idle:
            return .ignore
        case .starting, .recording, .stopping:
            abort()
            return .abortCapture
        case .processing:
            isProcessingCancelled = true
            return .cancelProcessing
        }
    }

    /// Processing finished (transcribed, skipped, or cancelled). No-op for a stale token.
    mutating func finish(_ token: Token) {
        guard isCurrent(token, in: .processing) else { return }
        phase = .idle
        pressStart = nil
        isProcessingCancelled = false
    }

    /// Unconditionally returns to idle and invalidates every outstanding token.
    mutating func abort() {
        generation &+= 1
        phase = .idle
        pressStart = nil
        isProcessingCancelled = false
    }
}
