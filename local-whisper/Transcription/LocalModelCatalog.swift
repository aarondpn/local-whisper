import Foundation

/// Which inference engine runs a given local model.
enum LocalModelEngine {
    case whisperKit
    case parakeet
}

/// One selectable local model. `id` is the value stored in the `localModelName`
/// UserDefaults key — Whisper IDs keep their historical raw names so existing
/// installs resolve unchanged.
struct LocalModelDescriptor: Identifiable, Equatable {
    let id: String
    let displayName: String
    let engine: LocalModelEngine
    let streamingCapable: Bool
    /// Hugging Face repo + filename for GGUF models (parakeet engine only).
    let hfRepo: String?
    let hfFilename: String?
}

enum LocalModelCatalog {
    static let all: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            id: "tiny", displayName: "Tiny (~75 MB)",
            engine: .whisperKit, streamingCapable: false, hfRepo: nil, hfFilename: nil),
        LocalModelDescriptor(
            id: "base", displayName: "Base (~140 MB)",
            engine: .whisperKit, streamingCapable: false, hfRepo: nil, hfFilename: nil),
        LocalModelDescriptor(
            id: "small", displayName: "Small (~460 MB)",
            engine: .whisperKit, streamingCapable: false, hfRepo: nil, hfFilename: nil),
        LocalModelDescriptor(
            id: "large-v3_turbo", displayName: "Large v3 Turbo (~1.5 GB)",
            engine: .whisperKit, streamingCapable: false, hfRepo: nil, hfFilename: nil),
        LocalModelDescriptor(
            id: "large-v3", displayName: "Large v3 (~3 GB)",
            engine: .whisperKit, streamingCapable: false, hfRepo: nil, hfFilename: nil),
        LocalModelDescriptor(
            id: "nemotron-3.5-asr-streaming-0.6b-q8_0",
            displayName: "Nemotron Streaming 0.6B (~1 GB) — live transcription",
            engine: .parakeet, streamingCapable: true,
            hfRepo: "mudler/parakeet-cpp-gguf",
            hfFilename: "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"),
    ]

    static func descriptor(for id: String) -> LocalModelDescriptor {
        all.first { $0.id == id } ?? all.first { $0.id == "large-v3_turbo" }!
    }

    /// The model currently selected in Settings.
    static var selected: LocalModelDescriptor {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.localModelName) ?? "large-v3_turbo"
        return descriptor(for: id)
    }
}
