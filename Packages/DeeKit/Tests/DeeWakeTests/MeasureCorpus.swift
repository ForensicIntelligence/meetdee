import Foundation
import Testing
@testable import DeeWake

/// Corpus measurement (opt-in, `DEE_WAKE_MEASURE=/path/out.json`): every fixture through
/// the real on-device recogniser under each corpus phrase's contextual strings; writes
/// all segments. `WakeCorpus` pins the transcripts measured this way.
@Suite struct MeasureCorpus {
    struct Row: Codable { var id: String; var context: String; var segments: [Seg] }
    struct Seg: Codable { var src: String; var text: String; var alts: [String]; var isFinal: Bool; var start: Int64?; var end: Int64?; var runs: [[String]] }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEE_WAKE_MEASURE"] != nil))
    func measure() async throws {
        let out = ProcessInfo.processInfo.environment["DEE_WAKE_MEASURE"]!
        let env = ProcessInfo.processInfo.environment
        let only = env["DEE_WAKE_MEASURE_KIND"]
        let prefix = env["DEE_WAKE_MEASURE_PREFIX"]
        let both = env["DEE_WAKE_MEASURE_SPEECH"] != nil
        var jobs: [(FixtureItem, String)] = []
        for item in Fixtures.items where (only == nil || item.kind == only) && (prefix == nil || item.id.hasPrefix(prefix!)) {
            if let p = item.phrase { jobs.append((item, p)) } else {
                for p in WakeCorpus.phrases { jobs.append((item, p)) }
            }
        }
        var rows: [Row] = []
        try await withThrowingTaskGroup(of: Row.self) { group in
            var next = 0
            func add() throws {
                guard next < jobs.count else { return }
                let (item, p) = jobs[next]
                next += 1
                let samples = try Fixtures.samples(item)
                let ctx = try WakePhrase(validating: p).contextualStrings
                group.addTask {
                    let segs = try await Recognizer.run(samples, contextual: ctx, speechTranscriber: both)
                    return Row(id: item.id, context: p, segments: segs.map {
                        Seg(src: $0.source.rawValue, text: $0.text, alts: $0.alternatives, isFinal: $0.isFinal, start: $0.startFrame, end: $0.endFrame,
                            runs: $0.runs.map { [$0.text, String($0.startFrame), String($0.endFrame)] })
                    })
                }
            }
            for _ in 0..<4 { try add() }
            while let r = try await group.next() {
                rows.append(r)
                try add()
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows.sorted { ($0.id, $0.context) < ($1.id, $1.context) }).write(to: URL(fileURLWithPath: out))
    }
}
