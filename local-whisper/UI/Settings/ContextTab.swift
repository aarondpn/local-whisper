import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContextTab: View {
    @Environment(AppState.self) private var appState

    @State private var useDynamicContext = UserDefaults.standard.bool(forKey: SettingsKeys.useDynamicContext)
    @State private var useWindowTitleFallback = UserDefaults.standard.bool(forKey: SettingsKeys.useWindowTitleFallback)
    @State private var excludedApps: [ExcludedContextApp] = ContextProvider.loadExcludedApps()

    var body: some View {
        Form {
            Section("Dynamic Context") {
                Toggle("Use surrounding text as context", isOn: $useDynamicContext)
                    .onChange(of: useDynamicContext) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKeys.useDynamicContext)
                    }
                Text("Reads text near the caret in the focused app via Accessibility and feeds it to Whisper's prompt parameter to bias toward matching vocabulary and style.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Fall back to window title", isOn: $useWindowTitleFallback)
                    .onChange(of: useWindowTitleFallback) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKeys.useWindowTitleFallback)
                    }
                    .disabled(!useDynamicContext)
                Text("When no text can be read (Electron apps, empty fields, canvas editors), use the focused window title as a weaker vocabulary hint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Excluded Apps") {
                if excludedApps.isEmpty {
                    Text("No apps excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedApps) { app in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.appName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(app.bundleID)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                remove(app)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from exclusion list")
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    if let lastID = appState.lastContextAppBundleID,
                       let lastName = appState.lastContextAppName,
                       !excludedApps.contains(where: { $0.bundleID == lastID }) {
                        Button {
                            addQuick(bundleID: lastID, name: lastName)
                        } label: {
                            Label("Exclude \(lastName)", systemImage: "plus.circle.fill")
                        }
                        .help("Add the last app you dictated into")
                    }

                    Button {
                        addFromPicker()
                    } label: {
                        Label("Add App…", systemImage: "plus")
                    }
                    .help("Choose any app from /Applications")

                    Spacer()
                }

                Text("Excluded apps contribute no dynamic context — only the per-app profile prompt, if any, is sent to Whisper when dictating in them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let prompt = appState.lastPrompt, !prompt.isEmpty {
                Section("Last Prompt (\(prompt.count) chars, \(prompt.utf8.count) bytes)") {
                    ScrollView {
                        Text(prompt)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Mutations

    private func remove(_ app: ExcludedContextApp) {
        excludedApps.removeAll { $0.bundleID == app.bundleID }
        ContextProvider.saveExcludedApps(excludedApps)
    }

    private func addQuick(bundleID: String, name: String) {
        guard !excludedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        excludedApps.append(ExcludedContextApp(bundleID: bundleID, appName: name))
        ContextProvider.saveExcludedApps(excludedApps)
    }

    private func addFromPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Select an app to exclude from dynamic context capture."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }

        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        guard !excludedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        excludedApps.append(ExcludedContextApp(bundleID: bundleID, appName: name))
        ContextProvider.saveExcludedApps(excludedApps)
    }
}
