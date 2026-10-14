import XCTest

/// `HTTP1ResponseParser.swift` is compiled straight into this bundle (target membership), so
/// these run as plain logic tests without launching the app.
final class HTTP1ResponseParserTests: XCTestCase {
    private func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testContentLengthBody() throws {
        var parser = HTTP1ResponseParser()
        let response = try XCTUnwrap(parser.append(bytes(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world"
        )))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/plain")
        XCTAssertEqual(response.body, bytes("hello world"))
    }

    func testContentLengthBodyArrivingInPieces() throws {
        var parser = HTTP1ResponseParser()
        XCTAssertNil(try parser.append(bytes("HTTP/1.1 200 OK\r\nContent-Len")))
        XCTAssertNil(try parser.append(bytes("gth: 5\r\n\r")))
        XCTAssertNil(try parser.append(bytes("\nhel")))
        let response = try XCTUnwrap(parser.append(bytes("lo")))
        XCTAssertEqual(response.body, bytes("hello"))
    }

    func testChunkedBody() throws {
        var parser = HTTP1ResponseParser()
        let response = try XCTUnwrap(parser.append(bytes(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
        )))
        XCTAssertEqual(response.body, bytes("hello world"))
    }

    func testChunkedBodyWaitsForTerminatorAndTrailers() throws {
        var parser = HTTP1ResponseParser()
        XCTAssertNil(try parser.append(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123")))
        XCTAssertNil(try parser.append(bytes("456789\r\n0\r\n")))
        XCTAssertNil(try parser.append(bytes("X-Trailer: yes\r\n")))
        let response = try XCTUnwrap(parser.append(bytes("\r\n")))
        XCTAssertEqual(response.body, bytes("0123456789"))
    }

    func testCloseDelimitedBodyCompletesOnlyAtEOF() throws {
        var parser = HTTP1ResponseParser()
        XCTAssertNil(try parser.append(bytes("HTTP/1.1 200 OK\r\n\r\npartial")))
        XCTAssertNil(try parser.append(bytes(" text")))
        let response = try XCTUnwrap(parser.finish())
        XCTAssertEqual(response.body, bytes("partial text"))
    }

    func testTruncatedResponseIsNilAtEOF() throws {
        var parser = HTTP1ResponseParser()
        XCTAssertNil(try parser.append(bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")))
        XCTAssertNil(try parser.finish(), "a body shorter than Content-Length is a lost connection, not a response")
    }

    func testInterimContinueResponseIsSkipped() throws {
        var parser = HTTP1ResponseParser()
        let response = try XCTUnwrap(parser.append(bytes(
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 401 Unauthorized\r\nContent-Length: 4\r\n\r\nnope"
        )))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(response.body, bytes("nope"))
    }

    func testNoContentHasEmptyBody() throws {
        var parser = HTTP1ResponseParser()
        let response = try XCTUnwrap(parser.append(bytes("HTTP/1.1 204 No Content\r\n\r\n")))
        XCTAssertEqual(response.body, Data())
    }

    func testMalformedStatusLineThrows() {
        var parser = HTTP1ResponseParser()
        XCTAssertThrowsError(try parser.append(bytes("SSH-2.0-OpenSSH\r\n\r\n")))
    }

    func testMalformedChunkSizeThrows() {
        var parser = HTTP1ResponseParser()
        XCTAssertThrowsError(try parser.append(bytes(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"
        )))
    }
}
