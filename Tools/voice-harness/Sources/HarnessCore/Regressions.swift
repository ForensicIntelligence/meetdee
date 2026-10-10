import Foundation

/// Tune 10: utterances a baseline run (tune 7, the best so far) handled correctly that
/// this run did not. "Correctly" is `Metrics.Utterance.problems` empty and, when both
/// runs were judged, a judge score above `judgeFloor`.
///
/// Utterances are matched by scenario + fixture + occurrence of that fixture in the
/// scenario, so an edited scenario file still lines up where it can. Both sides are
/// scored by the current metrics code (the baseline's runs are recomputed), so a metric
/// fix never reads as a regression.
public struct Regressions: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var scenario: String
        public var fixture: String
        /// 1-based occurrence of `fixture` in the scenario.
        public var occurrence: Int
        public var index: Int
        /// What went wrong now.
        public var problems: [String]
        /// What she said then, and now.
        public var baselineReply: String?
        public var reply: String?
    }

    /// The baseline's run id (e.g. `20261010-063215`, tune 7).
    public var baseline: String
    /// Utterances in both runs, and of those, handled correctly in the baseline.
    public var compared = 0
    public var baselineCorrect = 0
    /// Correct then, not now (the list), and wrong then, correct now (a count).
    public var regressions: [Entry] = []
    public var fixed = 0
    /// Utterances the baseline handled correctly that this run did not script.
    public var notRun = 0

    /// A judge score at or below this is a problem (the judge's "off" replies).
    public static let judgeFloor = 2

    struct Key: Hashable { var scenario: String; var fixture: String; var occurrence: Int }

    /// Utterance rows by key, each with its problems (plus a low judge score).
    static func keyed(_ m: Metrics, judge: Judge.Summary?) -> [Key: (row: Metrics.Utterance, problems: [String])] {
        var seen: [String: Int] = [:]
        var out: [Key: (row: Metrics.Utterance, problems: [String])] = [:]
        for r in m.utterances {
            let tag = "\(r.scenario)\u{1F}\(r.fixture)"
            seen[tag, default: 0] += 1
            var p = r.problems
            if let sc = judge?.scores.first(where: { $0.scenario == r.scenario && $0.index == r.index && $0.fixture == r.fixture }),
               sc.score <= judgeFloor {
                p.append("judge \(sc.score): \(sc.reason)")
            }
            out[Key(scenario: r.scenario, fixture: r.fixture, occurrence: seen[tag]!)] = (r, p)
        }
        return out
    }

    /// Compare `current` with `baseline`. The judge counts only when both runs were
    /// judged (a run without `--judge` is not "worse" for it).
    public static func compare(current: Metrics, judge: Judge.Summary?, baseline: Metrics, baselineJudge: Judge.Summary?,
                               baselineID: String) -> Regressions {
        let useJudge = judge.map { !$0.scores.isEmpty } == true && baselineJudge.map { !$0.scores.isEmpty } == true
        let now = keyed(current, judge: useJudge ? judge : nil)
        let then = keyed(baseline, judge: useJudge ? baselineJudge : nil)
        var out = Regressions(baseline: baselineID)
        let order = then.keys.sorted {
            ($0.scenario, then[$0]!.row.index) < ($1.scenario, then[$1]!.row.index)
        }
        for key in order {
            let old = then[key]!
            guard let new = now[key] else {
                if old.problems.isEmpty { out.notRun += 1 }
                continue
            }
            out.compared += 1
            if old.problems.isEmpty {
                out.baselineCorrect += 1
                if !new.problems.isEmpty {
                    out.regressions.append(Entry(scenario: key.scenario, fixture: key.fixture, occurrence: key.occurrence,
                                                 index: new.row.index, problems: new.problems,
                                                 baselineReply: old.row.deeReply, reply: new.row.deeReply))
                }
            } else if new.problems.isEmpty {
                out.fixed += 1
            }
        }
        return out
    }
}
