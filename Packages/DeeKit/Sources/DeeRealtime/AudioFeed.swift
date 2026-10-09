import Foundation
import Synchronization

/// The ordered queue between the mic tap thread (`RealtimeSession.feedAudio`) and
/// the session actor. Bounded: when the actor falls behind by more than `limit`
/// chunks, the oldest chunk is dropped and a `.gap` takes its place, so the
/// session learns exactly where in the stream audio went missing.
final class AudioFeed: Sendable {
    enum Item: Sendable, Equatable {
        case audio(Data)
        /// This many bytes were dropped here.
        case gap(bytes: Int)
    }

    private struct State {
        var items: [Item] = []
        var audioCount = 0
        var waiter: CheckedContinuation<Item?, Never>?
        var finished = false
    }

    private let state = Mutex(State())
    let limit: Int

    init(limit: Int) { self.limit = max(1, limit) }

    /// Never blocks; never reorders.
    func push(_ pcm: Data) {
        let waiter = state.withLock { s -> CheckedContinuation<Item?, Never>? in
            guard !s.finished else { return nil }
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.items.append(.audio(pcm))
            s.audioCount += 1
            if s.audioCount > limit { Self.dropOldest(&s) }
            return nil
        }
        waiter?.resume(returning: .audio(pcm))
    }

    /// The next item in order; nil once finished and drained.
    func next() async -> Item? {
        await withCheckedContinuation { (c: CheckedContinuation<Item?, Never>) in
            let ready = state.withLock { s -> Item?? in
                if !s.items.isEmpty {
                    let item = s.items.removeFirst()
                    if case .audio = item { s.audioCount -= 1 }
                    return .some(item)
                }
                if s.finished { return .some(nil) }
                s.waiter = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func finish() {
        let waiter = state.withLock { s -> CheckedContinuation<Item?, Never>? in
            s.finished = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// Replaces the oldest audio chunk with a gap (merged with a gap next to it).
    private static func dropOldest(_ s: inout State) {
        guard let i = s.items.firstIndex(where: { if case .audio = $0 { true } else { false } }),
              case .audio(let pcm) = s.items[i] else { return }
        s.audioCount -= 1
        var bytes = pcm.count
        var at = i
        if i > 0, case .gap(let before) = s.items[i - 1] {
            bytes += before
            s.items.remove(at: i)
            at = i - 1
        }
        if at + 1 < s.items.count, case .gap(let after) = s.items[at + 1] {
            bytes += after
            s.items.remove(at: at + 1)
        }
        s.items[at] = .gap(bytes: bytes)
    }
}
