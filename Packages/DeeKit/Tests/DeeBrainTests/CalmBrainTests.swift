import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Spec "calm" (brain half; scratchpad calm/spec.md §4.2, §3.3, §7.2): the user found 0.6.0
/// "too sensitive to interruptions" (the TV, their own mm-hm / laughs / coughs). The voice now
/// ducks Dee for a sound and pauses Dee only for a real interruption; the brain must agree:
/// it never answers failed words of an item the voice's hold decides, never the TV's words
/// over a ducked Dee, and still answers a real question exactly once.
@MainActor
@Suite(.serialized) struct CalmBrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    // MARK: 1. The `wordsFailed` race (RB:1779), both pump orders

    /// The transcription failed while the voice still ducks Dee for the item: the brain does
    /// not answer the audio; the voice lets Dee go on (`duckWordsWait`).
    @Test func failedWordsBeforeTheUnduckAreNeverAnswered() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_x", talk: 0.3)
        #expect(rig.voice.floorHold?.phase == .ducked)
        rig.push(Srv.speechStopped("item_x", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_x"),
                 Srv.transcriptFailed("item_x"))
        #expect(await rig.until { rig.brain.trace.contains(.holdClaimed) }, "\(rig.brain.trace)")
        for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "Dee never went on")
        #expect(rig.responseCreates().count == 1, "the failed words were answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        rig.shutdown()
    }

    /// The voice already let Dee go on (no words in `duckWordsWait`) when the failure comes:
    /// still never answered — the voice claims the item for `recentlyResolvedTTL`.
    @Test func failedWordsAfterTheUnduckAreNeverAnswered() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_x", talk: 0.3)
        rig.push(Srv.speechStopped("item_x", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_x"))
        await rig.settle()
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "the duck never ended")
        #expect(rig.voice.holdClaims(itemID: "item_x"))
        rig.push(Srv.transcriptFailed("item_x"))
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 1, "the failed words were answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        // Long after: the voice no longer claims it (today's rules decide again).
        try rig.quiet(CalmTuning.recentlyResolvedTTL + 1)
        #expect(!rig.voice.holdClaims(itemID: "item_x"))
        rig.shutdown()
    }

    /// Calm off: the race guard does nothing (byte-for-byte 0.6.0).
    @Test func calmOffNeverClaims() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: false)
        try await rig.start()
        try await T10.pausedBy(rig, "item_x", talk: 0.3)
        #expect(rig.voice.floorHold?.phase == .paused)
        #expect(!rig.voice.holdClaims(itemID: "item_x"))
        #expect(!rig.voice.isAmbient(itemID: "item_x", text: "In tonight's news."))
        rig.shutdown()
    }

    // MARK: 2. The TV over a ducked Dee in a TV room

    /// 1 s cycles: 0.4 s of a talker (voice-like, −33 dBFS), 0.6 s of quieter sound.
    @MainActor final class TV {
        private var i = 0
        let talk = pow(10, -33.0 / 20) / 0.4318
        func step(_ rig: BrainRig) throws {
            let n = Int(BrainRig.rate * 0.02)
            let on = i % 50 < 20
            try rig.step(on ? Sig.harmonic(hz: 210, amplitude: talk, rate: BrainRig.rate, seconds: 0.02)
                            : Sig.noise(amplitude: 0.0109, count: n, seed: UInt64(i + 101)))
            i += 1
        }
        func run(_ rig: BrainRig, _ seconds: Double) async throws {
            for k in 0..<Int((seconds / 0.02).rounded()) {
                try step(rig)
                if k % 5 == 4 { await rig.settle() }
            }
        }
    }

    @Test func theTVOverADuckedDeeIsNeverAnswered() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        let tv = TV()
        try await tv.run(rig, 7)
        try #require(rig.voice.earBed.tvLike, "the bed was not learned as a TV")
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<80 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100, amplitude: 0.03))) }
        rig.push(Srv.transcript("resp_1", "item_a1", "So the filing system is a mystery puzzle. It goes on and on."),
                 Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        await rig.settle()
        try await tv.run(rig, 0.8)
        // A TV peak 4 dB over its ceiling (under the TV bar), the TV pausing for it.
        let ceiling = try #require(rig.voice.earBed.ceilingDB)
        let peak = Sig.harmonic(hz: 210, amplitude: pow(10, (ceiling + 4) / 20) / 0.4318, rate: BrainRig.rate, seconds: 0.6)
        let size = Int(BrainRig.rate * 0.02)
        for (k, i) in stride(from: 0, to: peak.count - size + 1, by: size).enumerated() {
            try rig.step(Array(peak[i..<(i + size)]))
            if k == 7 {
                await rig.settle()
                rig.push(Srv.speechStarted("item_tv", ms: max(0, await T10.settledUplinkMs(rig) - 160)))
                await rig.settle()
            }
        }
        await rig.settle()
        #expect(rig.voice.floorHold?.phase == .ducked, "\(String(describing: rig.voice.floorHold))")
        try await tv.run(rig, 0.3)
        rig.push(Srv.speechStopped("item_tv", ms: await T10.settledUplinkMs(rig) - 300), Srv.committed("item_tv"))
        await rig.settle()
        try await tv.run(rig, 0.15)
        T2.deltas(rig, "item_tv", "In tonight's news, the")        // early words: ≥ 3, can't be "go on"
        try await tv.run(rig, 0.3)
        rig.push(Srv.userTranscript("item_tv", "In tonight's news, the mayor said."))
        for _ in 0..<10 { try await tv.run(rig, 0.1) }
        // The voice's verdict (settled words) or the brain's own check (early / full words)
        // dropped it — whichever came first; never an answer.
        #expect(rig.brain.trace.contains(.ambient), "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.backchannel("resumed-duck-ambient")), "the TV is no backchannel")
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "the TV was answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "Dee was cut for the TV: \(rig.trail())")
        #expect(rig.voice.floorHold == nil)
        #expect(await rig.until { rig.trail().contains("delete:item_tv") }, "the TV's item stayed: \(rig.trail())")
        rig.shutdown()
    }

    // MARK: 3. A real question over a ducked Dee

    /// "Hold on, what time is it?" (1.2 s of voice): sustained → paused → exactly one reply,
    /// which ends Dee's reply as in 0.6.0.
    @Test func holdOnWhatTimeIsItGetsExactlyOneAnswer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_q", talk: 1.2)
        #expect(rig.voice.floorHold?.phase == .paused && rig.voice.floorHold?.why == "sustained",
                "\(String(describing: rig.voice.floorHold))")
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        T2.deltas(rig, "item_q", "Hold on, what time is it?")
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_q", "Hold on, what time is it?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 2, "one answer: \(rig.trail())")
        #expect(rig.trail().filter { $0 == "truncate:item_a1" }.count == 1, "\(rig.trail())")
        rig.shutdown()
    }

    // MARK: 4. Tune 10 T9-1 while ducked

    /// The live echo10 c05 shape with calm on (Dee ducked, not paused): once the brain said
    /// "go on", Dee is never cut (`holdAfterWords` / the duck's deadlines), and goes on.
    @Test func theBrainsGoOnStillWinsWhileDucked() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_c", talk: 1.3)
        let end = await T10.settledUplinkMs(rig)
        rig.push(Srv.speechStopped("item_c", ms: end), Srv.committed("item_c"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_c", "Be sneaking, going.")
        rig.push(Srv.speechStarted("item_l", ms: end + 20))
        try await T10.talk(rig, 0.32)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_c", "Be sneaking, going."))
        try await T10.talk(rig, 1.2)
        #expect(rig.voice.floorHold != nil, "never cut over them")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_l", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_l"))
        T2.deltas(rig, "item_l", "I'm listening.")
        rig.push(Srv.userTranscript("item_l", "I'm listening."))
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "Dee went on")
        #expect(!rig.trail().contains("truncate:item_a1"), "Dee's reply is not cut: \(rig.trail())")
        #expect(rig.responseCreates().count == 1, "no carry-on in Dee's place: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }
}
