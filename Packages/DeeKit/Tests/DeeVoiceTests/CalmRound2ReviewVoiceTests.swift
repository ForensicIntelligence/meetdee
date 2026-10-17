import Foundation
import Testing
@testable import DeeVoice

/// Calm round 2, the review's findings (scratchpad calm/r2-review-regress.md and
/// r2-review-correct.md). Each test reproduces the finding first, then pins the fix.

/// A harness bed (fan, kitchen, tv…) in a `LoopRig` at `snr`, with Dee's quiet reply.
final class Round2BedLoop: @unchecked Sendable {
    let rig: LoopRig
    private let bed: [Float]
    private var pos = 0
    private let gain: Float

    init(duckOnOnset: Bool, bed name: String, snr: Double = 15) throws {
        rig = try LoopRig(duckOnOnset: duckOnOnset)
        bed = EchoTenRoom.upsample(try HarnessFixture.wav("noise/\(name).wav"))
        gain = Float(pow(10, (-24 - snr - Level.rmsDB(bed)) / 20))
    }

    func next(_ seconds: Double) -> [Float] {
        let n = Int(seconds * LoopRig.rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = bed[pos] * gain; pos = (pos + 1) % bed.count }
        return out
    }

    func feed(_ seconds: Double, _ w: PlayerWatch) throws { try rig.feed(next(seconds), w) }

    func mixed(_ x: [Float]) -> [Float] {
        let b = next(Double(x.count) / LoopRig.rate)
        return zip(x, b).map { $0 + $1 }
    }

    func setUp(_ w: PlayerWatch) async throws {
        try await rig.start()
        try feed(8.0, w)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        for _ in 0..<100 { rig.push(Srv.audio("resp_1", "item_a1", PCMTone.data(ms: 100, hz: 440, amplitude: 0.03))) }
        rig.push(Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        await rig.settle()
        try feed(0.8, w)
    }
}

// MARK: - regress F1: a fan or a kitchen is no TV room

@Suite(.serialized) struct Round2ReviewTVRoomTests {
    /// The beds' ceiling sits over `CalmTuning.loudBedDB` at 10–20 dB SNR, so round 2 made every
    /// one a "TV room". Only the beds with talk's spread (floor to ceiling) are TV rooms now.
    @Test(arguments: [("fan", 10.0), ("fan", 15.0), ("fan", 20.0), ("kitchen", 10.0), ("kitchen", 15.0), ("kitchen", 20.0)])
    func aSteadyBedIsNoTVRoom(bed: String, snr: Double) throws {
        var s = RoomSim(seconds: 14)
        s.core.duckOnOnset = true
        s.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: snr)
        s.run()
        let c = try #require(s.core.bed.ceilingDB), f = try #require(s.core.bed.floorDB)
        // The fan is loud enough that round 2 called it a TV room (the kitchen's hum is, in
        // the scenario's first seconds: `aQuestionInAFanOrKitchenRoomIsTheirs`).
        if bed == "fan", snr <= 15 { #expect(c >= CalmTuning.loudBedDB, "\(bed)\(snr): \(c)") }
        #expect(c - f < CalmTuning.tvSpreadDB, "\(bed)\(snr): spread \(c - f)")
        #expect(!s.core.tvRoom, "\(bed)\(snr)")
    }

    @Test(arguments: [("tv", 10.0), ("tv", 15.0), ("tv", 20.0), ("tvlong", 10.0), ("tvlong", 15.0)])
    func aTalkingBedIsStillATVRoom(bed: String, snr: Double) throws {
        var s = RoomSim(seconds: 20)
        s.core.duckOnOnset = true
        s.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: snr)
        s.run()
        #expect(s.core.tvRoom, "\(bed)\(snr): ceiling \(String(describing: s.core.bed.ceilingDB)) floor \(String(describing: s.core.bed.floorDB))")
    }

    /// The review's case (`RevRegressLoop`): "What time is it?" over Dee with the fan at
    /// 15 dB SNR, the user 2 dB under the fixture: `duck … gain=-6`, `unduck (wordsWait)`,
    /// `ambient … reason=tvItemSustain`, never held, never answered. Also softer, in the
    /// kitchen, and "Stop." / "Who made you?" at −6 dB.
    @Test(arguments: [("fan", "q03", "What time is it?", Float(1)), ("fan", "q03", "What time is it?", Float(0.8)),
                      ("fan", "q03", "What time is it?", Float(0.7)), ("fan", "q08", "Who made you?", Float(0.5)),
                      ("fan", "c01", "Stop.", Float(0.5)), ("kitchen", "q03", "What time is it?", Float(0.7)),
                      ("kitchen", "q08", "Who made you?", Float(0.5))])
    func aQuestionInAFanOrKitchenRoomIsTheirs(bed: String, id: String, text: String, gain: Float) async throws {
        let room = try Round2BedLoop(duckOnOnset: true, bed: bed)
        let w = PlayerWatch()
        try await room.setUp(w)
        try await room.rig.over(room.mixed(try Round2.audio(id, gain: gain)), item: "item_u2", w)
        try room.feed(0.3, w)
        room.rig.push(Srv.speechStopped("item_u2", ms: room.rig.uplinkMsNow - 300), Srv.committed("item_u2"))
        await room.rig.settle()
        room.rig.push(Srv.userTranscript("item_u2", text))
        await room.rig.settle()
        try room.feed(0.3, w)
        await room.rig.settle()
        let notes = room.rig.notes.map(\.text)
        #expect(w.held, "\(bed) \(id) g=\(gain): never paused for it: \(notes)")
        #expect(!room.rig.hasNote("ambient"), "\(bed) \(id) g=\(gain): dropped as the TV: \(notes)")
        #expect(!room.rig.voice.isAmbient(itemID: "item_u2", text: text))
        room.rig.voice.shutdown()
    }
}

// MARK: - regress F2 / correct F1: a comma ends no lone stop word; a partial word is no name

@Suite(.serialized) struct Round2ReviewDeltaTests {
    @Test func aCommaEndsNoLoneStopWord() {
        for t in ["No,", "No, keep", "No, no,", "Hey,", "Hey, that's", "What,", "No;"] {
            #expect(!CalmTuning.hasCommandWord(t, partial: true), "\(t)")
        }
        // Their full words were never one either.
        for t in ["No, keep going.", "No, no, go on.", "Hey, that's cool.", "What, really?"] {
            #expect(!CalmTuning.hasCommandWord(t), "\(t)")
        }
        // Still at once: a closing mark ends the lone word; "Stop" / "Wait" need none.
        for t in ["No.", "What?", "Hey!", "Stop", "Wait", "Wait,", "Stop talking", "Hold on,", "Dee,", "Dee ", "hold on "] {
            #expect(CalmTuning.hasCommandWord(t, partial: true), "\(t)")
        }
        // A phrase counts once its last word is whole ("Hold on" may be "Hold onto").
        #expect(!CalmTuning.hasCommandWord("Hold on", partial: true))
    }

    /// A partial's last word may still grow: "Dee" → "Deep", "Mira" → "Mirage", the persona
    /// Haven's "haven" → "haven't".
    @Test func aWordAPartialMayStillLengthenIsNoName() {
        #expect(!CalmTuning.hasCommandWord("Dee", partial: true))
        #expect(!CalmTuning.hasCommandWord("Mira", names: ["mira"], partial: true))
        #expect(!CalmTuning.hasCommandWord("I haven", names: ["haven"], partial: true))
        #expect(!CalmTuning.hasCommandWord("I haven't", names: ["haven"], partial: true))
        #expect(!CalmTuning.hasCommandWord("Deep down I", partial: true))
        #expect(CalmTuning.hasCommandWord("Mira,", names: ["mira"], partial: true))
        #expect(CalmTuning.hasCommandWord("Okay Dee ", partial: true))
        #expect(CalmTuning.hasCommandWord("Haven, what", names: ["haven"], partial: true))
        #expect(CalmTuning.hasCommandWord("Mira", names: ["mira"]), "full words: a name")
    }

    /// The review's `RevRegressDelta`: deltas 0.1 s apart under a duck → `hold why=stopword` at
    /// the "," delta, `resumed (words)` 0.3 s later (0.5 s for "No, no, go on.").
    @Test(arguments: [["No", ",", " keep", " going", "."], ["No", ",", " no", ",", " go", " on", "."],
                      ["Hey", ",", " that's", " cool", "."]])
    func noKeepGoingNeverPausesDee(deltas: [String]) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.5), w)
        #expect(rig.voice.floorHold?.phase == .ducked && !w.held)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        for d in deltas { rig.deltas("item_u2", [d]); await rig.settle(); try rig.idle(0.1, w); await rig.settle() }
        rig.push(Srv.userTranscript("item_u2", deltas.joined()))
        await rig.settle()
        _ = try await rig.idleUntil(1.5) { false }
        let notes = rig.notes.map(\.text)
        #expect(!rig.hasNote("hold item_u2 why=stopword"), "\(notes)")
        #expect(!w.held, "\(deltas.joined()): \(notes)")
        rig.voice.shutdown()
    }

    /// Control: a lone "No." still pauses at its closing delta; the persona's name split over
    /// two deltas ("Mira" + "ge") never does.
    @Test(arguments: [(["No", "."], true), (["Mira", "ge", " is", " a", " word", "."], false)])
    func aLoneNoStillStopsAndASplitWordDoesNot(deltas: [String], stops: Bool) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        rig.voice.setAddressNames(["Mira"])
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.5), w)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        var at: Double?
        for d in deltas {
            rig.deltas("item_u2", [d])
            await rig.settle()
            if at == nil, rig.hasNote("hold item_u2 why=stopword") { at = 0 }
            try rig.idle(0.1, w)
            await rig.settle()
        }
        #expect(rig.hasNote("hold item_u2 why=stopword") == stops, "\(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }
}

// MARK: - correct F2: Dee's own words in a ducked item stop nothing (no echo cancellation)

@Suite(.serialized) struct Round2ReviewEchoWordsTests {
    /// The review's probe: Dee says "Wait till you hear how it ends, it gets better."; the
    /// user's voice ducks Dee and the server's item holds Dee's echo, then their "Mm-hm."
    /// Round 2 paused Dee (`hold … why=stopword`) on Dee's own "Wait".
    @Test(arguments: [false, true])
    func herOwnWaitInADuckedItemNeverPausesHer(aec: Bool) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        _ = rig.graph.setManualFacts(aecActive: aec, outputLatency: 0)
        let w = PlayerWatch()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 10_000)], text: "Wait till you hear how it ends, it gets better.")
        try rig.quiet(0.6)
        try await rig.over(Calm.voice(0.5), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.deltas("item_u2", ["Wait", " till", " you", " hear", ".", " Mm", "-hm", "."])
        await rig.settle()
        if aec {
            // With echo cancellation the item is the user's sound: their words decide (as before).
            #expect(rig.hasNote("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
        } else {
            #expect(!rig.hasNote("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
            #expect(!rig.graph.player.isHeld)
        }
        rig.voice.shutdown()
    }

    /// Control (no echo cancellation): a stop word Dee never said still pauses at its delta.
    @Test(arguments: [["Stop", "."], ["Hold", " on", ","], ["Mm", ".", " Wait", ","]])
    func theirOwnStopStillPausesHer(deltas: [String]) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        let w = PlayerWatch()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 10_000)], text: "Here comes the best part, it gets better.")
        try rig.quiet(0.6)
        try await rig.over(Calm.voice(0.5), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.deltas("item_u2", deltas)
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 why=stopword"), "\(deltas): \(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }
}

// MARK: - correct F3: a question led by a stop word in an echo-rejected item is answered

@Suite(.serialized) struct Round2ReviewRescueTests {
    @Test func onlyAStopIsOnlyACommand() {
        for t in ["Stop talking for a second.", "Wait.", "Hold on, Dee.", "Stop. Stop.", "Wait a minute.", "Hang on a sec."] {
            #expect(CalmTuning.isOnlyCommand(t), "\(t)")
        }
        for t in ["Wait, what did you say about the moon?", "Stop, I want pasta.", "Hold on, who made you?", "Nice one."] {
            #expect(!CalmTuning.isOnlyCommand(t), "\(t)")
        }
        #expect(CalmTuning.isOnlyCommand("Mira, stop.", names: ["mira"]))
    }

    /// The c03 replay of `Round2EchoStopTests` (heavy echo, no echo cancellation): the item
    /// is rejected as Dee's echo before its words; its first delta "Wait" pauses Dee
    /// (`hold - why=stopword`, no item). Round 2: its words never reached anyone — the reply was
    /// cut at `holdNoItem` and the question lost. Now the full words go to the brain
    /// (`HoldEvent.rescued`) and the hold waits for its answer; a bare stop is unchanged.
    @Test(arguments: [true, false])
    func aQuestionLedByAStopUnderHeavyEchoIsRescued(question: Bool) async throws {
        let room = try EchoTenRoom(duckOnOnset: true)
        let holds = Collector(room.rig.voice.holdEvents)
        let replyStart = try await room.startReply(her: "l03", seconds: 8)
        let r = LoopRig.rate
        let u = try room.say("c03", atSample: replyStart + Int(1.4 * r))
        func at(_ s: Double) -> Int { u.onset + Int(s * r) }
        try room.run(untilSample: at(-0.44))
        room.rig.push(Srv.speechStarted("item_e1", ms: room.ms(atSample: at(-0.86))))
        await room.rig.settle()
        try room.run(untilSample: at(0.08))
        room.rig.push(Srv.speechStopped("item_e1", ms: room.ms(atSample: at(-0.11))), Srv.committed("item_e1"))
        room.rig.push(Srv.speechStarted("item_e2", ms: room.ms(atSample: at(-0.25))))
        await room.rig.settle()
        try room.run(untilSample: at(0.26))
        room.rig.deltas("item_e1", ["Bye", "."])
        try room.run(untilSample: at(0.51))
        room.rig.push(Srv.userTranscript("item_e1", "Bye."))
        await room.rig.settle()
        try room.run(untilSample: at(0.82))
        room.rig.push(Srv.speechStopped("item_e2", ms: room.ms(atSample: at(0.72))), Srv.committed("item_e2"))
        await room.rig.settle()
        try room.run(untilSample: at(0.90))
        room.rig.push(Srv.speechStarted("item_u3", ms: room.ms(atSample: at(0.49))))
        await room.rig.settle()
        try room.run(untilSample: at(0.96))
        room.rig.deltas("item_e2", ["Went", "."])
        await room.rig.settle()
        try room.run(untilSample: at(1.17))
        room.rig.push(Srv.userTranscript("item_e2", "Went."))
        await room.rig.settle()
        try room.run(untilSample: at(2.77))
        room.rig.push(Srv.speechStopped("item_u3", ms: room.ms(atSample: at(2.68))), Srv.committed("item_u3"))
        await room.rig.settle()
        try room.run(untilSample: at(2.91))
        let words = question ? ["Wait", ",", " what", " did", " you", " say", " about", " the", " moon", "?"]
            : ["Stop", " talking", " for", " a", " second", "."]
        room.rig.deltas("item_u3", words)
        await room.rig.settle()
        try room.run(0.3)
        room.rig.push(Srv.userTranscript("item_u3", words.joined()))
        await room.rig.settle()
        try room.run(0.1)
        await room.rig.settle()
        let rescued = holds.all.compactMap { e -> String? in if case .rescued(_, let text) = e { text } else { nil } }
        #expect(room.deleted.contains("item_u3"), "the replay rejects it as Dee's echo: \(room.notes)")
        if room.deleted.contains("item_u3") {
            #expect(room.rig.hasNote("hold - why=stopword"), "\(room.notes)")
            #expect(rescued == (question ? [words.joined()] : []), "\(rescued) \(room.notes)")
            try room.run(2.0)
            await room.rig.settle()
            if question {
                // The brain's answer ends the hold; nobody answers here, so `holdAfterWords` does.
                #expect(room.rig.voice.floorHold == nil)
            }
        } else {
            // Not rejected: the words path answers it as any item's words.
            #expect(rescued.isEmpty)
        }
        room.rig.voice.shutdown()
    }
}

// MARK: - regress F3: Dee's own cap over a labelled sound, then failed words

@Suite(.serialized) struct Round2ReviewOwnEndTests {
    /// A cough label over the burst, Dee's own cap, then the words: failed → not claimed (the
    /// brain answers the audio, as in 0.6.0); empty → claimed; none yet → claimed (wait).
    @Test(arguments: ["failed", "empty", "pending"])
    func aLabelledBurstWithFailedWordsIsNotClaimed(words: String) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(try Round2.audio("ns09"), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        let now = rig.graph.now
        rig.voice.classifiedForTesting([("cough", 0.8)], window: (now - 1.2)...(now - 0.9))
        rig.voice.stopSpeaking(ownEnd: true)
        await rig.settle()
        #expect(rig.hasNote("unduck item_u2 (stopped)"), "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        switch words {
        case "failed": rig.push(.inputTranscriptionFailed(.init(itemID: "item_u2", error: nil)))
        case "empty": rig.push(Srv.userTranscript("item_u2", ""))
        default: break
        }
        await rig.settle()
        try rig.idle(0.1)
        await rig.settle()
        #expect(rig.voice.holdClaims(itemID: "item_u2") == (words != "failed"), "\(words)")
        rig.voice.shutdown()
    }
}
