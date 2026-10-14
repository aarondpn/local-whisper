import XCTest
import os

/// `HedgedRequest.swift` is compiled straight into this bundle (target membership), so these
/// run as plain logic tests without launching the app.
final class HedgedRequestTests: XCTestCase {
    private struct Transient: Error {}
    private struct Final: Error {}

    /// Records which legs ran and whether they observed cancellation.
    private final class Recorder: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (started: [String](), cancelled: [String]()))

        func started(_ leg: String) { state.withLock { $0.started.append(leg) } }
        func cancelled(_ leg: String) { state.withLock { $0.cancelled.append(leg) } }
        var startedLegs: [String] { state.withLock { $0.started } }
        var cancelledLegs: [String] { state.withLock { $0.cancelled } }
    }

    /// A leg that never answers on its own and records when it gets cancelled.
    private func hang(_ leg: String, _ recorder: Recorder) async throws -> String {
        recorder.started(leg)
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            recorder.cancelled(leg)
            throw error
        }
        return leg
    }

    private func isFinal(_ error: Error) -> Bool { error is Final }

    func testFastPrimaryWinsWithoutStartingSecondary() async throws {
        let recorder = Recorder()
        let result = try await HedgedRequest.run(
            hedgeAfter: .milliseconds(200),
            isFinal: isFinal,
            primary: { recorder.started("primary"); return "primary" },
            secondary: { recorder.started("secondary"); return "secondary" }
        )
        XCTAssertEqual(result.value, "primary")
        XCTAssertEqual(result.leg, .primary)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.startedLegs, ["primary"], "no hedge once the primary has answered")
    }

    func testStalledPrimaryIsHedgedAfterDelayAndCancelled() async throws {
        let recorder = Recorder()
        let hedged = OSAllocatedUnfairLock(initialState: false)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await HedgedRequest.run(
            hedgeAfter: .milliseconds(150),
            isFinal: isFinal,
            primary: { try await self.hang("primary", recorder) },
            secondary: { recorder.started("secondary"); return "secondary" },
            onHedge: { hedged.withLock { $0 = true } }
        )
        let elapsed = clock.now - start
        XCTAssertEqual(result.value, "secondary")
        XCTAssertEqual(result.leg, .secondary)
        XCTAssertTrue(hedged.withLock { $0 })
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150), "secondary waits for the hedge delay")
        XCTAssertLessThan(elapsed, .seconds(5), "the stalled primary must not hold up the result")
        XCTAssertEqual(recorder.cancelledLegs, ["primary"], "the losing leg is cancelled")
    }

    func testFailingPrimaryStartsSecondaryImmediately() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await HedgedRequest.run(
            hedgeAfter: .seconds(10),
            isFinal: isFinal,
            primary: { () async throws -> String in throw Transient() },
            secondary: { "secondary" }
        )
        XCTAssertEqual(result.leg, .secondary)
        XCTAssertLessThan(clock.now - start, .seconds(2), "no need to wait out the hedge delay")
    }

    func testSlowSecondaryLosesToPrimaryThatAnswersLater() async throws {
        let recorder = Recorder()
        let result = try await HedgedRequest.run(
            hedgeAfter: .milliseconds(50),
            isFinal: isFinal,
            primary: { () async throws -> String in try await Task.sleep(for: .milliseconds(250)); return "primary" },
            secondary: { try await self.hang("secondary", recorder) }
        )
        XCTAssertEqual(result.leg, .primary)
        XCTAssertEqual(recorder.cancelledLegs, ["secondary"])
    }

    func testFinalErrorEndsRaceWithoutHedging() async throws {
        let recorder = Recorder()
        do {
            _ = try await HedgedRequest.run(
                hedgeAfter: .seconds(10),
                isFinal: isFinal,
                primary: { () async throws -> String in throw Final() },
                secondary: { recorder.started("secondary"); return "secondary" }
            )
            XCTFail("expected the final error to be thrown")
        } catch {
            XCTAssertTrue(error is Final)
        }
        XCTAssertEqual(recorder.startedLegs, [], "a server answer is not retried on the other transport")
    }

    func testFinalErrorFromSecondaryCancelsStalledPrimary() async throws {
        let recorder = Recorder()
        do {
            _ = try await HedgedRequest.run(
                hedgeAfter: .milliseconds(50),
                isFinal: isFinal,
                primary: { try await self.hang("primary", recorder) },
                secondary: { throw Final() }
            )
            XCTFail("expected the final error to be thrown")
        } catch {
            XCTAssertTrue(error is Final)
        }
        XCTAssertEqual(recorder.cancelledLegs, ["primary"])
    }

    func testBothLegsFailingThrowsLastError() async throws {
        struct SecondaryFailure: Error {}
        do {
            _ = try await HedgedRequest.run(
                hedgeAfter: .seconds(10),
                isFinal: isFinal,
                primary: { () async throws -> String in throw Transient() },
                secondary: { throw SecondaryFailure() }
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is SecondaryFailure)
        }
    }

    func testOuterCancellationStopsBothLegs() async throws {
        let recorder = Recorder()
        let task = Task {
            try await HedgedRequest.run(
                hedgeAfter: .milliseconds(20),
                isFinal: isFinal,
                primary: { try await self.hang("primary", recorder) },
                secondary: { try await self.hang("secondary", recorder) }
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(Set(recorder.cancelledLegs), ["primary", "secondary"])
    }
}
