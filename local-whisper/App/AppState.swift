import AppKit
import AVFoundation
import SwiftUI

enum LocalModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

enum OverlayPosition: String, CaseIterable, Identifiable {
    case bottom, center, top, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bottom: return "Bottom Center"
        case .center: return "Screen Center"
        case .top: return "Top Center"
        case .custom: return "Custom"
        }
    }
}

@Observable
final class AppState {
    // Stored properties below read UserDefaults in their initializers. This property
    // initializer runs first (declaration order) so later reads see registered defaults
    // instead of 0/false/nil. AppDelegate also calls registerDefaults(), which is
    // idempotent.
    @ObservationIgnored private let _defaultsRegistered: Void = SettingsKeys.registerDefaults()

    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var statusText = "Ready"
    var lastTranscription = ""
    var lastPrompt: String?
    var lastAudioData: Data?
    var lastContextAppBundleID: String?
    var lastContextAppName: String?
    var errorMessage: String?
    var errorTick: Int = 0
    var silentInputWarning = false
    var requestedSettingsTab: SettingsTab?
    var localModelState: LocalModelState = .notLoaded

    @ObservationIgnored var cancelCurrentTranscription: (@MainActor () -> Void)?

    func reportError(_ message: String) {
        errorMessage = message
        errorTick &+= 1
    }

    func clearError() {
        errorMessage = nil
    }

    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: AudioPlayerDelegate?
    var isPlayingLastAudio = false

    let profileManager = ProfileManager()

    var activeProfileName: String? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return profileManager.activeProfileName(for: bundleID)
    }

    func playLastAudio() {
        guard let data = lastAudioData else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = AudioPlayerDelegate { [weak self] in
                self?.isPlayingLastAudio = false
                self?.audioPlayer = nil
                self?.playerDelegate = nil
            }
            player.delegate = delegate
            self.audioPlayer = player
            self.playerDelegate = delegate
            isPlayingLastAudio = true
            player.play()
        } catch {
            Log.coordinator.error("Failed to play audio: \(error)")
            isPlayingLastAudio = false
        }
    }

    func stopLastAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        isPlayingLastAudio = false
    }

    var selectedProvider: ProviderType = {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.selectedProvider) ?? ProviderType.groq.rawValue
        return ProviderType(rawValue: raw) ?? .groq
    }() {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: SettingsKeys.selectedProvider) }
    }

    var language: String = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "auto" {
        didSet { UserDefaults.standard.set(language, forKey: SettingsKeys.language) }
    }

    var muteSystemAudioDuringRecording: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.muteSystemAudioDuringRecording) {
        didSet { UserDefaults.standard.set(muteSystemAudioDuringRecording, forKey: SettingsKeys.muteSystemAudioDuringRecording) }
    }

    var boostInputVolumeDuringRecording: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.boostInputVolumeDuringRecording) {
        didSet { UserDefaults.standard.set(boostInputVolumeDuringRecording, forKey: SettingsKeys.boostInputVolumeDuringRecording) }
    }

    var minRecordingDuration: Double = UserDefaults.standard.double(forKey: SettingsKeys.minRecordingDuration) {
        didSet { UserDefaults.standard.set(minRecordingDuration, forKey: SettingsKeys.minRecordingDuration) }
    }

    var pressEnterAfterPaste: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.pressEnterAfterPaste) {
        didSet { UserDefaults.standard.set(pressEnterAfterPaste, forKey: SettingsKeys.pressEnterAfterPaste) }
    }

    var hotkeyConfiguration: HotkeyConfiguration = .load() {
        didSet { hotkeyConfiguration.save() }
    }

    var overlayPosition: OverlayPosition = {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.overlayPosition) ?? OverlayPosition.bottom.rawValue
        return OverlayPosition(rawValue: raw) ?? .bottom
    }() {
        didSet { UserDefaults.standard.set(overlayPosition.rawValue, forKey: SettingsKeys.overlayPosition) }
    }

    var overlayCustomX: Double = UserDefaults.standard.double(forKey: SettingsKeys.overlayCustomX) {
        didSet { UserDefaults.standard.set(overlayCustomX, forKey: SettingsKeys.overlayCustomX) }
    }

    var overlayCustomY: Double = UserDefaults.standard.double(forKey: SettingsKeys.overlayCustomY) {
        didSet { UserDefaults.standard.set(overlayCustomY, forKey: SettingsKeys.overlayCustomY) }
    }

    var overlayCustomPositionSet: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.overlayCustomPositionSet) {
        didSet { UserDefaults.standard.set(overlayCustomPositionSet, forKey: SettingsKeys.overlayCustomPositionSet) }
    }

    var isOverlayPositioningSession: Bool = false

    @ObservationIgnored weak var overlayPanel: RecordingOverlayPanel?

    var hudThemeID: HUDThemeID = {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.hudTheme) ?? HUDThemeID.midnight.rawValue
        return HUDThemeID(rawValue: raw) ?? .midnight
    }() {
        didSet { UserDefaults.standard.set(hudThemeID.rawValue, forKey: SettingsKeys.hudTheme) }
    }

    var hudTheme: HUDTheme { HUDTheme.theme(for: hudThemeID) }

    var hudEnabled: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.hudEnabled) {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: SettingsKeys.hudEnabled) }
    }

    var hudShowTimer: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.hudShowTimer) {
        didSet { UserDefaults.standard.set(hudShowTimer, forKey: SettingsKeys.hudShowTimer) }
    }

    var hudShowIndicator: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.hudShowIndicator) {
        didSet { UserDefaults.standard.set(hudShowIndicator, forKey: SettingsKeys.hudShowIndicator) }
    }

    var hudSize: HUDSize = {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.hudSize) ?? HUDSize.regular.rawValue
        return HUDSize(rawValue: raw) ?? .regular
    }() {
        didSet { UserDefaults.standard.set(hudSize.rawValue, forKey: SettingsKeys.hudSize) }
    }

    var providerStatusText: String {
        switch selectedProvider {
        case .openAI:
            let hasKey = !(UserDefaults.standard.string(forKey: SettingsKeys.openAIAPIKey)?.isEmpty ?? true)
            return hasKey ? "OpenAI Whisper" : "OpenAI (No API Key)"
        case .groq:
            let hasKey = !(UserDefaults.standard.string(forKey: SettingsKeys.groqAPIKey)?.isEmpty ?? true)
            return hasKey ? "Groq Whisper" : "Groq (No API Key)"
        case .local:
            switch localModelState {
            case .notLoaded: return "Local (No Model)"
            case .downloading(let progress): return "Local (Downloading \(Int(progress * 100))%)"
            case .loading: return "Local (Loading...)"
            case .ready: return "Local (WhisperKit)"
            case .error(let msg): return "Local (Error: \(msg))"
            }
        }
    }
}

private class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish() }
    }
}
