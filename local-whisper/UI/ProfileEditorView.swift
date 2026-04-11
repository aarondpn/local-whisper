import AppKit
import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let profileManager: ProfileManager
    var existingProfile: AppProfile?

    @State private var selectedApp: RunningApp?
    @State private var language = "auto"
    @State private var provider = "default"
    @State private var prompt = ""

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

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return RunningApp(bundleID: bundleID, name: name, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if existingProfile == nil {
                    Section("Application") {
                        Picker("App", selection: $selectedApp) {
                            Text("Select an app...").tag(nil as RunningApp?)
                            ForEach(runningApps) { app in
                                HStack {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(app.name)
                                }
                                .tag(app as RunningApp?)
                            }
                        }
                    }
                } else {
                    Section("Application") {
                        HStack {
                            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: existingProfile!.appBundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            Text(existingProfile!.appName)
                        }
                    }
                }

                Section("Transcription Settings") {
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }

                    Picker("Provider", selection: $provider) {
                        Text("Use Default").tag("default")
                        ForEach(ProviderType.allCases) { type in
                            Text(type.displayName).tag(type.rawValue)
                        }
                    }
                }

                Section {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                    Text("Optional prompt to guide the model's style, vocabulary, and spelling. For example: \"Meeting notes with technical terms like Kubernetes, gRPC.\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Whisper Prompt")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(existingProfile == nil && selectedApp == nil)
            }
            .padding()
        }
        .frame(width: 400, height: 380)
        .onAppear {
            if let profile = existingProfile {
                language = profile.language
                provider = profile.provider
                prompt = profile.prompt
            }
        }
    }

    private func save() {
        if var profile = existingProfile {
            profile.language = language
            profile.provider = provider
            profile.prompt = prompt
            profileManager.updateProfile(profile)
        } else if let app = selectedApp {
            let profile = AppProfile(
                appBundleID: app.bundleID,
                appName: app.name,
                language: language,
                provider: provider,
                prompt: prompt
            )
            profileManager.addProfile(profile)
        }
        dismiss()
    }
}

struct RunningApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?

    var id: String { bundleID }

    static func == (lhs: RunningApp, rhs: RunningApp) -> Bool {
        lhs.bundleID == rhs.bundleID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }
}
