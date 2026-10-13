import XCTest

/// `PressLifecycle.swift` is compiled straight into this bundle (target membership), so
/// these run as plain logic tests without launching the app.
final class PressLifecycleTests: XCTestCase {
    private let threshold: TimeInterval = 0.22
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeLifecycle() -> PressLifecycle {
        PressLifecycle(tapThreshold: threshold)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - Normal press

    func testLongPressRecordsStopsAndFinishes() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.phase, .recording)

        XCTAssertEqual(lifecycle.release(at: at(1.5)), .stop(token))
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.beginProcessing(token))
        XCTAssertEqual(lifecycle.phase, .processing)

        lifecycle.finish(token)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertNotNil(lifecycle.press(at: at(2)), "next press is accepted once idle")
    }

    func testReleaseExactlyAtThresholdStops() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.release(at: at(threshold)), .stop(token))
    }

    // MARK: - Short presses (the stuck-recording scenarios)

    func testTapWhileRecordingCancels() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))

        XCTAssertEqual(lifecycle.release(at: at(0.1)), .cancel)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertFalse(lifecycle.beginProcessing(token))
    }

    /// The original bug: a key-up handled before the start path marked the session as
    /// recording was dropped, and the start then opened the mic with the key already up.
    func testReleaseBeforeCaptureBeganCancelsAndBlocksLateStart() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))

        XCTAssertEqual(lifecycle.release(at: at(0.05)), .cancel)
        XCTAssertEqual(lifecycle.phase, .idle)

        XCTAssertFalse(lifecycle.isCurrent(token, in: .starting), "suspended start must see it was canceled")
        XCTAssertFalse(lifecycle.captureBegan(token), "late engine start must not adopt the recording")
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    /// Slow start (e.g. Bluetooth mic, busy streaming engine): the key is held past the
    /// tap threshold but released before the mic opened. Nothing was captured, so this
    /// is still a cancel — never a recording that starts after the key is up.
    func testLongReleaseBeforeCaptureBeganStillCancels() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))

        XCTAssertEqual(lifecycle.release(at: at(2)), .cancel)
        XCTAssertFalse(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    // MARK: - Overlapping presses

    /// Tap, then press again while the first press's start path is still suspended. The
    /// first start must not resume into the second press's session.
    func testStaleStartCannotHijackNewerPress() throws {
        var lifecycle = makeLifecycle()
        let first = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertEqual(lifecycle.release(at: at(0.06)), .cancel)

        let second = try XCTUnwrap(lifecycle.press(at: at(0.1)))
        XCTAssertNotEqual(first, second)

        XCTAssertFalse(lifecycle.isCurrent(first, in: .starting))
        XCTAssertFalse(lifecycle.captureBegan(first))
        XCTAssertTrue(lifecycle.isCurrent(second, in: .starting), "stale start leaves the new press alone")

        XCTAssertTrue(lifecycle.captureBegan(second))
        XCTAssertEqual(lifecycle.release(at: at(1)), .stop(second))
    }

    func testPressIsRejectedWhileBusy() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertNil(lifecycle.press(at: at(0.01)), "starting")

        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertNil(lifecycle.press(at: at(0.5)), "recording")

        XCTAssertEqual(lifecycle.release(at: at(1)), .stop(token))
        XCTAssertNil(lifecycle.press(at: at(1.05)), "stopping")

        XCTAssertTrue(lifecycle.beginProcessing(token))
        XCTAssertNil(lifecycle.press(at: at(1.3)), "processing")

        lifecycle.finish(token)
        XCTAssertNotNil(lifecycle.press(at: at(2)))
    }

    func testStaleFinishDoesNotEndNewerSession() throws {
        var lifecycle = makeLifecycle()
        let first = try XCTUnwrap(lifecycle.press(at: at(0)))
        lifecycle.abort()
        let second = try XCTUnwrap(lifecycle.press(at: at(0.5)))

        lifecycle.finish(first)
        XCTAssertTrue(lifecycle.isCurrent(second, in: .starting))
    }

    // MARK: - Duplicate / stray key-ups

    func testReleaseIsIgnoredWhenIdleStoppingOrProcessing() throws {
        var lifecycle = makeLifecycle()
        XCTAssertEqual(lifecycle.release(at: at(0)), .ignore)

        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.release(at: at(1)), .stop(token))
        // A synthesized release followed by the real key-up must not stop twice.
        XCTAssertEqual(lifecycle.release(at: at(1.01)), .ignore)
        XCTAssertEqual(lifecycle.phase, .stopping)

        XCTAssertTrue(lifecycle.beginProcessing(token))
        XCTAssertEqual(lifecycle.release(at: at(1.3)), .ignore)
        XCTAssertEqual(lifecycle.phase, .processing)
    }

    // MARK: - ESC

    func testEscapeWhenIdleIsIgnored() {
        var lifecycle = makeLifecycle()
        XCTAssertEqual(lifecycle.escape(), .ignore)
    }

    /// Previously ESC was ignored until the start path set `isRecording`, so the
    /// recording started anyway.
    func testEscapeWhileStartingAbortsAndBlocksLateStart() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))

        XCTAssertEqual(lifecycle.escape(), .abortCapture)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertFalse(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.release(at: at(0.5)), .ignore, "the key-up after ESC is a no-op")
    }

    func testEscapeWhileRecordingAborts() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))

        XCTAssertEqual(lifecycle.escape(), .abortCapture)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertEqual(lifecycle.release(at: at(1)), .ignore)
    }

    func testEscapeDuringTailAbortsAndBlocksProcessing() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.release(at: at(1)), .stop(token))

        XCTAssertEqual(lifecycle.escape(), .abortCapture)
        XCTAssertFalse(lifecycle.beginProcessing(token), "pending stop task must not transcribe")
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    func testEscapeDuringProcessingFlagsCancellationUntilFinish() throws {
        var lifecycle = makeLifecycle()
        let token = try XCTUnwrap(lifecycle.press(at: at(0)))
        XCTAssertTrue(lifecycle.captureBegan(token))
        XCTAssertEqual(lifecycle.release(at: at(1)), .stop(token))
        XCTAssertTrue(lifecycle.beginProcessing(token))

        XCTAssertEqual(lifecycle.escape(), .cancelProcessing)
        XCTAssertTrue(lifecycle.isProcessingCancelled)
        XCTAssertEqual(lifecycle.phase, .processing, "processing still owns the pipeline until it unwinds")
        XCTAssertNil(lifecycle.press(at: at(1.5)))

        lifecycle.finish(token)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertFalse(lifecycle.isProcessingCancelled)

        let next = try XCTUnwrap(lifecycle.press(at: at(2)))
        XCTAssertTrue(lifecycle.captureBegan(next))
        XCTAssertFalse(lifecycle.isProcessingCancelled, "cancel flag never leaks into the next press")
    }

    // MARK: - Spam

    /// Hammer the key with sub-threshold taps, letting each start path resume at a
    /// random point. However the interleaving falls, no start may ever adopt a recording
    /// after its key-up, and the machine always ends idle.
    func testSpamTappingNeverLeavesARecordingRunning() {
        var generator = SplitMix64(seed: 0xC0FFEE)
        var lifecycle = makeLifecycle()
        var suspendedStarts: [PressLifecycle.Token] = []
        var clock: TimeInterval = 0

        for _ in 0..<5_000 {
            clock += 0.01 + Double(generator.next() % 100) / 1_000
            switch generator.next() % 4 {
            case 0:
                if let token = lifecycle.press(at: at(clock)) {
                    suspendedStarts.append(token)
                }
            case 1:
                if case .stop(let token) = lifecycle.release(at: at(clock)) {
                    // Held long enough for a real recording: let it run to completion.
                    XCTAssertTrue(lifecycle.beginProcessing(token))
                    lifecycle.finish(token)
                }
                XCTAssertEqual(lifecycle.phase, .idle, "after any key-up nothing is starting or capturing")
            case 2:
                // A suspended start path resumes and tries to open the mic.
                if !suspendedStarts.isEmpty {
                    let index = Int(generator.next() % UInt64(suspendedStarts.count))
                    let token = suspendedStarts.remove(at: index)
                    if lifecycle.captureBegan(token) {
                        XCTAssertTrue(lifecycle.isCurrent(token, in: .recording))
                    }
                }
            default:
                if generator.next() % 8 == 0 {
                    _ = lifecycle.escape()
                }
            }
        }

        // Final key-up: everything must wind down to idle.
        if case .stop(let token) = lifecycle.release(at: at(clock + 0.01)) {
            XCTAssertTrue(lifecycle.beginProcessing(token))
            lifecycle.finish(token)
        }
        for token in suspendedStarts {
            XCTAssertFalse(lifecycle.captureBegan(token))
        }
        XCTAssertEqual(lifecycle.phase, .idle)
    }
}

/// Small deterministic PRNG so the spam test is reproducible.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
