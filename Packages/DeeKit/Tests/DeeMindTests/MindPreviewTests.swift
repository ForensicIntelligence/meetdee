import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// v0.5 pre-commit appraisal (SELF.md §4.3, contracts-0.5/self.md "Open items"):
/// `Appraiser.evaluate` / `record` / `peek`, `Mind.preview` / `commit(_:as:at:)` and
/// `hear(_:prosody:at:adjust:)`, so the app can run `Cortex.adjust` between appraisal
/// and commit (scenario 4, `tookLiterally`).
@Suite struct MindPreviewTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static let shout = Prosody(loudnessDB: -14, peakDB: -4, speechRate: 3.6)
    static let soft = Prosody(loudnessDB: -40, peakDB: -32, speechRate: 2.4)
    static let normal = Prosody(loudnessDB: -30, peakDB: -20, speechRate: 2.7)

    /// A short conversation mixing kindness, teasing, hostility, repetition and prosody.
    static let script: [(String, Prosody?)] = [
        ("hi Dee, good morning", normal),
        ("you're useless lol", nil),
        ("you're useless", shout),
        ("you're useless", shout),
        ("sorry, I was joking, I love you", soft),
        ("what do you think about the guitar", normal),
        ("THIS IS SO ANNOYING!!!", nil),
        ("thank you, you're really clever", normal),
        ("I'm going to delete you", shout),
        ("never mind, tell me a story", nil),
    ]

    /// Equal apart from `age.since`, which `AgeSettings()` stamps with the wall clock.
    static func same(_ x: InnerState, _ y: InnerState) -> Bool {
        var y = y
        y.age = x.age
        return x == y
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dee-preview-\(UUID().uuidString).sqlite")
    }

    /// Softens hostility the way Interpreter's `tookLiterally` lesson does (× 0.5).
    static func softened(_ a: Appraisal) -> Appraisal {
        var b = a
        b.hostility *= 0.5
        b.valence = max(b.valence, -0.1)
        return b
    }

    // MARK: - Appraiser

    @Test func evaluateThenRecordIsExactlyAppraise() {
        var direct = Appraiser(), split = Appraiser()
        for (text, prosody) in Self.script + Self.script {
            let a = direct.appraise(text, prosody: prosody)
            let (b, footprint) = split.evaluate(text, prosody: prosody)
            split.record(footprint)
            #expect(a == b, "\(text)")
            #expect(direct.baseline == split.baseline)
        }
    }

    @Test func peekAndEvaluateChangeNothing() {
        var ap = Appraiser()
        _ = ap.appraise("hello there friend", prosody: Self.normal)
        let baseline = ap.baseline
        let first = ap.peek("you're useless", prosody: Self.shout)
        for _ in 0 ..< 5 {
            #expect(ap.peek("you're useless", prosody: Self.shout) == first, "no repetition build-up")
            _ = ap.evaluate("you're useless", prosody: Self.shout)
        }
        #expect(ap.baseline == baseline)
        // The real appraisal matches the peek, then repetition starts counting.
        #expect(ap.appraise("you're useless", prosody: Self.shout) == first)
        #expect(ap.baseline.samples == baseline.samples + 1)
    }

    // MARK: - Preview

    @Test func previewCommitsNothing() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        _ = await mind.hear("hi Dee", prosody: Self.normal, at: Self.t0 + 1)
        let state = await mind.state, baseline = await mind.voiceBaseline
        let seq = await mind.snapshot(at: Self.t0 + 2).sequence
        for k in 0 ..< 4 { _ = await mind.preview("you're useless", prosody: Self.shout); _ = k }
        #expect(await mind.state == state)
        #expect(await mind.voiceBaseline == baseline)
        let after = await mind.snapshot(at: Self.t0 + 2)
        #expect(after.sequence == seq + 1, "preview hands out no snapshot")

        // A twin that never previewed hears the same thing identically.
        let twin = try Mind(databaseURL: nil, now: Self.t0)
        _ = await twin.hear("hi Dee", prosody: Self.normal, at: Self.t0 + 1)
        // Same clock path as `mind` (snapshot(at:) advances time; decay composed in
        // different steps can round one byte differently).
        _ = await twin.snapshot(at: Self.t0 + 2)
        _ = await twin.snapshot(at: Self.t0 + 2)
        let (a1, s1) = await mind.hear("you're useless", prosody: Self.shout, at: Self.t0 + 3)
        let (a2, s2) = await twin.hear("you're useless", prosody: Self.shout, at: Self.t0 + 3)
        #expect(a1 == a2 && s1 == s2 && a1.repetition == 0)
    }

    @Test func previewThenCommitEqualsHear() async throws {
        let urlA = Self.tempURL(), urlB = Self.tempURL()
        defer { for u in [urlA, urlB] { try? FileManager.default.removeItem(at: u) } }
        let heard = try Mind(databaseURL: urlA, now: Self.t0)
        let staged = try Mind(databaseURL: urlB, now: Self.t0)
        var t = Self.t0
        for (text, prosody) in Self.script {
            t += 7
            let (a, s) = await heard.hear(text, prosody: prosody, at: t)
            let p = await staged.preview(text, prosody: prosody)
            #expect(p.appraisal == a, "\(text)")
            let s2 = await staged.commit(p, at: t)
            #expect(s2 == s && s2.reflex == s.reflex && s2.reflexAt == s.reflexAt && s2.sequence == s.sequence, "\(text)")
            #expect(Self.same(await staged.state, await heard.state))
            #expect(await staged.voiceBaseline == heard.voiceBaseline)
        }
        // Same daily aggregate (state and day rows), and it survives a reopen.
        let ha = await heard.history(), hb = await staged.history()
        #expect(ha.map(\.day) == hb.map(\.day) && ha.map(\.interactions) == hb.map(\.interactions))
        #expect(zip(ha, hb).allSatisfy { abs($0.regard - $1.regard) < 1e-12 })
        #expect(ha.first?.interactions == Self.script.count)
        let rowsA = try SQLiteStore(path: urlA.path(percentEncoded: false)).query("SELECT * FROM daily")
        let rowsB = try SQLiteStore(path: urlB.path(percentEncoded: false)).query("SELECT * FROM daily")
        #expect(rowsA == rowsB)
        let reopened = try Mind(databaseURL: urlB, now: t)
        #expect(await reopened.voiceBaseline == heard.voiceBaseline)
    }

    @Test func hearWithIdentityAdjustEqualsHear() async throws {
        let a = try Mind(databaseURL: nil, now: Self.t0), b = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        for (text, prosody) in Self.script {
            t += 5
            let x = await a.hear(text, prosody: prosody, at: t)
            let y = await b.hear(text, prosody: prosody, at: t) { $0 }
            #expect(x.appraisal == y.appraisal && x.snapshot == y.snapshot)
        }
        #expect(Self.same(await a.state, await b.state))
    }

    // MARK: - Adjusted commit (scenario 4 shape)

    @Test func softenedTeaseRaisesLessAnger() async throws {
        let plain = try Mind(databaseURL: nil, now: Self.t0), adjusted = try Mind(databaseURL: nil, now: Self.t0)
        let before = await plain.snapshot(at: Self.t0 + 1).code.feelings[.anger]
        let (raw, s1) = await plain.hear("you're useless", at: Self.t0 + 2)
        let p = await adjusted.preview("you're useless")
        #expect(p.appraisal == raw)
        let s2 = await adjusted.commit(p, as: Self.softened(p.appraisal), at: Self.t0 + 2)
        #expect(raw.hostility > 0.3, "the tease reads as hostile on its own")
        let rise1 = s1.code.feelings[.anger] - before, rise2 = s2.code.feelings[.anger] - before
        #expect(rise1 > 0 && rise2 < rise1, "softened: \(rise2) vs \(rise1)")
        #expect(s2.regard > s1.regard)
        // The appraiser moved the same way either way (it is text-driven, not adjusted).
        #expect(await adjusted.voiceBaseline == plain.voiceBaseline)
        let again1 = await plain.preview("you're useless"), again2 = await adjusted.preview("you're useless")
        #expect(again1.appraisal == again2.appraisal && again1.appraisal.repetition > 0)
    }

    @Test func hearAdjustReturnsAndCommitsTheAdjustedAppraisal() async throws {
        let a = try Mind(databaseURL: nil, now: Self.t0), b = try Mind(databaseURL: nil, now: Self.t0)
        let (adj, s1) = await a.hear("you're useless", prosody: Self.shout, at: Self.t0 + 1, adjust: Self.softened)
        let p = await b.preview("you're useless", prosody: Self.shout)
        let s2 = await b.commit(p, as: Self.softened(p.appraisal), at: Self.t0 + 1)
        #expect(adj == Self.softened(p.appraisal) && adj != p.appraisal)
        #expect(s1 == s2 && s1.reflex == s2.reflex)
        #expect(Self.same(await a.state, await b.state))
    }

    @Test func dailyAggregateJudgesTheCommittedAppraisal() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let mind = try Mind(databaseURL: url, now: Self.t0)
        let p = await mind.preview("you're stupid and useless", prosody: Self.shout)
        #expect(p.appraisal.kindness < -0.25)
        var calm = p.appraisal
        calm.hostility = 0; calm.valence = 0; calm.dismissal = 0
        await mind.commit(p, as: calm, at: Self.t0 + 1)
        let rows = try SQLiteStore(path: url.path(percentEncoded: false)).query("SELECT interactions, hostile, kind FROM daily")
        #expect(rows.count == 1)
        #expect(rows.first?["interactions"]?.double == 1 && rows.first?["hostile"]?.double == 0)
        let text = try SQLiteStore(path: url.path(percentEncoded: false)).query("SELECT * FROM meta").map { "\($0)" }.joined()
        #expect(!text.contains("useless") && !text.contains("stupid"), "no utterance text is stored")
    }

    @Test func internalAppraisalCanBeCommittedForHeardText() async throws {
        // Any appraisal may be committed; the preview only supplies the footprint.
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let p = await mind.preview("phew, it worked", prosody: Self.normal)
        let s = await mind.commit(p, as: .internal(relief: 0.8), at: Self.t0 + 1)
        #expect(s.reflex == .relieved)
        #expect(await mind.voiceBaseline.samples == 1)
    }

    // MARK: - Ordering and misuse

    @Test func interleavedHearKeepsBothFootprints() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let p = await mind.preview("tell me about the guitar", prosody: Self.normal)
        _ = await mind.hear("good morning", prosody: Self.soft, at: Self.t0 + 1)
        await mind.commit(p, at: Self.t0 + 2)
        #expect(await mind.voiceBaseline.samples == 2)
        // Reference: the same footprints recorded in commit order.
        var ref = Appraiser()
        _ = ref.appraise("good morning", prosody: Self.soft)
        ref.record(p.footprint)
        #expect(await mind.voiceBaseline == ref.baseline)
        // The guitar line is now in the repetition window.
        #expect(await mind.preview("tell me about the guitar").appraisal.repetition > 0.6)
    }

    @Test func doubleCommitCountsTheUtteranceOnce() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let p = await mind.preview("you're useless", prosody: Self.shout)
        let s1 = await mind.commit(p, at: Self.t0 + 1)
        let s2 = await mind.commit(p, at: Self.t0 + 2)
        #expect(await mind.voiceBaseline.samples == 1)
        #expect(s2.code.feelings[.anger] >= s1.code.feelings[.anger], "the appraisal itself is absorbed each time")
        #expect(await mind.state.interactions == 2)
    }

    @Test func stalePreviewSkipsTheFootprintOnly() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let old = await mind.preview("hello", prosody: Self.normal)
        for k in 0 ..< Mind.maxOutstandingPreviews { _ = await mind.preview("filler \(k)", prosody: Self.normal) }
        let before = await mind.state.interactions
        await mind.commit(old, at: Self.t0 + 1)
        #expect(await mind.voiceBaseline.samples == 0, "too old: footprint dropped")
        #expect(await mind.state.interactions == before + 1, "but it still counts as heard")
    }

    @Test func foreignPreviewIsNotRecorded() async throws {
        let a = try Mind(databaseURL: nil, now: Self.t0), b = try Mind(databaseURL: nil, now: Self.t0)
        let pa = await a.preview("hello", prosody: Self.normal)
        let pb = await b.preview("hello", prosody: Self.normal)    // same serial, other Mind
        await b.commit(pa, at: Self.t0 + 1)
        #expect(await b.voiceBaseline.samples == 0, "another Mind's preview never records")
        #expect(await b.state.interactions == 1)
        await b.commit(pb, at: Self.t0 + 2)
        #expect(await b.voiceBaseline.samples == 1, "b's own preview is still outstanding")
    }

    @Test func resetForgetsOutstandingPreviews() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let p = await mind.preview("hello", prosody: Self.loud)
        await mind.reset(at: Self.t0 + 1)
        await mind.commit(p, at: Self.t0 + 2)
        #expect(await mind.voiceBaseline == Appraiser.VoiceBaseline())
    }

    static let loud = Prosody(loudnessDB: -18, peakDB: -8, speechRate: 3.2)

    @Test func deterministicReplay() async throws {
        func run() async throws -> [MindSnapshot] {
            let mind = try Mind(databaseURL: nil, now: Self.t0)
            var out: [MindSnapshot] = []
            var t = Self.t0
            for (i, (text, prosody)) in Self.script.enumerated() {
                t += 4
                let p = await mind.preview(text, prosody: prosody)
                out.append(await mind.commit(p, as: i.isMultiple(of: 2) ? Self.softened(p.appraisal) : nil, at: t))
            }
            return out
        }
        let a = try await run(), b = try await run()
        #expect(a == b && a.map(\.reflex) == b.map(\.reflex))
    }
}
