import Foundation

struct TranscriptionEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let provider: String
    let audioDurationSeconds: Double
    let transcriptionLatencySeconds: Double
    let wordCount: Int
    let characterCount: Int
    let targetAppBundleID: String?
    // Optional so existing statistics.json (which lacks this field) still decodes.
    let text: String?

    init(
        provider: String,
        audioDurationSeconds: Double,
        transcriptionLatencySeconds: Double,
        wordCount: Int,
        characterCount: Int,
        targetAppBundleID: String?,
        text: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.provider = provider
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptionLatencySeconds = transcriptionLatencySeconds
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.targetAppBundleID = targetAppBundleID
        self.text = text
    }
}
