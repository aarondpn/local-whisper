import Foundation

/// Shared transport for the OpenAI-compatible `/audio/transcriptions` endpoint used by both
/// the Groq and OpenAI providers. Builds the multipart request, performs it, and parses the
/// plain-text response.
///
/// Crucially it retries *transient* transport failures. A real recording captured a
/// `NSPOSIXErrorDomain Code=40` ("Message too long" / `EMSGSIZE`) on a longer upload — the
/// kernel refusing to send a full-size packet because the IPv6 path MTU was momentarily
/// blackholed (PMTU discovery losing ICMPv6 "Packet Too Big"). That blip was intermittent:
/// the identical upload succeeded seconds later. Without a retry it surfaced as a hard red
/// transcription error. We must never turn a momentary network hiccup into a user-facing
/// failure, so transient errors get a bounded retry on a *fresh* connection. Genuine API
/// errors (auth, bad request, rate limit) are returned immediately and never retried.
enum WhisperHTTPClient {
    /// 1 initial attempt + 2 retries.
    private static let maxAttempts = 3
    private static let retryBackoff: Duration = .milliseconds(400)

    static func transcribe(
        endpoint: URL,
        apiKey: String,
        model: String,
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> String {
        var formData = MultipartFormData()
        formData.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        formData.addField(name: "model", value: model)
        formData.addField(name: "response_format", value: "text")

        if let language, language != "auto" {
            formData.addField(name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            formData.addField(name: "prompt", value: prompt)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = formData.finalize()
        request.timeoutInterval = 30

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await send(request)
            } catch {
                guard attempt < maxAttempts, isTransient(error) else { throw error }
                try Task.checkCancellation()
                Log.coordinator.warning(
                    "Transient network error on attempt \(attempt)/\(maxAttempts), retrying: \(error)"
                )
                try await Task.sleep(for: retryBackoff)
                try Task.checkCancellation()
            }
        }
    }

    /// One request/response round-trip. Uses an ephemeral session per attempt so a retry never
    /// reuses a pooled connection that's wedged on a broken path — the fresh connection re-runs
    /// Happy Eyeballs (and may fall back from IPv6 to IPv4) and re-does path-MTU discovery.
    private static func send(_ request: URLRequest) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TranscriptionError.invalidResponse
        }
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResponse
        }
        return text
    }

    /// Whether an error is a transport-level blip worth retrying. Deliberately excludes
    /// `TranscriptionError` cases (API/empty/invalid responses) — those are not network hiccups
    /// and retrying them just wastes time or hammers the API.
    private static func isTransient(_ error: Error) -> Bool {
        if error is TranscriptionError { return false }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                 .resourceUnavailable:
                return true
            default:
                break
            }
        }

        // The observed failure was `Domain=NSPOSIXErrorDomain Code=40` (EMSGSIZE) thrown
        // straight from URLSession, sometimes nested under another error. Match it directly,
        // and check one level of underlying error for the wrapped variants.
        if matchesEMSGSIZE(error as NSError) { return true }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
           matchesEMSGSIZE(underlying) {
            return true
        }
        return false
    }

    /// `EMSGSIZE` == POSIX error 40 ("Message too long").
    private static func matchesEMSGSIZE(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.EMSGSIZE.rawValue)
    }
}
