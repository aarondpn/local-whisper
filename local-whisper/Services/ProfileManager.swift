import AppKit
import Foundation

@Observable
final class ProfileManager {
    var profiles: [AppProfile] = []

    init() {
        loadProfiles()
    }

    func profile(for bundleID: String) -> AppProfile? {
        profiles.first { $0.appBundleID == bundleID }
    }

    struct ResolvedSettings {
        let provider: ProviderType
        let language: String
        let prompt: String?
    }

    func resolveSettings(for bundleID: String?, globalProvider: ProviderType, globalLanguage: String) -> ResolvedSettings {
        guard let bundleID, let profile = profile(for: bundleID) else {
            return ResolvedSettings(provider: globalProvider, language: globalLanguage, prompt: nil)
        }

        let provider = ProviderType(rawValue: profile.provider) ?? globalProvider
        let language = profile.language
        let prompt: String? = profile.prompt.isEmpty ? nil : profile.prompt

        return ResolvedSettings(provider: provider, language: language, prompt: prompt)
    }

    func activeProfileName(for bundleID: String?) -> String? {
        guard let bundleID, let profile = profile(for: bundleID) else { return nil }
        let languageName = Self.languageDisplayName(for: profile.language)
        return "\(profile.appName) (\(languageName))"
    }

    func addProfile(_ profile: AppProfile) {
        profiles.append(profile)
        saveProfiles()
    }

    func updateProfile(_ profile: AppProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveProfiles()
        }
    }

    func deleteProfile(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.appProfiles) else { return }
        do {
            profiles = try JSONDecoder().decode([AppProfile].self, from: data)
        } catch {
            Log.coordinator.error("Failed to load app profiles: \(error)")
        }
    }

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: SettingsKeys.appProfiles)
        } catch {
            Log.coordinator.error("Failed to save app profiles: \(error)")
        }
    }

    static func languageDisplayName(for code: String) -> String {
        switch code {
        case "auto": return "Auto-detect"
        case "en": return "English"
        case "de": return "German"
        case "fr": return "French"
        case "es": return "Spanish"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "nl": return "Dutch"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "ko": return "Korean"
        default: return code
        }
    }
}
