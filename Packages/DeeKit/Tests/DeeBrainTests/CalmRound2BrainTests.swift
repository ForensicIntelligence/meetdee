import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Calm round 2, brain half (scratchpad calm/live.md, verdict NOT-SHIP). The user found 0.6.0
/// "too sensitive to interruptions"; round 1's live run still answered a laugh after Dee's
/// own sentence cap, and its sustain rule paused Dee on continuers before a short question's
/// words. Round 2: Dee's own cap end over a sound is no barge-in and the sound is no turn;
/// a short question over a ducked Dee is still answered exactly once, from its words.
@MainActor
@Suite(.serialized) struct CalmRound2BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    /// Dee's reply ducked for `item` (`talk` s of voice), then Dee's own sentence cap.
    func cappedOver(_ rig: BrainRig, _ item: String, talk: Double) async throws {
        try await rig.start()
        try await T10.pausedBy(rig, item, talk: talk)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(String(describing: rig.voice.floorHold))")
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 1, text: s))
            await rig.settle()
        }
        try #require(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        await rig.settle()
    }

    /// Live calm-sounds-clean ns09 (202402, 156.14): "Ha ha!" ducked Dee; Dee's sentence cap
    /// at +1.16 s escalated the duck (`hold why=brain`, `bargeInSensed`); the laugh's transcript
    /// came back empty and the brain answered it (5.9 s). Round 2: no barge-in, not answered.
    @Test(arguments: ["", "Ha ha."])
    func aLaughAfterHerOwnCapIsNeverAnswered(text: String) async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await cappedOver(rig, "item_x", talk: 0.3)
        #expect(!rig.brain.trace.contains(.bargeInSensed), "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_x", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_x"))
        await rig.settle()
        if !text.isEmpty { T2.deltas(rig, "item_x", text) }
        rig.push(Srv.userTranscript("item_x", text))
        for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 1, "the laugh was answered: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// A real question said over Dee as the cap came is still answered, from its words or
    /// (failed words) from the audio as in 0.6.0.
    @Test(arguments: [true, false])
    func aQuestionAfterHerOwnCapIsAnswered(words: Bool) async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await cappedOver(rig, "item_q", talk: 0.6)
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        if words {
            T2.deltas(rig, "item_q", "Who made you?")
            rig.push(Srv.userTranscript("item_q", "Who made you?"))
        } else {
            rig.push(Srv.transcriptFailed("item_q"))
        }
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// Live t2-interrupt-fan15 q08 and calm-bc T1: round 1 paused Dee at 0.56 s on the sound of
    /// "Who made you?" (0.75 s). Round 2: Dee stays ducked through its sound; its words pause
    /// Dee and the brain answers exactly once, which ends Dee's reply once.
    @Test func whoMadeYouOverADuckedDeeGetsExactlyOneAnswer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_q", talk: 0.75)
        #expect(rig.voice.floorHold?.phase == .ducked, "no early pause: \(String(describing: rig.voice.floorHold))")
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        T2.deltas(rig, "item_q", "Who made you?")
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_q", "Who made you?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 2, "one answer: \(rig.trail())")
        #expect(rig.trail().filter { $0 == "truncate:item_a1" }.count == 1, "\(rig.trail())")
        rig.shutdown()
    }

    /// The persona's name reaches the voice: "Mira," over a ducked Dee pauses Dee.
    @Test func thePersonasNamePausesDee() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false; $0.persona = Persona(name: "Mira") }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_n", talk: 0.4)
        rig.push(Srv.speechStopped("item_n", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_n"))
        await rig.settle()
        T2.deltas(rig, "item_n", "Mira,")
        await rig.settle()
        #expect(rig.voice.floorHold?.phase == .paused && rig.voice.floorHold?.why == "stopword",
                "\(String(describing: rig.voice.floorHold))")
        rig.shutdown()
    }
}
