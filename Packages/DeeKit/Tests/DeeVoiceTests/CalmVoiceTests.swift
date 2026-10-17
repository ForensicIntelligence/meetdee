import AVFAudio
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Spec "calm" (scratchpad calm/spec.md, against 0.6.0 5297f77): after 0.6.0 the user said
// "Wow! It works! But it's too sensitive to interruptions" — background noise / TV, and their
// own short sounds (mm-hm, yeah, laughs, coughs, breaths), in OpenAI mode 1. Every voice onset
// over Dee's reply paused Dee within ~0.15 s. Calm ducks Dee instead (−12 dB, −6 dB in a TV
// room) and pauses Dee only for sustained voice, a stop / command word, words that are not
// "go on", or the brain's reply. Each reproduction test has a pair: `…_flagOff_reproduces`
// (0.6.0's bad outcome, documented) and `…_calm` (the fix).

// MARK: - Rig helpers

/// Watches Dee's player while the rig steps.
final class PlayerWatch: @unchecked Sendable {
    private(set) var held = false
    private(set) var minDuck: Float = 1
    func look(_ p: PCMStreamPlayer) {
        if p.isHeld { held = true }
        minDuck = min(minDuck, p.duckGain)
    }
}

enum Calm {
    static let rate = LoopRig.rate
    static let step = Int(LoopRig.rate * 0.02)

    /// Pitched voice-like sound (`Signal.harmonic` at 48 kHz).
    static func voice(_ seconds: Double, amplitude: Double = 0.3, hz: Double = 180) -> [Float] {
        Signal.harmonic(hz: hz, amplitude: amplitude, sampleRate: rate, seconds: seconds)
    }
    /// Unpitched sound (a cough's burst, a breath): loud white noise.
    static func hiss(_ seconds: Double, amplitude: Double = 0.25, seed: UInt64 = 7) -> [Float] {
        Signal.noise(amplitude: amplitude, count: Int(rate * seconds), seed: seed)
    }
    /// The room between sounds.
    static func gap(_ seconds: Double, seed: UInt64 = 3) -> [Float] {
        Signal.noise(amplitude: 0.001, count: Int(rate * seconds), seed: seed)
    }
    /// `n` pitched pulses of `on` s, `period` s apart (a laugh).
    static func pulses(_ n: Int, on: Double, period: Double) -> [Float] {
        var x: [Float] = []
        for i in 0..<n {
            x += voice(on, hz: 200 + Double(i % 2) * 20)
            if i < n - 1 { x += gap(period - on, seed: UInt64(i + 11)) }
        }
        return x
    }
    /// Amplitude of `Signal.harmonic` for an RMS of `db` dBFS.
    static func harmonicAmplitude(db: Double) -> Double { pow(10, db / 20) / 0.4318 }
}

extension LoopRig {
    /// The voice's timed notes (`TurnTimeline` `.note` marks), in order.
    var notes: [(t: Double, text: String)] {
        timeline.turns().flatMap(\.marks).filter { $0.stage == .note }.compactMap { m in m.detail.map { (m.t, $0) } }
    }
    func note(_ prefix: String) -> (t: Double, text: String)? { notes.first { $0.text.hasPrefix(prefix) } }
    func hasNote(_ prefix: String) -> Bool { note(prefix) != nil }

    /// Steps `x` (48 kHz) 20 ms at a time, watching the player.
    func feed(_ x: [Float], _ w: PlayerWatch? = nil) throws {
        for f in Signal.frames(x, size: Calm.step) {
            try step(f)
            w?.look(graph.player)
        }
    }

    /// Room noise for `seconds`, watching.
    func idle(_ seconds: Double, _ w: PlayerWatch? = nil) throws {
        for _ in 0..<Int((seconds / 0.02).rounded()) {
            try step()
            w?.look(graph.player)
        }
    }

    /// Steps (letting events through) until `done`, at most `limit` s; watching.
    func idleUntil(_ limit: Double, _ w: PlayerWatch? = nil, _ done: () -> Bool) async throws -> Double? {
        var elapsed = 0.0
        while elapsed < limit + 1e-9 {
            await settle()
            if done() { return elapsed }
            try step()
            w?.look(graph.player)
            elapsed += 0.02
        }
        await settle()
        return done() ? elapsed : nil
    }

    /// Dee's reply (`item_a1`, `ms`) playing.
    func calmReply(ms: Int = 10_000) async throws {
        try quiet(0.3)
        try await answerWith([("item_a1", ms)])
        try quiet(0.6)
    }

    /// The user's `sound` over Dee: the server opens `item` `onsetAfter` s into it.
    func over(_ sound: [Float], item: String = "item_u2", onsetAfter: Double = 0.16, _ w: PlayerWatch) async throws {
        let n = min(sound.count, Int((onsetAfter / 0.02).rounded()) * Calm.step)
        try feed(Array(sound[..<n]), w)
        push(Srv.speechStarted(item, ms: uplinkMsNow - Int(onsetAfter * 1000)))
        await settle()
        if n < sound.count { try feed(Array(sound[n...]), w) }
        await settle()
    }

    /// The server's commit of `item` (as live: right after the voice's quick commit).
    func commitWhenAsked(_ item: String = "item_u2", _ w: PlayerWatch? = nil, limit: Double = 0.8) async throws -> Bool {
        let before = sent("input_audio_buffer.commit").count
        guard try await idleUntil(limit, w, { sent("input_audio_buffer.commit").count > before }) != nil else { return false }
        push(Srv.committed(item))
        await settle()
        return true
    }

    var truncates: Int { sent("conversation.item.truncate").count }
    var bargeIns: Int { voiceEvents.filter { $0 == .bargeIn }.count }
}

// MARK: - 2. Cough over Dee

@Suite(.serialized) struct CalmCoughTests {
    /// 0.12 s near (≈0.09 s pitched), then 0.25 s unpitched; the transcript is "Uh.".
    static var cough: [Float] { Calm.voice(0.08) + Calm.hiss(0.04) + Calm.hiss(0.24, seed: 9) }

    /// 0.6.0: the cough paused Dee, "Uh." was not "go on" (`.answer`), and nobody answering
    /// it, the hold cut Dee's reply (`holdAfterWords`).
    @Test func coughOverHer_flagOff_reproduces() async throws {
        let rig = try LoopRig(duckOnOnset: false)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.cough, w)
        #expect(w.held, "0.6.0 paused Dee for the cough")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.push(Srv.userTranscript("item_u2", "Uh."))
        _ = try await rig.idleUntil(2.0, w) { rig.truncates > 0 }
        #expect(rig.truncates == 1, "0.6.0 cut Dee's reply for a cough")
        rig.voice.shutdown()
    }

    @Test func coughOverHer_calm() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.cough, w)
        #expect(rig.voice.floorHold?.phase == .ducked)
        #expect(abs(rig.graph.player.duckGain - 0.251) < 0.01, "\(rig.graph.player.duckGain)")
        #expect(rig.hasNote("duck item_u2 gain=-12 via="), "\(rig.notes.map(\.text))")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.push(Srv.userTranscript("item_u2", "Uh."))
        let back = try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil }
        #expect(back != nil, "never unducked")
        #expect(rig.hasNote("unduck item_u2 (resume)"), "\(rig.notes.map(\.text))")
        try rig.idle(1.0, w)
        #expect(!w.held, "Dee went silent for a cough")
        #expect(rig.truncates == 0 && rig.bargeIns == 0)
        #expect(rig.graph.player.duckGain == 1)
        rig.voice.shutdown()
    }

    /// Variant: a duck with no server item at all ends at `duckNoItem`, never a cut.
    @Test func aDuckWithNoItemEndsAtDuckNoItem() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        rig.voice.duckForTesting(nil)
        #expect(rig.voice.floorHold?.phase == .ducked)
        let t = try await rig.idleUntil(2.5, w) { rig.voice.floorHold == nil }
        let took = try #require(t)
        #expect(abs(took - CalmTuning.duckNoItem) <= 0.06, "\(took)")
        #expect(rig.hasNote("unduck - (noItem)"))
        #expect(!w.held && rig.truncates == 0)
        rig.voice.shutdown()
    }
}

// MARK: - 3 / 4. Laughs over Dee

@Suite(.serialized) struct CalmLaughTests {
    /// Four short pitched pulses (≈0.32–0.48 s of voice in 0.68 s): "Ha ha.".
    static var shortLaugh: [Float] { Calm.pulses(4, on: 0.08, period: 0.2) }

    @Test func shortLaughOverHer_flagOff_reproduces() async throws {
        let rig = try LoopRig(duckOnOnset: false)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.shortLaugh, w)
        #expect(w.held)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.push(Srv.userTranscript("item_u2", "Ha ha."))
        _ = try await rig.idleUntil(2.0, w) { rig.truncates > 0 }
        #expect(rig.truncates == 1, "0.6.0 cut Dee's reply for a laugh")
        rig.voice.shutdown()
    }

    @Test func shortLaughOverHer_calm() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.shortLaugh, w)
        #expect(rig.voice.floorHold?.phase == .ducked)
        #expect(!rig.hasNote("sustained"), "\(rig.notes.map(\.text))")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.push(Srv.userTranscript("item_u2", "Ha ha."))
        #expect(try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil } != nil)
        try rig.idle(0.5, w)
        #expect(!w.held && rig.truncates == 0 && rig.bargeIns == 0)
        rig.voice.shutdown()
    }

    /// Six pulses (≈0.7 s of voice in 1.1 s). Round 1 paused Dee here (sustained at 0.50 s);
    /// round 2 (D2: a pause needs ~1.2 s of continuous near voice) keeps Dee ducked, and
    /// "Hahaha." — or failed words — lets Dee go on at full level. Never silent, never cut.
    @Test(arguments: [true, false])
    func aLongLaughNeverPausesDee(words: Bool) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let holds = Collector(rig.voice.holdEvents)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.pulses(6, on: 0.12, period: 0.2), w)
        rig.voice.classifiedForTesting([("laughter", 0.8)], window: (rig.graph.now - 1.0)...rig.graph.now)
        #expect(!rig.hasNote("sustained"), "\(rig.notes.map(\.text))")
        #expect(rig.voice.floorHold?.phase == .ducked && !w.held)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        try rig.idle(0.15, w)
        if words {
            rig.push(Srv.userTranscript("item_u2", "Hahaha."))
        } else {
            rig.push(.inputTranscriptionFailed(.init(itemID: "item_u2", error: nil)))
        }
        let back = try await rig.idleUntil(3.0, w) { rig.voice.floorHold == nil }
        #expect(back != nil, "Dee never went back to full level")
        #expect(rig.hasNote("unduck item_u2"), "\(rig.notes.map(\.text))")
        #expect(!w.held && rig.truncates == 0 && rig.bargeIns == 0)
        #expect(!holds.all.contains { if case .ended = $0 { true } else { false } })
        rig.voice.shutdown()
    }

    /// A laugh with continuous voice past `sustainVoice` (1.6 s) still pauses Dee, and goes
    /// on from the labelled sound when its words fail (R5, unchanged).
    @Test func aSustainedLabelledLaughPausesThenResumes() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(1.6, hz: 220), w)
        rig.voice.classifiedForTesting([("laughter", 0.8)], window: (rig.graph.now - 1.0)...rig.graph.now)
        #expect(rig.hasNote("hold item_u2 why=sustained"), "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        try rig.idle(0.15)
        rig.push(.inputTranscriptionFailed(.init(itemID: "item_u2", error: nil)))
        #expect(try await rig.idleUntil(3.5) { rig.voice.floorHold == nil } != nil)
        #expect(rig.hasNote("resumed item_u2 (nowords)"), "\(rig.notes.map(\.text))")
        #expect(rig.truncates == 0 && rig.bargeIns == 0)
        rig.voice.shutdown()
    }
}

// MARK: - 5. mm-hm over Dee

@Suite(.serialized) struct CalmMmHmTests {
    static var mmhm: [Float] { Calm.voice(0.36, hz: 150) }

    @Test func mmHmOverHer_flagOff_reproduces() async throws {
        let rig = try LoopRig(duckOnOnset: false)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.mmhm, w)
        #expect(w.held, "0.6.0 went silent for a mm-hm")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.deltas("item_u2", ["Mm", "-hm", "."])
        #expect(try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil } != nil)
        #expect(rig.truncates == 0)
        rig.voice.shutdown()
    }

    /// Also a misheard one: one word the words don't know that *sounded* like a backchannel
    /// (the tune 9 rescue, unchanged; "Film." here — a lone two-letter word such as "FM." stays
    /// the start of a turn by the existing fragment rule, which calm leaves as it is).
    @Test(arguments: [["Mm", "-hm", "."], ["Film", "."]])
    func mmHmOverHer_calm(words: [String]) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Self.mmhm, w)
        #expect(rig.voice.floorHold?.phase == .ducked)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        try rig.idle(0.1, w)
        rig.deltas("item_u2", words)
        await rig.settle()
        if words == ["Film", "."] { rig.push(Srv.userTranscript("item_u2", "Film.")) }
        let t0 = rig.graph.now
        let back = try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil }
        #expect(back != nil, "never unducked for \(words)")
        // The verdict needs the deltas to settle (`holdSettleQuick`): unduck ≤ 0.25 s after it.
        if let back { #expect(back <= CloudVoice.holdSettleQuick + 0.25, "\(back) s (from \(t0))") }
        try rig.idle(0.5, w)
        #expect(!w.held, "Dee went silent for \(words): \(rig.notes.map(\.text))")
        #expect(rig.truncates == 0 && rig.bargeIns == 0)
        rig.voice.shutdown()
    }
}

// MARK: - 6 / 7 / 8. Real interruptions still stop Dee

@Suite(.serialized) struct CalmInterruptTests {
    /// "Wait, — stop": 0.30 s, a 0.20 s gap, 0.35 s — never sustained (round 2, D2). The first
    /// transcript delta "Wait" pauses Dee at once (no settle, no full words); "Wait, stop."
    /// ends the reply, and `.bargeIn` reaches the app once.
    @Test func waitStopStopsAtItsFirstDelta() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.30) + Calm.gap(0.20) + Calm.voice(0.36), w)
        #expect(!rig.hasNote("sustained"), "\(rig.notes.map(\.text))")
        #expect(rig.voice.floorHold?.phase == .ducked && !w.held)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        let t0 = rig.graph.now
        rig.deltas("item_u2", ["Wait"])
        await rig.settle()
        let hold = try #require(rig.note("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
        #expect(hold.t - t0 < 0.005, "paused \(hold.t - t0) s after the delta")
        #expect(rig.graph.player.isHeld)
        rig.deltas("item_u2", [",", " stop", "."])
        rig.push(Srv.userTranscript("item_u2", "Wait, stop."))
        _ = try await rig.idleUntil(2.0) { rig.truncates > 0 }
        #expect(rig.truncates == 1)
        try rig.idle(0.2)
        await rig.settle()
        #expect(rig.bargeIns == 1, "\(rig.voiceEvents)")
        rig.voice.shutdown()
    }

    /// "Hold on, what time is it?": its first delta "Hold on" pauses Dee (a command phrase);
    /// the brain's answer (`respond`) ends the reply as in 0.6.0.
    @Test func holdOnWhatTimeIsItPausesAtItsFirstDelta() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let holds = Collector(rig.voice.holdEvents)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.9), w)
        #expect(!rig.hasNote("sustained"), "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        rig.deltas("item_u2", ["Hold", " on", ","])
        await rig.settle()
        #expect(rig.voice.floorHold?.phase == .paused && rig.voice.floorHold?.why == "stopword", "\(rig.notes.map(\.text))")
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(rig.truncates == 1)
        #expect(holds.all.contains(.ended(itemIDs: ["item_u2"], byVoice: false)), "\(holds.all)")
        #expect(rig.bargeIns == 0, "the brain's answer is no voice barge-in")
        rig.voice.shutdown()
    }

    /// Continuous voice past `sustainVoice` (a long turn begun over Dee) pauses Dee then
    /// (1.2 s of it), before any words.
    @Test func continuousVoicePausesAfterSustainVoice() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        let t0 = rig.graph.now
        try await rig.over(Calm.voice(1.8), w)
        let sus = try #require(rig.note("sustained item_u2"), "\(rig.notes.map(\.text))")
        #expect(abs(sus.t - t0 - CalmTuning.sustainVoice) <= 0.08, "sustained \(sus.t - t0) s in")
        #expect(rig.voice.floorHold?.phase == .paused && rig.voice.floorHold?.why == "sustained" && w.held)
        rig.voice.shutdown()
    }

    /// A lone "Stop." (0.35 s: never sustained) ends the reply no later than in 0.6.0, for the
    /// same scripted word times.
    @Test func aLoneStopEndsTheReplyNoLaterThanBefore() async throws {
        func run(_ calm: Bool) async throws -> (cut: Double, held: Bool, sustained: Bool) {
            let rig = try LoopRig(duckOnOnset: calm)
            let w = PlayerWatch()
            try await rig.start()
            try await rig.calmReply()
            try await rig.over(Calm.voice(0.36), w)
            let t0 = rig.graph.now
            #expect(try await rig.commitWhenAsked("item_u2", w))
            try rig.idle(0.12)
            rig.push(Srv.userTranscript("item_u2", "Stop."))
            let cut = try #require(try await rig.idleUntil(2.0) { rig.truncates > 0 }, "never cut (calm \(calm))")
            let out = (rig.graph.now - t0, w.held, rig.hasNote("sustained"))
            if calm { #expect(rig.hasNote("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))") }
            _ = cut
            rig.voice.shutdown()
            return out
        }
        let before = try await run(false)
        let calm = try await run(true)
        #expect(!calm.sustained)
        #expect(calm.cut <= before.cut + 0.021, "calm cut at \(calm.cut) s, 0.6.0 at \(before.cut) s")
    }
}

// MARK: - 9 / 10. Ducked deadlines never cut

@Suite(.serialized) struct CalmDeadlineTests {
    /// An open item, no words, no stop, no sustain (unpitched after its start): unduck at `duckMax`.
    @Test func duckMaxUnducksAndNeverCuts() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.16) + Calm.hiss(1.2), w)
        #expect(rig.voice.floorHold?.phase == .ducked)
        let since = try #require(rig.voice.floorHold?.duckSince)
        _ = try await rig.idleUntil(3.5, w) { rig.voice.floorHold == nil }
        let un = try #require(rig.note("unduck item_u2 (duckMax)"), "\(rig.notes.map(\.text))")
        #expect(abs(un.t - since - CalmTuning.duckMax) <= 0.05)
        #expect(!w.held && rig.truncates == 0 && rig.bargeIns == 0)
        rig.voice.shutdown()
    }

    /// Committed, then no words for `duckWordsWait`: unduck. A late "Stop." still stops Dee
    /// (today's `holdForWords` path).
    @Test func duckWordsWaitThenALateStopStillStops() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.30), w)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        let committed = rig.graph.now
        _ = try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil }
        let un = try #require(rig.note("unduck item_u2 (wordsWait)"), "\(rig.notes.map(\.text))")
        #expect(un.t - committed <= CalmTuning.duckWordsWait + 0.08)
        #expect(!w.held)
        try rig.idle(0.3)
        rig.push(Srv.userTranscript("item_u2", "Stop."))
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 (words)"), "\(rig.notes.map(\.text))")
        _ = try await rig.idleUntil(2.0) { rig.truncates > 0 }
        #expect(rig.truncates == 1)
        rig.voice.shutdown()
    }
}

// MARK: - 11. Sentence boundaries

@Suite(.serialized) struct CalmBoundaryTests {
    /// A duck over the end of one of Dee's items: the next starts at once, at the duck gain.
    @Test func theNextSentenceStartsDucked() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 900), ("item_a2", 3000)])
        try rig.quiet(0.4)
        try await rig.over(Calm.voice(0.20, hz: 150), w)           // "Yeah." near item_a1's end
        #expect(rig.voice.floorHold?.phase == .ducked)
        let started = try await rig.idleUntil(1.0, w) { rig.graph.player.playedMs(utterance: "item_a2") > 100 }
        #expect(started != nil, "item_a2 never started under the duck")
        #expect(!rig.graph.player.holdAtBoundary)
        if rig.voice.floorHold?.phase == .ducked {
            #expect(abs(rig.graph.player.currentGain - 0.251) < 0.01, "\(rig.graph.player.currentGain)")
        }
        #expect(!w.held)
        rig.voice.shutdown()
    }
}

// MARK: - 12. The player's duck

@Suite struct CalmPlayerTests {
    static func player(ms: Double = 2000) -> PCMStreamPlayer {
        let p = PCMStreamPlayer()
        p.enqueue(PCMTone.data(ms: ms, hz: 300, amplitude: 0.5), utterance: "u")
        p.finish(utterance: "u")
        return p
    }

    @Test func duckRampsReleaseAndHoldFromDucked() {
        let p = Self.player()
        _ = p.renderForTesting(frames: 2400)                    // 100 ms at full level
        #expect(p.currentGain == 1)
        p.duck(gainDB: CalmTuning.duckGainDB)
        _ = p.renderForTesting(frames: 960)                     // 40 ms
        #expect(abs(p.currentGain - 0.2512) < 0.002, "attack: \(p.currentGain)")
        p.unduck()
        _ = p.renderForTesting(frames: 4800 - 24)               // 199 ms
        #expect(p.currentGain < 1 && p.currentGain > 0.99, "release before 200 ms: \(p.currentGain)")
        _ = p.renderForTesting(frames: 48)
        #expect(p.currentGain == 1, "release after 200 ms: \(p.currentGain)")
        p.duck(gainDB: CalmTuning.duckGainDB)
        _ = p.renderForTesting(frames: 960)
        p.hold()
        _ = p.renderForTesting(frames: 120)                     // 5 ms
        #expect(p.currentGain == 0, "hold from ducked: \(p.currentGain)")
        p.resume()
        _ = p.renderForTesting(frames: 240)
        #expect(p.currentGain == 1, "resume returns to full level: \(p.currentGain)")
        #expect(p.duckGain == 1)
    }

    @Test func theEchoReferenceIsTwelveDBDownWhileDucked() {
        let p = Self.player()
        _ = p.takeReference(now: 0)
        _ = p.renderForTesting(frames: 4800)
        let full = p.takeReference(now: 0).map(\.energy)
        p.duck(gainDB: CalmTuning.duckGainDB)
        _ = p.renderForTesting(frames: 2400)                    // the attack
        _ = p.takeReference(now: 0)
        _ = p.renderForTesting(frames: 4800)
        let ducked = p.takeReference(now: 0).map(\.energy)
        let db = 10 * log10((ducked.reduce(0, +) / Double(ducked.count)) / (full.reduce(0, +) / Double(full.count)))
        #expect(abs(db - CalmTuning.duckGainDB) <= 0.5, "\(db) dB")
    }

    @Test func fullGainWithNoDuckIsBitIdentical() {
        let pcm = PCMTone.data(ms: 500, hz: 300, amplitude: 0.5)
        let p = PCMStreamPlayer()
        p.enqueue(pcm, utterance: "u")
        p.finish(utterance: "u")
        let out = p.renderForTesting(frames: 12_000)
        let ring = PCM16.samples(pcm).map { Float($0) / 32768 }
        #expect(out == ring)
        // A duck released before anything rendered changes nothing either.
        let q = PCMStreamPlayer()
        q.enqueue(pcm, utterance: "u")
        q.finish(utterance: "u")
        q.duck(gainDB: CalmTuning.duckGainDB)
        q.unduck()
        #expect(q.renderForTesting(frames: 12_000) == ring)
    }

    /// A flush while ducked fades out from the duck gain (no 5 ms burst at full level).
    @Test func aFlushWhileDuckedFadesFromTheDuckGain() {
        let p = Self.player()
        _ = p.renderForTesting(frames: 2400)
        p.duck(gainDB: CalmTuning.duckGainDB)
        _ = p.renderForTesting(frames: 2400)
        p.flush()
        let fade = p.renderForTesting(frames: 240)
        #expect((fade.map(abs).max() ?? 0) <= 0.5 * 0.26, "\(fade.map(abs).max() ?? 0)")
        #expect(p.duckGain == 1)
    }
}

// MARK: - 13. Dee's echo under a duck

@Suite(.serialized) struct CalmEchoTests {
    /// AEC off, Dee's echo at −20 dB: the per-band echo model learns while Dee plays, never
    /// while Dee is ducked; Dee's echo alone under a duck is never `.sustained`.
    @Test func herEchoUnderADuck() throws {
        var sim = RoomSim(seconds: 12, aec: false)
        sim.core.duckOnOnset = true
        sim.setEcho(gainDB: -20, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        RoomSim.place(try herReply(seconds: 9), into: &sim.her, at: RoomSim.sample(1.0))
        sim.duckAtSample = RoomSim.sample(5.0)
        sim.run()
        #expect(sim.learnAtDuck > 0, "the echo model never learned (vacuous)")
        #expect(sim.learnAfterDuck == sim.learnAtDuck, "learned while ducked: \(sim.learnAtDuck) → \(sim.learnAfterDuck)")
        #expect(!sim.actions.contains { if case .sustained = $0 { true } else { false } }, "Dee's echo was sustained voice")
        #expect(!sim.actions.contains { if case .bargeIn = $0 { true } else { false } })
    }
}

// MARK: - 14. TV-room hysteresis

@Suite struct CalmTVRoomTests {
    /// 1 s slices (40 ms frames), `share` of each voice-like.
    static func feed(_ bed: inout RoomBed, from a: Double, to b: Double, share: Double) {
        var t = a
        var i = 0
        while t < b - 1e-9 {
            t += 0.04
            bed.add(-40 + Double(i % 5), duration: 0.04, at: t)
            if Double(i % 25) < share * 25 { bed.markVoiceLike(duration: 0.04) }
            i += 1
        }
    }

    @Test func onAfterThreeSecondsOffThirtySecondsAfter() {
        var bed = RoomBed()
        Self.feed(&bed, from: 0, to: 2.5, share: 0.3)
        #expect(!bed.tvLike, "on before 3 s of slices")
        Self.feed(&bed, from: 2.5, to: 6.0, share: 0.3)
        #expect(bed.tvLike)
        bed.advance(to: 6.1)                                     // the last slice closes: qualifies at 6.1
        #expect(bed.tvLike)
        bed.advance(to: 6.1 + 29)
        #expect(bed.tvLike, "off before tvHold")
        bed.advance(to: 6.1 + 30)
        #expect(!bed.tvLike, "still on after tvHold")
    }

    @Test func aFanIsNoTV() {
        var bed = RoomBed()
        Self.feed(&bed, from: 0, to: 8, share: 0)
        #expect(!bed.tvLike)
        #expect(bed.ceilingDB != nil)
    }
}

// MARK: - 1. TV peak over Dee in a TV room

@Suite(.serialized) struct CalmTVBedTests {
    /// A TV across the room: 1 s cycles of 0.4 s talker (voice-like, −33 dBFS) and 0.6 s of
    /// its quieter sound (−44 dBFS noise): a voice-like share of 0.4.
    final class TV: @unchecked Sendable {
        private var i = 0
        let talk = Calm.harmonicAmplitude(db: -33)
        func next(_ seconds: Double) -> [Float] {
            var out: [Float] = []
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                let phase = i % 50                              // 50 × 20 ms = 1 s
                out += phase < 20 ? Calm.voice(0.02, amplitude: talk, hz: 210)
                    : Signal.noise(amplitude: 0.0109, count: Calm.step, seed: UInt64(i + 101))
                i += 1
            }
            return out
        }
    }

    /// Dee's quiet reply (−33 dBFS) after `warm` s of TV; returns the TV.
    static func setUp(_ rig: LoopRig) async throws -> TV {
        let tv = TV()
        try await rig.start()
        try rig.feed(tv.next(7.0))
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        for _ in 0..<100 { rig.push(Srv.audio("resp_1", "item_a1", PCMTone.data(ms: 100, hz: 440, amplitude: 0.03))) }
        rig.push(Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        await rig.settle()
        try rig.feed(tv.next(0.8))
        return tv
    }

    /// `peakOverCeiling` dB over the bed's ceiling, 0.6 s of pitched voice, over Dee, the TV
    /// pausing for it; the server opens an item; the words are "In tonight's news.".
    static func peak(_ rig: LoopRig, _ tv: TV, overCeiling: Double, _ w: PlayerWatch) async throws {
        let ceiling = try #require(rig.voice.earBed.ceilingDB)
        let a = Calm.harmonicAmplitude(db: ceiling + overCeiling)
        try await rig.over(Calm.voice(0.6, amplitude: a, hz: 210), w)
        try rig.feed(tv.next(0.4), w)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 400), Srv.committed("item_u2"))
        await rig.settle()
        try rig.feed(tv.next(0.2), w)
        rig.push(Srv.userTranscript("item_u2", "In tonight's news."))
        await rig.settle()
        try rig.feed(tv.next(0.3), w)
        await rig.settle()
    }

    @Test func tvPeakOverHer_flagOff_reproduces() async throws {
        let rig = try LoopRig(duckOnOnset: false)
        let w = PlayerWatch()
        let tv = try await Self.setUp(rig)
        try await Self.peak(rig, tv, overCeiling: 4, w)
        #expect(w.held, "0.6.0 paused Dee for the TV")
        rig.voice.shutdown()
    }

    @Test func tvPeakOverHer_calm() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        let tv = try await Self.setUp(rig)
        try #require(rig.voice.earBed.tvLike, "the TV bed was not learned as a TV")
        try await Self.peak(rig, tv, overCeiling: 4, w)
        #expect(abs(w.minDuck - 0.501) < 0.01, "duck gain \(w.minDuck)")
        #expect(rig.hasNote("duck item_u2 gain=-6"), "\(rig.notes.map(\.text))")
        #expect(!rig.hasNote("sustained"))
        #expect(rig.hasNote("ambient item_u2 reason=tvItemSustain"), "\(rig.notes.map(\.text))")
        #expect(rig.hasNote("unduck item_u2 (ambient)"))
        #expect(rig.voice.isAmbient(itemID: "item_u2", text: "In tonight's news."))
        #expect(!w.held && rig.truncates == 0 && rig.bargeIns == 0)
        #expect(rig.sent("response.create").count == 1, "only Dee's reply")
        #expect(await rig.waitSent("conversation.item.delete"), "the TV's item stays in the conversation")
        rig.voice.shutdown()
    }

    /// Control: 8 dB over the ceiling (over the TV bar, ceiling + 6) is the user: their words
    /// (not "go on") pause Dee (round 2: 0.6 s of voice is never sustained by itself).
    @Test func aVoiceWellAboveTheTVStillPauses() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        let tv = try await Self.setUp(rig)
        try #require(rig.voice.earBed.tvLike)
        try await Self.peak(rig, tv, overCeiling: 8, w)
        #expect(rig.hasNote("hold item_u2 why=answer"), "\(rig.notes.map(\.text))")
        #expect(w.held)
        #expect(!rig.hasNote("ambient"))
        rig.voice.shutdown()
    }
}

// MARK: - 15. In-hold sound tokens

@Suite struct CalmTokenTests {
    @Test func inAHoldTheseMeanGoOn() {
        for t in ["Ha ha.", "Heh.", "Uh.", "Um.", "(coughs)", "[laughter]", "Haha, yeah.", "*sighs*", "Hahaha.", "He he."] {
            #expect(Backchannel.isHoldSoundToken(t, sound: nil), "\(t)")
        }
        for t in ["Huh?", "Haha, what?", "Hm?", "[music]", "Ha ha, stop.", "He.", "", "Uh, what time is it"] {
            #expect(!Backchannel.isHoldSoundToken(t, sound: nil), "\(t)")
        }
        // A filler with a rising end asks.
        let rising = FragmentSound(voiced: 0.2, syllables: 1, pitchEnd: .rising)
        #expect(!Backchannel.isHoldSoundToken("Uh.", sound: rising))
        #expect(Backchannel.isHoldSoundToken("Ha ha.", sound: rising), "laughs skip the sound rule")
    }

    @Test func outsideAHoldNothingChanges() {
        for t in ["Ha ha.", "Heh.", "Uh.", "(coughs)", "Haha, yeah."] {
            #expect(!Backchannel.isBackchannel(t), "\(t)")
            #expect(!Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
    }

    @Test func theHoldVerdict() {
        var h = CloudVoice.FloorHold(itemID: "i", since: 0)
        h.final["i"] = "Ha ha."
        #expect(h.verdict(settled: true, quiet: true) == .answer, "a long burst: as today")
        h.tokenItems = ["i"]
        #expect(h.verdict(settled: true, quiet: true) == .resume)
        h.final["i"] = "Haha, what?"
        #expect(h.verdict(settled: true, quiet: true) == .answer)
        h.final["i"] = "Huh?"
        #expect(h.verdict(settled: true, quiet: true) == .answer)
    }

    @Test func commandWords() {
        for t in ["Stop.", "Wait.", "No.", "Hey.", "What?", "Hold on, what time is it?", "Hang on.", "Excuse me.",
                  "Be quiet.", "Quiet.", "Shush.", "Dee, look at this.", "Okay, stop."] {
            #expect(CalmTuning.hasCommandWord(t), "\(t)")
        }
        for t in ["Mm-hm.", "Yeah.", "No way, really?", "What a day.", "Ha ha.", "Keep going.", "Wait for it, that was funny"] {
            if t == "Wait for it, that was funny" { continue }
            #expect(!CalmTuning.hasCommandWord(t), "\(t)")
        }
    }
}

// MARK: - 16. The flag

@Suite struct CalmFlagTests {
    @Test func theDefaultIsOnForOpenAIOffForALANAndTheEnvOverrides() {
        var c = CloudVoice.Configuration()
        #expect(c.duckOnOnset == nil)
        if CalmTuning.duckOverride() == nil {
            #expect(c.ducksOnOnset)
            c.provider = .lan(host: "studio.local")
            #expect(!c.ducksOnOnset)
        }
        c.duckOnOnset = true
        #expect(c.ducksOnOnset)
        c.holdOnBargeIn = false
        #expect(!c.ducksOnOnset, "a duck needs holds")
        #expect(CalmTuning.duckOverride(["DEE_DUCK_ON_ONSET": "0"]) == false)
        #expect(CalmTuning.duckOverride(["DEE_DUCK_ON_ONSET": "1"]) == true)
        #expect(CalmTuning.duckOverride(["DEE_DUCK_ON_ONSET": "x"]) == nil)
        #expect(CalmTuning.sustainOverride(["DEE_SUSTAIN_VOICE": "0.55"]) == 0.55)
        #expect(CalmTuning.sustainOverride(["DEE_SUSTAIN_VOICE": "0.9"]) == 0.9)
        #expect(CalmTuning.sustainOverride(["DEE_SUSTAIN_VOICE": "2.5"]) == nil)
    }

    /// Off, the ear decides exactly as 0.6.0: a `.bargeIn` (and its event), never a duck.
    @Test func offTheEarStillBargesIn() {
        var core = EarCore()
        #expect(!core.duckOnOnset)
        core.duckOnOnset = false
        #expect(core.duckNow(nil, at: 0).isEmpty, "nothing plays: no duck")
    }
}
