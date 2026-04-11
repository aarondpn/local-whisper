import Foundation

enum SettingsKeys {
    static let selectedProvider = "selectedProvider"
    static let language = "language"
    static let openAIAPIKey = "openAIAPIKey"
    static let groqAPIKey = "groqAPIKey"
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"
    static let whisperModel = "whisperModel"
    static let localModelDownloaded = "localModelDownloaded"
    static let trimSilenceEnabled = "trimSilenceEnabled"
    static let silenceThresholdDB = "silenceThresholdDB"
    static let silenceMinDuration = "silenceMinDuration"
    static let minRecordingDuration = "minRecordingDuration"
    static let muteSystemAudioDuringRecording = "muteSystemAudioDuringRecording"
    static let selectedInputDeviceUID = "selectedInputDeviceUID"
    static let boostInputVolumeDuringRecording = "boostInputVolumeDuringRecording"
    static let appProfiles = "appProfiles"
    static let localModelName = "localModelName"
    static let pressEnterAfterPaste = "pressEnterAfterPaste"
    static let useDynamicContext = "useDynamicContext"
    static let useWindowTitleFallback = "useWindowTitleFallback"
    static let excludedContextApps = "excludedContextApps"
    static let overlayPosition = "overlayPosition"
    static let overlayCustomX = "overlayCustomX"
    static let overlayCustomY = "overlayCustomY"
    static let overlayCustomPositionSet = "overlayCustomPositionSet"
    static let hudTheme = "hudTheme"
    static let hudEnabled = "hudEnabled"
    static let hudShowTimer = "hudShowTimer"
    static let hudShowIndicator = "hudShowIndicator"
    static let hudSize = "hudSize"

    static let prodBundleID = "com.aarondpn.local-whisper"

    static func registerDefaults() {
        // In debug builds, fall back to prod UserDefaults for API keys and settings
        #if DEBUG
        if Bundle.main.bundleIdentifier != prodBundleID {
            UserDefaults.standard.addSuite(named: prodBundleID)
        }
        #endif

        UserDefaults.standard.register(defaults: [
            selectedProvider: ProviderType.groq.rawValue,
            language: "auto",
            hotkeyKeyCode: 999,
            hotkeyModifiers: 0,
            whisperModel: "base",
            localModelDownloaded: false,
            trimSilenceEnabled: true,
            silenceThresholdDB: -45.0,
            silenceMinDuration: 0.05,
            minRecordingDuration: 0.3,
            muteSystemAudioDuringRecording: false,
            selectedInputDeviceUID: "",
            boostInputVolumeDuringRecording: false,
            localModelName: "large-v3_turbo",
            pressEnterAfterPaste: false,
            useDynamicContext: true,
            useWindowTitleFallback: true,
            hudTheme: HUDThemeID.midnight.rawValue,
            hudEnabled: true,
            hudShowTimer: true,
            hudShowIndicator: false,
            hudSize: HUDSize.regular.rawValue,
        ])
    }
}
