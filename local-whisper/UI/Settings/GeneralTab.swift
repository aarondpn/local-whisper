import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var localModelName = UserDefaults.standard.string(forKey: SettingsKeys.localModelName) ?? "large-v3_turbo"

    private let localModels = [
        ("tiny", "Tiny (~75 MB)"),
        ("base", "Base (~140 MB)"),
        ("small", "Small (~460 MB)"),
        ("large-v3_turbo", "Large v3 Turbo (~1.5 GB)"),
        ("large-v3", "Large v3 (~3 GB)"),
    ]

    private var localModelStatusText: String {
        switch appState.localModelState {
        case .notLoaded: return "Not loaded"
        case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
        case .loading: return "Loading model..."
        case .ready: return "Ready"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var localModelStatusColor: Color {
        switch appState.localModelState {
        case .notLoaded: return .secondary
        case .downloading, .loading: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    private let languages = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
    ]

    var body: some View {
        @Bindable var appState = appState
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            Toggle("Press Enter after inserting text", isOn: $appState.pressEnterAfterPaste)

            Picker("Transcription Provider", selection: $appState.selectedProvider) {
                ForEach(ProviderType.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            if appState.selectedProvider == .local {
                Picker("Model", selection: $localModelName) {
                    ForEach(localModels, id: \.0) { id, name in
                        Text(name).tag(id)
                    }
                }
                .disabled({
                    if case .downloading = appState.localModelState { return true }
                    if case .loading = appState.localModelState { return true }
                    return false
                }())
                .onChange(of: localModelName) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: SettingsKeys.localModelName)
                    // Reset state when model changes so user knows to download again
                    if appState.localModelState == .ready {
                        appState.localModelState = .notLoaded
                        Task { await LocalWhisperProvider.resetLoadedModel() }
                    }
                }

                if case .downloading(let progress) = appState.localModelState {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress) {
                            HStack {
                                Text("Downloading model...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.orange)
                    }
                } else if case .loading = appState.localModelState {
                    HStack {
                        Text("Loading model...")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    HStack {
                        Text("Status:")
                            .foregroundStyle(.secondary)
                        Text(localModelStatusText)
                            .foregroundStyle(localModelStatusColor)
                        Spacer()
                        if appState.localModelState == .notLoaded || appState.localModelState != .ready {
                            Button("Download") {
                                Task {
                                    await LocalWhisperProvider.downloadAndLoadModel(appState: appState)
                                }
                            }
                        }
                    }
                    .font(.caption)
                }
            }

            Picker("Language", selection: $appState.language) {
                ForEach(languages, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }

            Section("Overlay") {
                Toggle("Show recording overlay", isOn: $appState.hudEnabled)

                Toggle("Show recording indicator", isOn: $appState.hudShowIndicator)
                    .disabled(!appState.hudEnabled)

                Toggle("Show elapsed timer", isOn: $appState.hudShowTimer)
                    .disabled(!appState.hudEnabled)

                Picker("Size", selection: $appState.hudSize) {
                    ForEach(HUDSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!appState.hudEnabled)

                Picker("Position", selection: $appState.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .disabled(!appState.hudEnabled)
                .onChange(of: appState.overlayPosition) { _, newValue in
                    if newValue != .custom && appState.isOverlayPositioningSession {
                        appState.overlayPanel?.endPositioningSession()
                    }
                }

                if appState.overlayPosition == .custom {
                    HStack {
                        if appState.isOverlayPositioningSession {
                            Button("Done") {
                                appState.overlayPanel?.endPositioningSession()
                            }
                            .keyboardShortcut(.defaultAction)
                            Text("Drag the overlay to place it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Position Overlay…") {
                                appState.overlayPanel?.beginPositioningSession()
                            }
                            if appState.overlayCustomPositionSet {
                                Button("Reset") {
                                    appState.overlayCustomPositionSet = false
                                    appState.overlayCustomX = 0
                                    appState.overlayCustomY = 0
                                }
                            }
                        }
                    }
                    .disabled(!appState.hudEnabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    HUDThemePickerView()
                        .disabled(!appState.hudEnabled)
                        .opacity(appState.hudEnabled ? 1 : 0.5)
                }
                .padding(.top, 2)
            }

            if !appState.lastTranscription.isEmpty {
                Section("Last Transcription") {
                    Text(appState.lastTranscription)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if appState.lastAudioData != nil {
                        Button {
                            if appState.isPlayingLastAudio {
                                appState.stopLastAudio()
                            } else {
                                appState.playLastAudio()
                            }
                        } label: {
                            Label(
                                appState.isPlayingLastAudio ? "Stop" : "Play Recording",
                                systemImage: appState.isPlayingLastAudio ? "stop.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let error = appState.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear {
            if appState.isOverlayPositioningSession {
                appState.overlayPanel?.endPositioningSession()
            }
        }
    }
}
