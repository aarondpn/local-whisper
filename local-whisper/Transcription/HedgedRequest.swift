import Foundation

/// Races two ways of performing the same request without paying for both in the common case.
///
/// `primary` runs alone at first. `secondary` starts as soon as `primary` fails, or once
/// `hedgeAfter` elapses without an answer, whichever comes first. The first success wins and
/// the other leg is cancelled. A "final" error (the server answered, e.g. an HTTP 4xx) ends the
/// race immediately, since the other leg would only get the same answer. If both legs fail, the
/// last error is thrown.
///
/// The time-based hedge exists because a wedged HTTP/3 upload gives no signal at all: URLSession
/// reports the whole body as sent the moment it's buffered, then sits silently until the server
/// gives up ~15 s later. Elapsed time is the only usable stall signal.
enum HedgedRequest {
    enum Leg: Equatable, Sendable {
        case primary
        case secondary
    }

    private enum Event<T: Sendable>: Sendable {
        case finished(Leg, Result<T, Error>)
        case hedgeTimerFired
    }

    static func run<T: Sendable>(
        hedgeAfter delay: Duration,
        isFinal: @escaping @Sendable (Error) -> Bool,
        primary: @escaping @Sendable () async throws -> T,
        secondary: @escaping @Sendable () async throws -> T,
        onHedge: @escaping @Sendable () -> Void = {}
    ) async throws -> (value: T, leg: Leg) {
        let result = await withTaskGroup(of: Event<T>.self) { group -> Result<(value: T, leg: Leg), Error> in
            group.addTask { .finished(.primary, await outcome(of: primary)) }
            group.addTask {
                try? await Task.sleep(for: delay)
                return .hedgeTimerFired
            }

            var secondaryStarted = false
            var inFlight = 1
            var lastError: Error = CancellationError()

            while let event = await group.next() {
                switch event {
                case .hedgeTimerFired:
                    guard !secondaryStarted, !Task.isCancelled else { continue }
                    secondaryStarted = true
                    inFlight += 1
                    onHedge()
                    group.addTask { .finished(.secondary, await outcome(of: secondary)) }

                case .finished(let leg, .success(let value)):
                    group.cancelAll()
                    return .success((value, leg))

                case .finished(_, .failure(let error)):
                    inFlight -= 1
                    lastError = error
                    if isFinal(error) {
                        group.cancelAll()
                        return .failure(error)
                    }
                    if !secondaryStarted, !Task.isCancelled {
                        secondaryStarted = true
                        inFlight += 1
                        group.addTask { .finished(.secondary, await outcome(of: secondary)) }
                    } else if inFlight == 0 {
                        group.cancelAll()
                        return .failure(lastError)
                    }
                }
            }
            return .failure(lastError)
        }
        return try result.get()
    }

    private static func outcome<T>(of operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}
