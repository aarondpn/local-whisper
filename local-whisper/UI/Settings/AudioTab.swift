import AVFoundation
import SwiftUI

struct AudioTab: View {
    @Environment(AppState.self) private var appState
    @State private var trimEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.trimSilenceEnabled)
    @State private var threshold = UserDefaults.standard.double(forKey: SettingsKeys.silenceThresholdDB)
    @State private var minDuration = UserDefaults.standard.double(forKey: SettingsKeys.silenceMinDuration)

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceUID: String = UserDefaults.standard.string(forKey: SettingsKeys.selectedInputDeviceUID) ?? ""

    @State private var testRecorder: AudioRecorder?
    @State private var isTestRecording = false
    @State private var testAudioLevel: Float = 0
    @State private var testRawAudio: Data?
    @State private var testProcessedAudio: Data?
    @State private var testPlayer: AVAudioPlayer?
    @State private var testPlayerDelegate: AudioTabPlayerDelegate?
    @State private var playingSource: TestPlaybackSource?
    @State private var isProcessing = false

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Input Device") {
                Picker("Microphone", selection: $selectedDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: SettingsKeys.selectedInputDeviceUID)
                }
                Text("Choose which microphone to use for recording. \"System Default\" uses whatever macOS has selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Boost input volume during recording", isOn: $appState.boostInputVolumeDuringRecording)
                Text("Temporarily sets microphone input volume to maximum while recording, then restores the original level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System Audio") {
                Toggle("Mute system audio during recording", isOn: $appState.muteSystemAudioDuringRecording)
                Text("Mutes all system audio output while recording to prevent background audio from being captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Silence Trimming") {
                Toggle("Trim silence from recordings", isOn: $trimEnabled)
                    .onChange(of: trimEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKeys.trimSilenceEnabled)
                    }

                if trimEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Threshold")
                            Spacer()
                            Text("\(Int(threshold)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $threshold, in: -60...(-20), step: 1)
                            .onChange(of: threshold) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: SettingsKeys.silenceThresholdDB)
                            }
                        Text("Lower = only trim very quiet parts. Higher = more aggressive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Min Duration")
                            Spacer()
                            Text("\(String(format: "%.2f", minDuration)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $minDuration, in: 0.01...0.5, step: 0.01)
                            .onChange(of: minDuration) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: SettingsKeys.silenceMinDuration)
                            }
                        Text("Minimum silence duration before it gets trimmed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Reset to Defaults") {
                        threshold = -45
                        minDuration = 0.05
                        appState.minRecordingDuration = 0.3
                        UserDefaults.standard.set(threshold, forKey: SettingsKeys.silenceThresholdDB)
                        UserDefaults.standard.set(minDuration, forKey: SettingsKeys.silenceMinDuration)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Minimum Recording Length") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Min Duration")
                        Spacer()
                        Text("\(String(format: "%.1f", appState.minRecordingDuration)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.minRecordingDuration, in: 0.1...2.0, step: 0.1)
                    Text("Recordings shorter than this are discarded without sending a request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Test Recording") {
                HStack(spacing: 12) {
                    Button {
                        if isTestRecording {
                            stopTestRecording()
                        } else {
                            startTestRecording()
                        }
                    } label: {
                        Label(
                            isTestRecording ? "Stop" : "Record",
                            systemImage: isTestRecording ? "stop.fill" : "circle.fill"
                        )
                        .foregroundStyle(isTestRecording ? Color.primary : Color.red)
                    }
                    .buttonStyle(.borderless)

                    if let rawAudio = testRawAudio {
                        Button {
                            playTestAudio(rawAudio, source: .original)
                        } label: {
                            Label(
                                "Original (\(wavDurationString(rawAudio)))",
                                systemImage: playingSource == .original ? "stop.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderless)

                        if let processedAudio = testProcessedAudio {
                            Button {
                                playTestAudio(processedAudio, source: .processed)
                            } label: {
                                Label(
                                    "Processed (\(wavDurationString(processedAudio)))",
                                    systemImage: playingSource == .processed ? "stop.fill" : "play.fill"
                                )
                            }
                            .buttonStyle(.borderless)
                        }

                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if isTestRecording {
                    AudioVisualizationView(
                        level: testAudioLevel,
                        barCount: 20,
                        barWidth: 3,
                        spacing: 2
                    )
                    .frame(height: 30)
                    .tint(.accentColor)
                }

                Text("Record a short clip to preview how silence trimming affects your audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            inputDevices = AudioDeviceManager.availableInputDevices()
        }
    }

    private func startTestRecording() {
        stopTestPlayback()
        testRawAudio = nil
        testProcessedAudio = nil

        let recorder = AudioRecorder()
        do {
            try recorder.startRecording { level in
                testAudioLevel = level
            }
            testRecorder = recorder
            isTestRecording = true
        } catch {
            Log.audio.error("Test recording failed to start: \(error)")
        }
    }

    private func stopTestRecording() {
        guard let recorder = testRecorder else { return }
        let rawAudio = recorder.stopRecording()
        testRecorder = nil
        isTestRecording = false
        testAudioLevel = 0
        testRawAudio = rawAudio

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let processed = AudioProcessor.trimSilence(from: rawAudio)
            DispatchQueue.main.async {
                testProcessedAudio = processed
                isProcessing = false
            }
        }
    }

    private func playTestAudio(_ data: Data, source: TestPlaybackSource) {
        if playingSource == source {
            stopTestPlayback()
            return
        }
        stopTestPlayback()

        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = AudioTabPlayerDelegate {
                playingSource = nil
                testPlayer = nil
                testPlayerDelegate = nil
            }
            player.delegate = delegate
            testPlayer = player
            testPlayerDelegate = delegate
            playingSource = source
            player.play()
        } catch {
            Log.audio.error("Test playback failed: \(error)")
            playingSource = nil
        }
    }

    private func stopTestPlayback() {
        testPlayer?.stop()
        testPlayer = nil
        testPlayerDelegate = nil
        playingSource = nil
    }

    private func wavDurationString(_ data: Data) -> String {
        guard data.count > 44 else { return "0.0s" }
        let dataBytes = data.count - 44 // WAV header is 44 bytes
        let bytesPerSecond = 16000 * 2 // 16kHz, 16-bit mono
        let duration = Double(dataBytes) / Double(bytesPerSecond)
        return String(format: "%.1fs", duration)
    }
}

enum TestPlaybackSource {
    case original
    case processed
}

final class AudioTabPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish() }
    }
}
