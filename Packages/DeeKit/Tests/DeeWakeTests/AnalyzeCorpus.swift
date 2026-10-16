import Foundation
import Testing
@testable import DeeWake

/// Opt-in analysis of a MeasureCorpus dump (`DEE_WAKE_ANALYZE=/path.json`): recall per
/// phrase with the real matcher, misses, and negative hits. Prints only.
@Suite struct AnalyzeCorpus {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEE_WAKE_ANALYZE"] != nil))
    func analyze() throws {
        let env = ProcessInfo.processInfo.environment
        let data = try Data(contentsOf: URL(fileURLWithPath: env["DEE_WAKE_ANALYZE"]!))
        let rows = try JSONDecoder().decode([MeasureCorpus.Row].self, from: data)
        let src = env["DEE_WAKE_SRC"]   // dictation | speech | nil = both
        for p in WakeCorpus.phrases {
            let phrase = try WakePhrase(validating: p)
            let t = env["DEE_WAKE_T"].map { v -> WakeMatcher.Thresholds in
                let p = v.split(separator: ",")
                return .init(keyDistance: Int(p[0])!, letterRatio: Double(p[1])!)
            } ?? .tuned
            let m = WakeMatcher(phrase, t)
            var pos = 0, hit = 0, rpos = 0, rhit = 0
            var misses: [String] = []
            var falseHits: [String] = []
            for r in rows where r.context == p {
                let item = Fixtures.item(r.id)
                if item.kind == "positive" || item.kind == "onset", item.phrase != p { continue }
                let segs = r.segments.filter { src == nil || $0.src == src }
                let matched = segs.contains { m.match([$0.text] + $0.alts, isFinal: $0.isFinal) != nil }
                if item.kind == "positive" {
                    pos += 1
                    let real = WakeCorpus.isRealisticVoice(Fixtures.item(r.id).voice)
                    if real { rpos += 1; if matched { rhit += 1 } }
                    if matched { hit += 1 } else { misses.append("\(r.id)\(real ? "" : " (robotic)"): " + segs.filter(\.isFinal).map(\.text).joined(separator: "|")) }
                } else if ["negative", "unaddressed", "bed", "harness-dee"].contains(item.kind) {
                    if matched {
                        let which = segs.compactMap { s in m.match([s.text] + s.alts, isFinal: s.isFinal).map { "\($0.matched)[\($0.tier)] in \(s.isFinal ? "F" : "V") '\(s.text)'" } }
                        falseHits.append("\(r.id): \(which)")
                    }
                }
            }
            print("ANALYZE \(p): recall \(hit)/\(pos), realistic voices \(rhit)/\(rpos)")
            for x in misses { print("ANALYZE   miss \(x)") }
            for x in falseHits { print("ANALYZE   FALSE \(x)") }
        }
    }
}
