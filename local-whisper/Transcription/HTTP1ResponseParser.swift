import Foundation

/// Incremental HTTP/1.1 response parser for `HTTP1Transport`. Pure value type with no I/O, so
/// the framing rules (Content-Length, chunked, and close-delimited bodies) are unit-testable.
struct HTTP1ResponseParser {
    struct Response: Equatable {
        let statusCode: Int
        /// Header names are lowercased.
        let headers: [String: String]
        let body: Data
    }

    enum ParseError: Error, Equatable {
        case malformed
    }

    private enum Framing {
        case contentLength(Int)
        case chunked
        case untilClose
    }

    private struct Head {
        let statusCode: Int
        let headers: [String: String]
        let framing: Framing
    }

    private var buffer: [UInt8] = []
    private var head: Head?
    /// Index into `buffer` where the body of the current response starts.
    private var bodyStart = 0

    /// Feeds received bytes. Returns the response once it is complete, `nil` if more bytes are needed.
    mutating func append(_ data: Data) throws -> Response? {
        buffer.append(contentsOf: data)
        return try parse(atEOF: false)
    }

    /// Signals that the peer closed the connection. Returns the response if the bytes received so
    /// far form a complete one (close-delimited bodies only complete here), `nil` if truncated.
    mutating func finish() throws -> Response? {
        try parse(atEOF: true)
    }

    private mutating func parse(atEOF: Bool) throws -> Response? {
        while head == nil {
            guard let end = Self.find([13, 10, 13, 10], in: buffer, from: 0) else { return nil }
            let parsed = try Self.parseHead(buffer[..<end])
            // Interim 1xx responses (e.g. 100 Continue) carry no body; skip to the final response.
            if (100..<200).contains(parsed.statusCode) {
                buffer.removeSubrange(..<(end + 4))
                continue
            }
            head = parsed
            bodyStart = end + 4
        }
        guard let head else { return nil }

        let body: [UInt8]
        switch head.framing {
        case .contentLength(let length):
            guard buffer.count - bodyStart >= length else { return nil }
            body = Array(buffer[bodyStart..<(bodyStart + length)])
        case .chunked:
            guard let decoded = try Self.decodeChunked(buffer, from: bodyStart) else { return nil }
            body = decoded
        case .untilClose:
            guard atEOF else { return nil }
            body = Array(buffer[bodyStart...])
        }
        return Response(statusCode: head.statusCode, headers: head.headers, body: Data(body))
    }

    private static func parseHead(_ bytes: ArraySlice<UInt8>) throws -> Head {
        guard let text = String(bytes: bytes, encoding: .isoLatin1) else { throw ParseError.malformed }
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusLine[1]) else {
            throw ParseError.malformed
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let framing: Framing
        if statusCode == 204 || statusCode == 304 {
            framing = .contentLength(0)
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunked
        } else if let lengthHeader = headers["content-length"] {
            guard let length = Int(lengthHeader), length >= 0 else { throw ParseError.malformed }
            framing = .contentLength(length)
        } else {
            framing = .untilClose
        }
        return Head(statusCode: statusCode, headers: headers, framing: framing)
    }

    /// Decodes a chunked body starting at `start`. Returns `nil` while the terminating chunk (and
    /// trailer section) hasn't fully arrived yet.
    private static func decodeChunked(_ buffer: [UInt8], from start: Int) throws -> [UInt8]? {
        var body: [UInt8] = []
        var index = start
        while true {
            guard let lineEnd = find([13, 10], in: buffer, from: index) else { return nil }
            guard let line = String(bytes: buffer[index..<lineEnd], encoding: .isoLatin1) else {
                throw ParseError.malformed
            }
            let sizeField = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw ParseError.malformed
            }
            index = lineEnd + 2

            if size == 0 {
                // Skip optional trailer fields up to the empty line that ends the message.
                while true {
                    guard let trailerEnd = find([13, 10], in: buffer, from: index) else { return nil }
                    if trailerEnd == index { return body }
                    index = trailerEnd + 2
                }
            }

            guard buffer.count >= index + size + 2 else { return nil }
            guard buffer[index + size] == 13, buffer[index + size + 1] == 10 else { throw ParseError.malformed }
            body.append(contentsOf: buffer[index..<(index + size)])
            index += size + 2
        }
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        for index in start...(bytes.count - pattern.count)
        where bytes[index] == pattern[0] && bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
            return index
        }
        return nil
    }
}
