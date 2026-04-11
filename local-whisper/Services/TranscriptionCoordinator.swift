import Foundation

/// Thin glue that wires a `RecordingSession` to a `TranscriptionPipeline`. The external
/// API (`start()`, `stop()`) is unchanged — this type used to own both lifecycles in one
/// 291-line class; it's now just the seam between them.
@MainActor
final class TranscriptionCoordinator {
    private let session: RecordingSession
    private let pipeline: TranscriptionPipeline

    init(appState: AppState, overlayPanel: RecordingOverlayPanel) {
        self.session = RecordingSession(appState: appState, overlayPanel: overlayPanel)
        self.pipeline = TranscriptionPipeline(appState: appState, overlayPanel: overlayPanel)
        self.session.onReadyToTranscribe = { [weak self] audioData, bundleID, context in
            await self?.pipeline.run(
                audioData: audioData,
                frontmostBundleID: bundleID,
                capturedContext: context
            )
        }
    }

    func start() { session.start() }
    func stop() { session.stop() }
}
