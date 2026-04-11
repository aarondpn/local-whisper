import SwiftUI

struct APIKeysTab: View {
    @State private var openAIKey: String = UserDefaults.standard.string(forKey: SettingsKeys.openAIAPIKey) ?? ""
    @State private var groqKey: String = UserDefaults.standard.string(forKey: SettingsKeys.groqAPIKey) ?? ""

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $openAIKey)
                    .onChange(of: openAIKey) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKeys.openAIAPIKey)
                    }
                Text("Used for OpenAI Whisper API transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Groq") {
                SecureField("API Key", text: $groqKey)
                    .onChange(of: groqKey) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKeys.groqAPIKey)
                    }
                Text("Used for Groq Whisper API transcription (fastest)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
