import Foundation
import Synchronization

/// One chat request at a time to one LAN server (0.6 LAN verify).
///
/// Measured on the user's lithos-metal server (port 8000): it serves exactly one request and
/// answers any concurrent one with HTTP 429 at once (no queue); it frees the slot about 1.5 s
/// after a client disconnects. Dee used to overlap requests all the time (a warm-up left
/// running under the real request, a new request right after a cancel), so every overlapping
/// turn was lost. Every chat stream to a server holds that server's lane from before its
/// request is sent until its HTTP stream has closed (finished, failed or cancelled), so a
/// request after a cancel waits for the cancelled stream to close first. Ollama queues on
/// its own; the lane costs it nothing (only one reply is ever wanted at a time).
public actor ChatLane {
    private var busy = false
    private var waiters: [(id: Int, c: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0
    /// Requests that had to wait for an earlier one (tests / harness).
    public private(set) var waited = 0

    public init() {}

    private static let registry = Mutex<[String: ChatLane]>([:])

    /// The lane of the server at `base` (one per scheme://host:port, shared by every socket).
    public static func shared(for base: URL) -> ChatLane {
        let key = "\(base.scheme ?? "http")://\(base.host?.lowercased() ?? ""):\(base.port ?? -1)"
        return registry.withLock { r in
            if let lane = r[key] { return lane }
            let lane = ChatLane()
            r[key] = lane
            return lane
        }
    }

    /// Waits for the lane. False when the caller was cancelled while waiting (it holds nothing then).
    /// A caller granted the lane must `release()` it exactly once.
    public func acquire() async -> Bool {
        if !busy { busy = true; return true }
        waited += 1
        nextID += 1
        let id = nextID
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.drop(id) }
        }
        return granted
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().c.resume(returning: true)   // stays busy: handed over
        }
    }

    public var isBusy: Bool { busy }

    private func drop(_ id: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).c.resume(returning: false)
    }
}

/// How a chat request treats HTTP 429 ("busy"): wait and retry, never another provider.
public struct RateLimitRetry: Sendable, Equatable {
    /// Total seconds spent waiting across retries before the 429 is a failure (0: no retries).
    public var budget: Double
    public init(budget: Double) { self.budget = budget }
    public static let none = RateLimitRetry(budget: 0)
    /// A reply: a single-slot server frees within ~1.5 s of the previous client leaving; another
    /// client's (the user's phone) reply can take several seconds.
    public static let reply = RateLimitRetry(budget: 8)

    /// The wait before retry `attempt` (0-based): `Retry-After` seconds when given (0.2…3 s),
    /// else 0.3, 0.6, 1.0, then 1.5 s.
    public static func delay(retryAfter header: String?, attempt: Int) -> Double {
        if let h = header?.trimmingCharacters(in: .whitespaces), let s = Double(h), s.isFinite, s >= 0 {
            return min(max(s, 0.2), 3)
        }
        let steps = [0.3, 0.6, 1.0]
        return attempt < steps.count ? steps[attempt] : 1.5
    }
}
