import Foundation
import Synchronization

/// Monotonic time and sleeping, injectable so tests run watchdogs, keepalives
/// and the 60-minute rollover on a virtual clock.
public protocol RealtimeClock: Sendable {
    /// Monotonic seconds (any origin).
    func now() -> Double
    /// Sleeps; throws `CancellationError` when the task is cancelled.
    func sleep(seconds: Double) async throws
}

/// Wall time (`ContinuousClock`, keeps counting while the device sleeps).
public struct SystemRealtimeClock: RealtimeClock {
    private static let origin = ContinuousClock.now

    public init() {}

    public func now() -> Double {
        let d = ContinuousClock.now - Self.origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

/// A clock that only moves when told to. Sleepers wake in deadline order on `advance`.
public final class ManualRealtimeClock: RealtimeClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var now: Double
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledEarly: Set<UInt64> = []
    }
    private let state: Mutex<State>

    public init(start: Double = 1_000) { state = Mutex(State(now: start)) }

    public func now() -> Double { state.withLock { $0.now } }

    /// Number of tasks currently sleeping on this clock.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(seconds: Double) async throws {
        let id = state.withLock { s -> UInt64 in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let outcome = state.withLock { s -> Bool? in
                    if s.cancelledEarly.remove(id) != nil { return false }
                    if seconds <= 0 { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + seconds, continuation: c))
                    return nil
                }
                switch outcome {
                case true?: c.resume()
                case false?: c.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let c = state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else {
                    s.cancelledEarly.insert(id)   // not registered yet: refuse on arrival
                    return nil
                }
                return s.sleepers.remove(at: i).continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    public func advance(by seconds: Double) {
        let due = state.withLock { s -> [Sleeper] in
            s.now += seconds
            let due = s.sleepers.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
