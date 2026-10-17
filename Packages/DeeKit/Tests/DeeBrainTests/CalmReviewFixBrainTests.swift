import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Calm review fixes (brain + voice together, scratchpad calm/review-regress.md and
/// review-correct.md). Each reproduction runs with calm on; the flag-off twin pins 0.6.0.
@MainActor
@Suite(.serialized) struct CalmReviewFixBrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    // MARK: regress F3 — a sustained question whose transcription failed

    /// The user talks 1.2 s over Dee ("Hold on, what time is it?"): sustained → paused; the
    /// transcription fails. `laugh`: a laughter label lay over the burst (a long laugh).
    func sustainedFailed(calm: Bool, laugh: Bool = false) async throws -> (creates: Int, cut: Bool, trace: [BrainTrace], resumed: Bool) {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: calm)
        try await rig.start()
        let t0 = rig.graph.now
        try await T10.pausedBy(rig, "item_q", talk: 1.2)
        if laugh { rig.voice.classifiedForTesting([("laughter", 0.8)], window: (t0 + 1.0)...rig.graph.now) }
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        try rig.quiet(0.3)
        rig.push(Srv.transcriptFailed("item_q"))
        for _ in 0..<40 { try rig.quiet(0.1); await rig.settle() }
        let r = (rig.responseCreates().count, rig.trail().contains("truncate:item_a1"), rig.brain.trace,
                 rig.brain.trace.contains(.backchannel("resumed-nowords")))
        rig.shutdown()
        return r
    }

    @Test func aSustainedQuestionWithFailedWordsIsAnswered_calm() async throws {
        let r = try await sustainedFailed(calm: true)
        #expect(r.creates == 2, "the interrupting question was never answered: \(r.trace)")
        #expect(r.cut, "Dee went on over a question")
        #expect(!r.trace.contains(.holdClaimed), "\(r.trace)")
    }

    @Test func aSustainedQuestionWithFailedWordsIsAnswered_flagOff() async throws {
        let r = try await sustainedFailed(calm: false)
        #expect(r.creates == 2)
        #expect(r.cut)
    }

    /// The same burst labelled a laugh: R5 still lets Dee go on, nothing answered.
    @Test func aLabelledSustainedLaughWithFailedWordsStillResumes() async throws {
        let r = try await sustainedFailed(calm: true, laugh: true)
        #expect(r.creates == 1, "a long laugh was answered: \(r.trace)")
        #expect(!r.cut)
        #expect(r.trace.contains(.holdClaimed), "\(r.trace)")
    }

    // MARK: regress F2 / correct F2 — the reply played out under the duck, then failed words

    func playedOutFailed(calm: Bool) async throws -> (creates: Int, trace: [BrainTrace], playedOut: Bool) {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: calm)
        try await rig.start()
        try rig.quiet(0.3)
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<12 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_1", "item_a1", "What would you like to do?"),
                 Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        try rig.quiet(0.6)
        await rig.settle()
        try await T10.talk(rig, 0.15)
        rig.push(Srv.speechStarted("item_q", ms: max(0, await T10.settledUplinkMs(rig) - 150)))
        await rig.settle()
        try await T10.talk(rig, 0.25)
        for _ in 0..<6 { try rig.quiet(0.1); await rig.settle() }       // Dee's 1.2 s plays out
        let playedOut = rig.voice.duckPlayedOut(itemID: "item_q")
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        try rig.quiet(0.3)
        rig.push(Srv.transcriptFailed("item_q"))
        for _ in 0..<80 { try rig.quiet(0.1); await rig.settle() }
        let r = (rig.responseCreates().count, rig.brain.trace, playedOut)
        rig.shutdown()
        return r
    }

    @Test func aTurnBegunOverDeesLastWordsIsAnsweredWhenItsWordsFail_calm() async throws {
        let r = try await playedOutFailed(calm: true)
        #expect(r.playedOut, "the reply did not play out under the duck (the probe is vacuous)")
        #expect(r.creates == 2, "their turn was never answered: \(r.trace)")
        #expect(!r.trace.contains(.holdClaimed), "\(r.trace)")
    }

    @Test func aTurnBegunOverDeesLastWordsIsAnsweredWhenItsWordsFail_flagOff() async throws {
        let r = try await playedOutFailed(calm: false)
        #expect(r.creates == 2)
    }

    // MARK: regress F1 — Dee's echo opens a new item under the duck

    static let herLine = "So the filing system is a mystery puzzle. It goes on and on."

    func echoItem(calm: Bool, duckFirst: Bool) async throws -> (creates: Int, cut: Bool, joined: Bool, ducked: Bool) {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: calm)
        try await rig.start()
        try rig.quiet(0.3)
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<80 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_1", "item_a1", Self.herLine), Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        try rig.quiet(0.6)
        await rig.settle()
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the filing system is a mystery puzzle."))
        var ducked = false
        if duckFirst {
            try await T10.talk(rig, 0.15)
            rig.push(Srv.speechStarted("item_m", ms: max(0, await T10.settledUplinkMs(rig) - 150)))
            await rig.settle()
            try await T10.talk(rig, 0.2)
            ducked = rig.voice.floorHold?.phase == .ducked
            try rig.quiet(0.1); await rig.settle()
        }
        // Dee's echo opens a server item (no near-end voice at the mic).
        rig.push(Srv.speechStarted("item_e", ms: max(0, await T10.settledUplinkMs(rig) - 100)))
        await rig.settle()
        for _ in 0..<5 { try rig.quiet(0.1); await rig.settle() }
        let joined = rig.voice.floorHold?.items.contains("item_e") == true
        rig.push(Srv.speechStopped("item_e", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_e"))
        await rig.settle()
        T2.deltas(rig, "item_e", "the filing system is a mystery")
        try rig.quiet(0.2); await rig.settle()
        rig.push(Srv.userTranscript("item_e", "The filing system is a mystery puzzle."))
        for _ in 0..<30 { try rig.quiet(0.1); await rig.settle() }
        let r = (rig.responseCreates().count, rig.trail().contains("truncate:item_a1"), joined, ducked)
        rig.shutdown()
        return r
    }

    @Test func deesEchoUnderTheDuckNeverCutsDee() async throws {
        let r = try await echoItem(calm: true, duckFirst: true)
        #expect(r.ducked, "the mm-hm did not duck Dee (the probe is vacuous)")
        #expect(!r.joined, "Dee's echo joined the hold")
        #expect(!r.cut, "Dee's own echo cut Dee")
        #expect(r.creates == 1, "Dee's own echo was answered")
    }

    @Test func deesEchoWithNoDuckNeverCutsDee() async throws {
        let r = try await echoItem(calm: true, duckFirst: false)
        #expect(!r.cut)
        #expect(r.creates == 1)
    }
}
