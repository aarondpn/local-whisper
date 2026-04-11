import Foundation

struct AppProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var appBundleID: String
    var appName: String
    var language: String
    var provider: String
    var prompt: String

    init(id: UUID = UUID(), appBundleID: String, appName: String, language: String = "auto", provider: String = "default", prompt: String = "") {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.language = language
        self.provider = provider
        self.prompt = prompt
    }
}
