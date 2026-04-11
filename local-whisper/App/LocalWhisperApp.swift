import SwiftUI

@main
struct LocalWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.appState)
        } label: {
            MenuBarIconLabel(appState: appDelegate.appState)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

private struct MenuBarIconLabel: View {
    let appState: AppState

    var body: some View {
        Image(systemName: iconName)
    }

    private var iconName: String {
        if appState.errorMessage != nil {
            return "waveform.badge.exclamationmark"
        }
        if appState.isRecording {
            return "waveform.circle.fill"
        }
        if appState.isTranscribing {
            return "waveform.circle"
        }
        return "waveform"
    }
}
