import Foundation
import Network
import os

/// Shared transport for the OpenAI-compatible `/audio/transcriptions` endpoint used by both
/// the Groq and OpenAI providers. Builds the multipart request, performs it, and parses the
/// plain-text response.
///
/// Every request is a hedged race between two transports (see `HedgedRequest`):
///
/// - `URLSession`, which uses HTTP/3 (QUIC) whenever the server advertises it. That's normally
///   the fastest option, but on a path with an MTU below 1500 (e.g. PPPoE DSL at 1492) Apple's
///   QUIC stack wedges any upload longer than a few hundred milliseconds. The recorded symptom
///   was `NSPOSIXErrorDomain Code=40` (`EMSGSIZE`) in the network logs, then silence until the
///   server reset the stream ~15 s later (`-1005` here, a 499 in Groq's dashboard). That happened
///   on every attempt, so retrying over QUIC never helps. Details in `HTTP1Transport`.
/// - `HTTP1Transport`, plain HTTP/1.1 over TCP, which is immune to that failure.
///
/// The preferred transport goes first. The other one starts if the first fails, or if it hasn't
/// answered within a delay scaled to the upload size. When TCP wins, it becomes the preferred
/// transport for a while, so a network that breaks QUIC costs one hedge delay instead of one
/// per dictation. Genuine API errors (auth, bad request, rate limit) end the race immediately and
/// are never retried. Transport failures on both legs get one more round.
enum WhisperHTTPClient {
    private enum Transport: String {
        case urlSession = "URLSession"
        case http1 = "HTTP/1.1"
    }

    /// 1 initial round + 1 retry. Each round already tries both transports.
    private static let maxRounds = 2
    private static let retryBackoff: Duration = .milliseconds(400)
    private static let requestTimeout: TimeInterval = 30
    /// Overall deadline for the TCP fallback. It reports no progress we could use as an idle
    /// timer, so give it enough room for a long upload on a slow uplink.
    private static let http1Timeout: Duration = .seconds(60)
    /// How long the HTTP/1.1 transport stays preferred after it won a race.
    private static let http1PreferenceLifetime: Duration = .seconds(60 * 60)
    private static let http1PreferredUntil = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

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
        request.timeoutInterval = requestTimeout

        let bodyBytes = request.httpBody?.count ?? 0
        let delay = hedgeDelay(forBodyBytes: bodyBytes)
        let primary: Transport = prefersHTTP1() ? .http1 : .urlSession
        let secondary: Transport = primary == .urlSession ? .http1 : .urlSession
        let finalRequest = request

        var round = 0
        while true {
            round += 1
            do {
                let (text, leg) = try await HedgedRequest.run(
                    hedgeAfter: delay,
                    isFinal: { $0 is TranscriptionError },
                    primary: { try await send(finalRequest, via: primary) },
                    secondary: { try await send(finalRequest, via: secondary) },
                    onHedge: {
                        Log.network.warning(
                            "No response via \(primary.rawValue) after \(delay) for \(bodyBytes) bytes, racing \(secondary.rawValue)"
                        )
                    }
                )
                let winner = leg == .primary ? primary : secondary
                recordWinner(winner)
                if winner != primary {
                    Log.network.warning("Fallback transport \(winner.rawValue) won the race")
                }
                return text
            } catch {
                guard round < maxRounds, isTransient(error) else { throw error }
                try Task.checkCancellation()
                Log.network.warning(
                    "Transient network error on round \(round)/\(maxRounds), retrying: \(error)"
                )
                try await Task.sleep(for: retryBackoff)
                try Task.checkCancellation()
            }
        }
    }

    /// How long the primary transport gets before the other one is started alongside it: a
    /// fixed allowance for connection setup and server processing, plus 1 s per MB of upload.
    /// A healthy upload of a 2-minute recording (~3.4 MB) measured ~3 s end to end. Starting the
    /// hedge too early only costs a duplicate request; starting it too late costs the user waiting.
    static func hedgeDelay(forBodyBytes bytes: Int) -> Duration {
        .milliseconds(1500 + bytes / 1000)
    }

    private static func prefersHTTP1() -> Bool {
        http1PreferredUntil.withLock { until in
            guard let until else { return false }
            return ContinuousClock.now < until
        }
    }

    private static func recordWinner(_ transport: Transport) {
        http1PreferredUntil.withLock { until in
            until = transport == .http1 ? ContinuousClock.now.advanced(by: http1PreferenceLifetime) : nil
        }
    }

    private static func send(_ request: URLRequest, via transport: Transport) async throws -> String {
        switch transport {
        case .urlSession:
            return try await sendViaURLSession(request)
        case .http1:
            let response = try await HTTP1Transport.send(request, timeout: http1Timeout)
            return try decode(statusCode: response.statusCode, data: response.body)
        }
    }

    /// Uses an ephemeral session per attempt so a retry never reuses a pooled connection that's
    /// wedged on a broken path.
    private static func sendViaURLSession(_ request: URLRequest) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        return try decode(statusCode: httpResponse.statusCode, data: data)
    }

    private static func decode(statusCode: Int, data: Data) throws -> String {
        guard statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("HTTP \(statusCode): \(errorBody)")
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TranscriptionError.invalidResponse
        }
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResponse
        }
        return text
    }

    /// Whether an error is a transport-level blip worth another round. Deliberately excludes
    /// `TranscriptionError` cases (API/empty/invalid responses). Those aren't network hiccups,
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

        // Errors from `HTTP1Transport`'s NWConnection. TLS failures aren't blips; socket-level
        // and DNS failures are.
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return code != .ECANCELED
            case .dns:
                return true
            default:
                return false
            }
        }

        // `EMSGSIZE` thrown straight from URLSession, sometimes nested under another error.
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
