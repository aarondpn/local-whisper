import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var hasAccessibility = PermissionChecker.hasAccessibilityPermission
    @State private var micStatus = PermissionChecker.microphonePermissionStatus

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 4) {
            Text("LocalWhisper")
                .font(.headline)

            Divider()

            if let error = appState.errorMessage {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("Dismiss") {
                        appState.clearError()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                Divider()
            }

            Label(appState.providerStatusText, systemImage: providerIcon)

            Picker("Provider", selection: $appState.selectedProvider) {
                ForEach(ProviderType.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let profileName = appState.activeProfileName {
                Label("Profile: \(profileName)", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            }

            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
            } else if appState.isTranscribing {
                Label("Transcribing...", systemImage: "text.bubble")
                    .foregroundStyle(.orange)
            }

            if !appState.hotkeyConfiguration.isConfigured {
                Button {
                    showSettings(tab: .shortcut)
                } label: {
                    Label("No shortcut configured — tap to set", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.borderless)
            } else {
                Label("Hold \(appState.hotkeyConfiguration.displayString) to record", systemImage: "keyboard")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if hasAccessibility && micStatus == .granted {
                Label("All permissions granted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                if !hasAccessibility {
                    Button {
                        PermissionChecker.requestAccessibilityPermission()
                    } label: {
                        Label("Accessibility required", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                if micStatus != .granted {
                    Button {
                        Task {
                            _ = await PermissionChecker.checkMicrophonePermission()
                            refreshPermissions()
                        }
                    } label: {
                        Label(micStatus == .denied ? "Microphone denied" : "Microphone required",
                              systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            Button("Settings...") {
                showSettings(tab: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit LocalWhisper") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(4)
        .onAppear {
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        hasAccessibility = PermissionChecker.hasAccessibilityPermission
        micStatus = PermissionChecker.microphonePermissionStatus
    }

    private func showSettings(tab: SettingsTab?) {
        if let tab {
            appState.requestedSettingsTab = tab
        }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private var providerIcon: String {
        switch appState.selectedProvider {
        case .openAI: return "cloud"
        case .groq: return "bolt"
        case .local: return "desktopcomputer"
        }
    }
}
