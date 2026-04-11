import Foundation

struct ExcludedContextApp: Codable, Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
}
