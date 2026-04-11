import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    @Environment(AppState.self) private var appState
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut:")

            Button(action: toggleRecording) {
                Text(buttonLabel)
                    .frame(minWidth: 120)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            if appState.hotkeyConfiguration.isConfigured {
                Button("Clear") {
                    var config = HotkeyConfiguration(keyCode: 999, modifiers: CGEventFlags(rawValue: 0))
                    config.save()
                    appState.hotkeyConfiguration = config
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var buttonLabel: String {
        if isRecording {
            return "Press a key..."
        }
        return appState.hotkeyConfiguration.displayString
    }

    private func toggleRecording() {
        if isRecording {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let keyCode = event.keyCode
            let modifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))

            // Filter to only meaningful modifier flags
            let relevantModifiers = CGEventFlags(rawValue: modifiers.rawValue & (
                CGEventFlags.maskCommand.rawValue |
                CGEventFlags.maskShift.rawValue |
                CGEventFlags.maskAlternate.rawValue |
                CGEventFlags.maskControl.rawValue
            ))

            // For flagsChanged, detect Fn key press
            if event.type == .flagsChanged {
                if event.modifierFlags.contains(.function) && keyCode == UInt16(kVK_Function) {
                    var config = HotkeyConfiguration(keyCode: UInt16(kVK_Function), modifiers: CGEventFlags(rawValue: 0))
                    config.save()
                    appState.hotkeyConfiguration = config
                    stopListening()
                    return nil
                }
                return event
            }

            // Escape cancels
            if keyCode == 53 {
                stopListening()
                return nil
            }

            var config = HotkeyConfiguration(keyCode: keyCode, modifiers: relevantModifiers)
            config.save()
            appState.hotkeyConfiguration = config
            stopListening()

            return nil
        }
    }

    private func stopListening() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
