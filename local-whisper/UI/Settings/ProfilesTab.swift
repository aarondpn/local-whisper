import AppKit
import SwiftUI

struct ProfilesTab: View {
    @Environment(AppState.self) private var appState
    @State private var showingEditor = false
    @State private var editingProfile: AppProfile?
    @State private var selectedProfileID: AppProfile.ID?

    var body: some View {
        VStack(spacing: 0) {
            if appState.profileManager.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "person.2")
                } description: {
                    Text("Add a profile to automatically switch language and provider settings for specific apps.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedProfileID) {
                    ForEach(appState.profileManager.profiles) { profile in
                        HStack {
                            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.appBundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            VStack(alignment: .leading) {
                                Text(profile.appName)
                                    .font(.body)
                                Text(profileSummary(profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingProfile = profile
                        }
                        .contextMenu {
                            Button("Delete") {
                                appState.profileManager.deleteProfile(profile)
                            }
                        }
                    }
                }
            }

            HStack {
                Button {
                    editingProfile = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    if let id = selectedProfileID,
                       let profile = appState.profileManager.profiles.first(where: { $0.id == id }) {
                        appState.profileManager.deleteProfile(profile)
                        selectedProfileID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedProfileID == nil)

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(profileManager: appState.profileManager)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(profileManager: appState.profileManager, existingProfile: profile)
        }
    }

    private func profileSummary(_ profile: AppProfile) -> String {
        var parts: [String] = []
        parts.append(ProfileManager.languageDisplayName(for: profile.language))
        if profile.provider != "default", let type = ProviderType(rawValue: profile.provider) {
            parts.append(type.displayName)
        }
        return parts.joined(separator: " · ")
    }
}
