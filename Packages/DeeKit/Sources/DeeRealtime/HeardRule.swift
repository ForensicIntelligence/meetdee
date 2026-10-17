import Foundation

/// The single source of truth for "which of Dee's sentences did the listener hear".
///
/// Every sentence of an assistant item is placed on that item's audio exactly
/// once, when `.assistantSentence` is emitted: its `audioMsHint` is where it
/// **ends**, and it starts where the previous sentence ended (0 for the first);
/// a hint below the previous end is clamped up to it. Those numbers are final:
/// nobody re-derives them later from a better rate or the item's total audio.
/// Given the same hints and the same played milliseconds, the session's history
/// (`recentTurns`, rollover seeds, `BargeInOutcome.Truncation.heardSentences`)
/// and DeeVoice's `SentenceClock` (`deeSaid`) therefore always agree.
///
/// A sentence counts as heard when playback passed its end, or — for a cut —
/// when it had started (the first sentence: any audio played; later ones:
/// playback passed their start) and its midpoint (integer ms) was played.
public enum HeardRule {
    /// `(start, end)` of each sentence from the emitted hints, in order.
    public static func placements(_ hints: [Int]) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        out.reserveCapacity(hints.count)
        var previous = 0
        for h in hints {
            let end = max(h, previous)
            out.append((previous, end))
            previous = end
        }
        return out
    }

    /// Whether sentence `index`, placed at `start…end`, was heard when playback
    /// stopped at `playedMs`.
    public static func heard(start: Int, end: Int, index: Int, playedMs: Int) -> Bool {
        let started = index == 0 ? playedMs > 0 : playedMs > start
        return started && (start + end) / 2 <= playedMs
    }

    /// How many leading sentences (hints as emitted) were heard at `playedMs`.
    public static func heardCount(hints: [Int], playedMs: Int) -> Int {
        var n = 0
        for (i, p) in placements(hints).enumerated() {
            guard heard(start: p.start, end: p.end, index: i, playedMs: playedMs) else { break }
            n += 1
        }
        return n
    }
}
