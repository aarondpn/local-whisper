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
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        errorToastPanel?.endObserving()
    }
}
