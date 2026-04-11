import SwiftUI

struct ShortcutTab: View {
    @Environment(AppState.self) private var appState
    @State private var hasAccessibility = PermissionChecker.hasAccessibilityPermission
    @State private var micStatus = PermissionChecker.microphonePermissionStatus

    var body: some View {
        Form {
            Section("Push-to-Talk Shortcut") {
                ShortcutRecorderView()

                Text("Hold the shortcut key to record, release to transcribe and insert text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Press Esc during a recording or transcription to cancel it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    name: "Accessibility",
                    description: "Required for global keyboard shortcuts and text insertion.",
                    isGranted: hasAccessibility
                ) {
                    PermissionChecker.requestAccessibilityPermission()
                }

                PermissionRow(
                    name: "Microphone",
                    description: "Required to record speech for transcription.",
                    isGranted: micStatus == .granted
                ) {
                    Task {
                        _ = await PermissionChecker.checkMicrophonePermission()
                        micStatus = PermissionChecker.microphonePermissionStatus
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            hasAccessibility = PermissionChecker.hasAccessibilityPermission
            micStatus = PermissionChecker.microphonePermissionStatus
        }
    }
}

struct PermissionRow: View {
    let name: String
    let description: String
    let isGranted: Bool
    let requestAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                if isGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access", action: requestAction)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
