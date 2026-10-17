import Foundation

/// Tune 14: the 0.6.0 acceptance is judged over TWO consecutive full runs, every gate
/// on the POOLED counts and percentiles (e.g. backchannel stops over 32, latency p90
/// over both runs' turns). Pooling recomputes `Metrics` over every run of every report
/// at once, so each gate sees the summed counts and the percentiles of the joined
/// samples, with the same thresholds as a single run (`Gates.evaluate`).
public enum Pool {
    public struct Source: Sendable {
        public var id: String
        public var model: String
        public var aborted: String?
        public var runs: [RunRecord]
        public var judge: Judge.Summary?
        public init(id: String, model: String, aborted: String? = nil, runs: [RunRecord], judge: Judge.Summary? = nil) {
            self.id = id; self.model = model; self.aborted = aborted; self.runs = runs; self.judge = judge
        }
    }

    public struct Result: Sendable {
        public var metrics: Metrics
        public var judge: Judge.Summary?
        public var gates: [Gate]
        /// Reports with a judge pass, of all pooled.
        public var judged: Int
        public var failed: Bool { Gates.anyFailed(gates) }
    }

    /// Every run, its scenario prefixed with its report id ("<id>/<scenario>"): the same
    /// scenario in two reports stays two runs (metrics match rows by scenario name).
    public static func runs(_ sources: [Source]) -> [RunRecord] {
        let ids = uniqueIDs(sources)
        return zip(sources, ids).flatMap { s, id in s.runs.map { r in var r = r; r.scenario = "\(id)/\(r.scenario)"; return r } }
    }

    /// Round 2: report ids made unique ("<id>#2") — two reports written in the same
    /// second before `RunIDs` shared an id, and their runs must stay apart.
    public static func uniqueIDs(_ sources: [Source]) -> [String] {
        var seen: [String: Int] = [:]
        return sources.map { s in
            let n = (seen[s.id] ?? 0) + 1
            seen[s.id] = n
            return n == 1 ? s.id : "\(s.id)#\(n)"
        }
    }

    /// Every judged report's verdicts in one summary (leaks re-checked as `gates` does);
    /// nil when no report was judged.
    public static func judge(_ sources: [Source]) -> Judge.Summary? {
        let judged = sources.filter { $0.judge != nil }
        guard !judged.isEmpty else { return nil }
        let models = judged.compactMap { $0.judge?.model }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var out = Judge.Summary(model: models.joined(separator: ", "))
        let ids = uniqueIDs(sources)
        for (s, id) in zip(sources, ids) {
            guard var j = s.judge else { continue }
            j.recheckLeaks()
            out.scores += j.scores.map { var c = $0; c.scenario = "\(id)/\(c.scenario)"; return c }
            out.failures += j.failures
            out.usageInputTokens += j.usageInputTokens
            out.usageOutputTokens += j.usageOutputTokens
        }
        out.aggregate()
        return out
    }

    public static func evaluate(_ sources: [Source], thresholds: Gates.Thresholds = Gates.Thresholds()) -> Result {
        let all = runs(sources)
        let metrics = Metrics.compute(all, pricing: Pricing.forModel(sources.first?.model ?? "gpt-realtime-2.1-mini"))
        var judge = judge(sources)
        judge?.restrictToSpoken(all, metrics: metrics)
        return Result(metrics: metrics, judge: judge, gates: Gates.evaluate(metrics, judge: judge, thresholds: thresholds),
                      judged: sources.filter { $0.judge != nil }.count)
    }
}
