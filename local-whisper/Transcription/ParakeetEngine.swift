import Foundation
import ParakeetCAPI

enum ParakeetError: LocalizedError {
    case loadFailed(String)
    case notLoaded
    case streamBeginFailed(String)
    case streamActive
    case transcribeFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .notLoaded: return "Model not downloaded. Please download it in Settings first."
        case .streamBeginFailed(let msg): return "Failed to start streaming: \(msg)"
        case .streamActive: return "A streaming session is already active"
        case .transcribeFailed(let msg): return "Transcription failed: \(msg)"
        }
    }
}

/// Serializes all access to the parakeet.cpp C API. The context wraps one loaded
/// GGUF model; at most one streaming session exists at a time. Strings returned
/// by the C API are copied and released with parakeet_capi_free_string before
/// crossing the actor boundary.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    private var stream: OpaquePointer?

    private var lastError: String {
        guard let ctx else { return "no context" }
        return String(cString: parakeet_capi_last_error(ctx))
    }

    var isLoaded: Bool { ctx != nil }

    /// The decoder occasionally emits its language-ID token in the text stream
    /// (observed as a trailing "<en-US>" from stream_finalize). Strip them.
    private static let languageTagPattern = /<[a-z]{2,3}(?:-[A-Z]{2})?>/

    private static func stripLanguageTags(_ text: String) -> String {
        text.replacing(languageTagPattern, with: "")
    }

    func load(modelPath: String) throws {
        if ctx != nil, loadedModelPath == modelPath { return }
        unload()
        Log.parakeet.info("Loading GGUF model: \(modelPath)")
        let start = Date()
        guard let loaded = parakeet_capi_load(modelPath) else {
            throw ParakeetError.loadFailed("parakeet_capi_load returned NULL")
        }
        ctx = loaded
        loadedModelPath = modelPath
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
        Log.parakeet.info("Model loaded in \(elapsed)s (ABI v\(parakeet_capi_abi_version()))")
    }

    func unload() {
        if stream != nil {
            parakeet_capi_stream_free(stream)
            stream = nil
        }
        if let ctx {
            parakeet_capi_free(ctx)
        }
        ctx = nil
        loadedModelPath = nil
    }

    /// One-shot transcription of 16 kHz mono Float32 PCM.
    /// `language` is a locale string ("en", "de", …); nil means auto-detect.
    func transcribe(samples: [Float], language: String?) throws -> String {
        guard let ctx else { throw ParakeetError.notLoaded }
        let lang = language ?? "auto"
        guard let cstr = samples.withUnsafeBufferPointer({ buf in
            parakeet_capi_transcribe_pcm_lang(ctx, buf.baseAddress, Int32(buf.count), 16000, 0, lang)
        }) else {
            throw ParakeetError.transcribeFailed(lastError)
        }
        defer { parakeet_capi_free_string(cstr) }
        return Self.stripLanguageTags(String(cString: cstr))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming

    func beginStream(language: String?) throws {
        guard let ctx else { throw ParakeetError.notLoaded }
        guard stream == nil else { throw ParakeetError.streamActive }
        let lang = language ?? "auto"
        guard let s = parakeet_capi_stream_begin_lang(ctx, lang) else {
            throw ParakeetError.streamBeginFailed(lastError)
        }
        stream = s
    }

    /// Feed 16 kHz mono PCM; returns the newly finalized text ("" when none).
    func feed(_ samples: [Float]) throws -> String {
        guard let stream else { throw ParakeetError.notLoaded }
        var eou: Int32 = 0
        guard let cstr = samples.withUnsafeBufferPointer({ buf in
            parakeet_capi_stream_feed(stream, buf.baseAddress, Int32(buf.count), &eou)
        }) else {
            throw ParakeetError.transcribeFailed(lastError)
        }
        defer { parakeet_capi_free_string(cstr) }
        return Self.stripLanguageTags(String(cString: cstr))
    }

    /// Flush the end-of-stream tail and end the session; returns the final increment.
    func finalizeStream() throws -> String {
        guard let stream else { throw ParakeetError.notLoaded }
        defer {
            parakeet_capi_stream_free(stream)
            self.stream = nil
        }
        guard let cstr = parakeet_capi_stream_finalize(stream) else {
            throw ParakeetError.transcribeFailed(lastError)
        }
        defer { parakeet_capi_free_string(cstr) }
        return Self.stripLanguageTags(String(cString: cstr))
    }

    /// Tear down the session without caring about remaining text.
    func abortStream() {
        if let stream {
            parakeet_capi_stream_free(stream)
            self.stream = nil
        }
    }
}
