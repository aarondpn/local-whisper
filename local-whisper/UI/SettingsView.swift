import SwiftUI

enum SettingsTab: String, Hashable {
    case general, apiKeys, audio, shortcut, profiles, context, history, statistics
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }
                .tag(SettingsTab.apiKeys)

            AudioTab()
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(SettingsTab.audio)

            ShortcutTab()
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
                .tag(SettingsTab.shortcut)

            ProfilesTab()
                .tabItem { Label("Profiles", systemImage: "person.2") }
                .tag(SettingsTab.profiles)

            ContextTab()
                .tabItem { Label("Context", systemImage: "text.magnifyingglass") }
                .tag(SettingsTab.context)

            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)

            StatisticsTab()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
                .tag(SettingsTab.statistics)
        }
        .frame(width: 620, height: 640)
        .onAppear {
            if let requested = appState.requestedSettingsTab {
                selection = requested
                appState.requestedSettingsTab = nil
            }
        }
        .onChange(of: appState.requestedSettingsTab) { _, newValue in
            if let newValue {
                selection = newValue
                appState.requestedSettingsTab = nil
            }
        }
    }
}
