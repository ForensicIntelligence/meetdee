import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// SELF.md §11, §12.5 — lint and privacy invariants.
@Suite struct PolicyTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DeeSelf")

    static func swiftFiles() throws -> [URL] {
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static let banned = ["Date()", "Date.now", "Date(timeIntervalSinceNow", "timeIntervalSinceNow", ".random(", "Double.random",
                         "Int.random", "Bool.random", "UUID()", "UUID.init()", "SystemRandomNumberGenerator", "arc4random",
                         "CFAbsoluteTimeGetCurrent", "ProcessInfo.processInfo.systemUptime", ".randomElement(", ".shuffled(",
                         ".shuffle(", "Hasher", ".hashValue", "hash(into"]
    /// Patterns: the `.now` shorthand (`= .now`, `(.now)`), and iterating a Dictionary's
    /// keys/values or a fresh Set without sorting (order differs per process).
    static let bannedPatterns: [(String, NSRegularExpression)] = [
        ("the .now shorthand", try! NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_\)\]\?!])\.now\b"#)),
        ("unsorted dictionary iteration", try! NSRegularExpression(pattern: #"\bfor\b.*\bin\b.*\.(keys|values)\b(?!\.sorted)"#)),
        ("unsorted dictionary iteration", try! NSRegularExpression(pattern: #"\.(keys|values)\.(forEach|map|compactMap|flatMap|reduce|first|filter|joined|enumerated)\b"#)),
        ("Set iteration", try! NSRegularExpression(pattern: #"\bfor\b.*\bin\s+Set\("#)),
    ]

    /// Lint findings for one file's text (comments after `//` are ignored).
    static func lint(_ text: String, file: String) -> [String] {
        var out: [String] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.components(separatedBy: "//").first ?? ""
            for b in banned where code.contains(b) { out.append("\(file):\(n + 1) uses \(b)") }
            let range = NSRange(code.startIndex..., in: code)
            for (why, re) in bannedPatterns where re.firstMatch(in: code, range: range) != nil { out.append("\(file):\(n + 1) \(why)") }
        }
        return out
    }

    /// No wall clock, global randomness, fresh UUIDs or per-process ordering in pure DeeSelf code.
    @Test func lintNoClockRandomOrUUIDInPureCode() throws {
        let impure: Set<String> = ["SelfStore.swift", "SelfDatabase.swift"]
        let files = try Self.swiftFiles()
        #expect(files.count >= 20)
        for f in files where !impure.contains(f.lastPathComponent) {
            for issue in Self.lint(try String(contentsOf: f, encoding: .utf8), file: f.lastPathComponent) { Issue.record(Comment(rawValue: issue)) }
        }
    }

    /// Canary: the lint catches each planted violation and passes clean idioms.
    @Test func lintCatchesPlantedViolations() {
        let planted = ["let t = Date()", "let t: Date = .now", "f(.now)", "Date(timeIntervalSinceNow: 3)", "let u = UUID.init()",
                       "xs.randomElement()", "xs.shuffled()", "var h = Hasher()", "k.hashValue", "for (k, v) in d.values {",
                       "for k in profiles.keys {", "d.keys.map { $0 }", "for x in Set(xs) {"]
        for p in planted { #expect(!Self.lint(p, file: "x").isEmpty, "missed: \(p)") }
        let clean = ["m.now = now", "moment.now", "let x = until.timeIntervalSince(now)", "for k in d.keys.sorted() {",
                     "UUID(uuidString: s)", "rng.uuid()", "e.values[$0]", "// Date() in a comment", "x?.now"]
        for c in clean { #expect(Self.lint(c, file: "x").isEmpty, "false positive: \(c)") }
    }

    /// DeeSelf (Dee DNA included) only describes Dee; it never talks to the network
    /// (review F9: DeeRealtime is the one module that does).
    @Test func deeSelfDoesNotImportFaceVoiceSenseOrRealtime() throws {
        for f in try Self.swiftFiles() {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in ["import DeeFace", "import DeeVoice", "import DeeSense", "import DeeRealtime", "import Network"] {
                #expect(!text.contains(m), "\(f.lastPathComponent): \(m)")
            }
        }
    }

    /// Every 5-word window of `text` (letters only, lower-cased).
    static func windows(_ text: String) -> Set<String> {
        let w = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard w.count >= 5 else { return [] }
        return Set((0...(w.count - 5)).map { w[$0..<($0 + 5)].joined(separator: " ") })
    }

    /// 5-grams of `utterances` found in the database file (main + WAL + SHM bytes) or in
    /// any stored text value.
    static func leaks(_ utterances: [[String]], store: SelfStore, url: URL) async throws -> (leaked: Set<String>, bytes: Int, grams: Int) {
        var stored = Set<String>()
        var bytes = 0
        for suffix in ["", "-wal", "-shm"] {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                bytes += d.count
                stored.formUnion(windows(String(decoding: d, as: UTF8.self)))
            }
        }
        for t in try await store.allText() { stored.formUnion(windows(t)) }
        var grams = Set<String>()
        for u in utterances { grams.formUnion(windows(u.joined(separator: " "))) }
        return (grams.intersection(stored), bytes, grams.count)
    }

    static let vocabulary = ["purple", "elephant", "quietly", "remembers", "seventeen", "violins", "under", "a", "melting",
                             "glacier", "while", "my", "neighbour", "practises", "tuba", "every", "thursday", "morning",
                             "secret", "password", "banana", "orbit", "whisper", "lantern", "copper", "kettle"]

    /// 1,000 seeded utterances through full sessions; neither the database file (main
    /// + WAL) nor any stored text contains a 5-word sequence from any utterance. Every
    /// persisted effect is applied, including the cue's (issued-note bookkeeping).
    @Test func noTranscriptFuzz() async throws {
        let url = SelfStoreTests.tempURL("fuzz")
        let store = try SelfStore(url: url)
        let enduring = try await store.loadEnduring(personality: Personality(), seed: 3, at: Kit.t0)
        var cx = Cortex(enduring: enduring, mind: Kit.snap(), at: Kit.t0, carried: try await store.loadCarried(at: Kit.t0),
                        session: try await store.nextSession())
        var rng = Rand(seed: 0xF022)
        var utterances: [[String]] = []
        var t = 0.0
        var writes: [SelfWrite] = SelfStoreTests.allWrites(Kit.john)
        func keep(_ fx: [Effect]) { for e in fx { if case .persist(let w) = e { writes.append(w) } } }
        keep(cx.step(.identified(Kit.john, distance: 0.2), mind: Kit.snap(), at: Kit.t0))
        for i in 0..<1000 {
            let words = (0..<(6 + rng.index(10))).map { _ in Self.vocabulary[rng.index(Self.vocabulary.count)] }
            utterances.append(words)
            let text = words.joined(separator: " ")
            t += 5
            let at = Kit.t0.addingTimeInterval(t)
            for p: Percept in [.partial(text), .pause(turnEnd: 0.9, hesitation: 0.1), Kit.heard(text), .promptSubmitted,
                               .speakingStarted, .deeSaid(tag: .curious, sentence: text), .speakingFinished,
                               .deeTurnFinished(text: text)] {
                keep(cx.step(p, mind: Kit.snap(), at: at))
            }
            keep(cx.cue(at: at).effects)
            if i % 100 == 99 {
                keep(cx.step(.conversationStarted(at), mind: Kit.snap(), at: at))
                keep(cx.flush(at: at))
            }
        }
        let applied = try await store.apply(writes)
        #expect(applied.failed.isEmpty)
        try await store.checkpoint()
        let r = try await Self.leaks(utterances, store: store, url: url)
        #expect(r.bytes > 0)
        #expect(r.grams > 1000)
        #expect(r.leaked.isEmpty, "stored 5-grams: \(r.leaked.prefix(3))")
    }

    /// Canary for the fuzz (review finding 13): a planted text-bearing write is caught,
    /// both in a stored value and in the raw file bytes.
    @Test func noTranscriptFuzzCatchesAPlantedLeak() async throws {
        let url = SelfStoreTests.tempURL("canary")
        let store = try SelfStore(url: url)
        let utterance = ["my", "neighbour", "practises", "tuba", "every", "thursday", "morning"]
        var leaky = SelfStoreTests.episode(nil)
        leaky.gist = utterance.joined(separator: " ")
        try await store.apply(.episode(leaky))
        try await store.checkpoint()
        let r = try await Self.leaks([utterance], store: store, url: url)
        #expect(r.leaked == Self.windows(utterance.joined(separator: " ")))
        #expect(r.leaked.count == 3)
    }
}
