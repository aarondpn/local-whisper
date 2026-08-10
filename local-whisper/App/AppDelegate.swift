import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var coordinator: TranscriptionCoordinator?
    private var overlayPanel: RecordingOverlayPanel?
    private var errorToastPanel: ErrorToastPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsKeys.registerDefaults()

        Log.app.info("Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
        Log.app.info("Executable: \(Bundle.main.executableURL?.path ?? "nil")")
        Log.app.info("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        Log.app.info("Mic status: \(String(describing: PermissionChecker.microphonePermissionStatus))")

        overlayPanel = RecordingOverlayPanel(appState: appState)
        appState.overlayPanel = overlayPanel
        coordinator = TranscriptionCoordinator(appState: appState, overlayPanel: overlayPanel!)
        coordinator?.start()

        errorToastPanel = ErrorToastPanel(appState: appState)
        errorToastPanel?.beginObserving()

        // Load (never download) the selected local model at launch when its files
        // are already on disk, so local transcription — and especially the live
        // mode — works without a Settings visit after every relaunch.
        if appState.selectedProvider == .local {
            let appState = appState
            Task { await LocalModelManager.loadSelectedModelIfDownloaded(appState: appState) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        errorToastPanel?.endObserving()
        // ggml's Metal backend (statically linked via parakeet.xcframework) fires a
        // GGML_ASSERT in a static destructor during normal exit teardown once the GPU
        // device was initialized, turning every quit into a crash report. All state
        // is flushed by this point; skip atexit handlers entirely.
        _exit(0)
    }
}
