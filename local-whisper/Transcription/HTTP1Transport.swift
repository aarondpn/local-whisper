import Foundation
import Network

/// Minimal HTTP/1.1-over-TCP client: `WhisperHTTPClient`'s fallback transport.
///
/// URLSession speaks HTTP/3 (QUIC) to any host that advertises it — api.groq.com does, via its
/// DNS HTTPS record — and has no public switch to opt out. On a path whose MTU is below 1500
/// (e.g. a PPPoE DSL line at 1492), Apple's QUIC stack wedges larger uploads: it probes 1500-byte
/// packets, the kernel rejects them with `EMSGSIZE` once it has learned the smaller path MTU, and
/// the frames it already built never fit into the shrunken packets again. The body stops moving,
/// and after ~15 s the server resets the stream (Groq logs a 499, we see `-1005`). Anything past
/// ~10 s of audio hit this every time, and retrying over QUIC reproduces it deterministically.
///
/// TCP doesn't have this problem (the MSS is negotiated, and routers clamp it), so this sends the
/// same request as plain HTTP/1.1 over a TLS/TCP `NWConnection`. One request per connection
/// (`Connection: close`), no redirects, no compression: exactly what the Whisper endpoint needs.
enum HTTP1Transport {
    static func send(_ request: URLRequest, timeout: Duration) async throws -> HTTP1ResponseParser.Response {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            throw URLError(.unsupportedURL)
        }
        let exchange = Exchange(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
            message: serialize(request, url: url, host: host),
            timeout: timeout
        )
        return try await exchange.run()
    }

    private static func serialize(_ request: URLRequest, url: URL, host: String) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?\(query)" }

        let body = request.httpBody ?? Data()
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
        head += "Host: \(url.port.map { "\(host):\($0)" } ?? host)\r\n"
        let managed: Set<String> = ["host", "content-length", "connection"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !managed.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var message = Data(head.utf8)
        message.append(body)
        return message
    }

    /// One connection, one request/response. All state is confined to `queue`; the continuation
    /// is resumed exactly once by `finish`.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let message: Data
        private let timeout: Duration
        private let queue = DispatchQueue(label: "com.aarondpn.local-whisper.http1")
        private var continuation: CheckedContinuation<HTTP1ResponseParser.Response, Error>?
        private var parser = HTTP1ResponseParser()
        private var cancelled = false

        init(endpoint: NWEndpoint, message: Data, timeout: Duration) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 10
            self.connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
            self.message = message
            self.timeout = timeout
        }

        func run() async throws -> HTTP1ResponseParser.Response {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { self.start(continuation) }
                }
            } onCancel: {
                queue.async {
                    self.cancelled = true
                    self.finish(.failure(CancellationError()))
                }
            }
        }

        private func start(_ continuation: CheckedContinuation<HTTP1ResponseParser.Response, Error>) {
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation

            let (seconds, attoseconds) = timeout.components
            let interval = Double(seconds) + Double(attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.finish(.failure(URLError(.timedOut)))
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendRequest()
                case .waiting(let error), .failed(let error):
                    // `.waiting` means no usable path right now. Fail fast instead of waiting
                    // for one; the caller decides whether to retry.
                    self.finish(.failure(error))
                case .cancelled:
                    self.finish(.failure(URLError(.cancelled)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        private func sendRequest() {
            connection.send(content: message, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(.failure(error)) }
            })
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, self.continuation != nil else { return }
                do {
                    if let data, !data.isEmpty, let response = try self.parser.append(data) {
                        self.finish(.success(response))
                        return
                    }
                    if let error {
                        self.finish(.failure(error))
                    } else if isComplete {
                        if let response = try self.parser.finish() {
                            self.finish(.success(response))
                        } else {
                            self.finish(.failure(URLError(.networkConnectionLost)))
                        }
                    } else {
                        self.receive()
                    }
                } catch {
                    self.finish(.failure(URLError(.badServerResponse)))
                }
            }
        }

        private func finish(_ result: Result<HTTP1ResponseParser.Response, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }
}
