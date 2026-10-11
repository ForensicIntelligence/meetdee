import DeeCore
import DeeRealtime
import DeeSelf
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 13: the tune-12 live findings (scratchpad/tune12-live.md), replayed at the live shape
/// on the real voice and session (BrainRig).
@MainActor
@Suite(.serialized) struct Tune13BrainTests {
    typealias T12 = Tune12BrainTests
    typealias T2 = Tune2BrainTests
    typealias T7 = Tune7BrainTests

    /// T12-2, t2-backchannel-echo20 c05 (Traces/20261010-205810, 59.5–66.3): "Keep going." →
    /// `continued` (61.64), "I'm listening." → the tail of it, she went on. 2.58 s after the
    /// go-on her reply reached its sentence cap (`sentenceCapStop`, truncate at 64.21): her own
    /// stop, which the "cut anyway after keep going" rule took for a barge-in and answered with
    /// a carry-on at 64.52 ("Oh, okay, let's keep going…"). Her own stop asks for nothing.
    @Test func liveEcho20C05HerOwnSentenceCapStopIsNoCarryOn() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await T12.continuerThenMore(rig, second: "I'm listening.", talk: 0.5)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "nothing answered: \(rig.trail())")
        // She talks on to her sentence cap, inside 3 s of the go-on.
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 1, text: s))
            await rig.settle()
        }
        #expect(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 3565, cut: true))
        await rig.settle()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 1, "no carry-on after her own stop: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// interrupt-echo20 q08 "Who made you?" over her (A 50.92, solo 54.07; Traces/20261010-201149 and
    /// -214811): asked from its words ("Who", " made", " you", "?" just before the request) with the
    /// answer-first note, but the model only had the audio, her echo in it, and answered her own
    /// subject ("Ready for what, Alex? … that filing system"). A short question is named in the note.
    @Test func liveEcho20Q08AShortQuestionOverHerIsNamedInTheNote() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_q")
        T2.delta(rig, "item_q", "Who made you?")                             // live: 4 deltas in 14 ms
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        let dna = try #require(rig.dnaText(String(dnaID)))
        #expect(dna.contains("Keep in mind: They asked you something, in words like \u{201C}Who made you?\u{201D}: your very first sentence answers it plainly"), "\(dna)")
        rig.shutdown()
    }

    /// Only a few words are ever named (the DNA never holds five of theirs in a row).
    @Test func theAnswerFirstNoteNamesOnlyAShortQuestion() {
        #expect(TurnPolicy.answerFirstNote(asked: "Are you awake?").contains("\u{201C}Are you awake?\u{201D}"))
        #expect(TurnPolicy.answerFirstNote(asked: "What did you do today?") == TurnPolicy.answerFirstNote)
        #expect(TurnPolicy.answerFirstNote(asked: "") == TurnPolicy.answerFirstNote)
        #expect(TurnPolicy.answerFirstNote(asked: "Who made") == TurnPolicy.answerFirstNote, "a partial that broke off")
    }
}
