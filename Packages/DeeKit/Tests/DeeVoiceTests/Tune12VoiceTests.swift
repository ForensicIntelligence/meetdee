import Foundation
import Testing
@testable import DeeVoice

/// Tune 12 (T11-1, live backchannel-fan15 c05, trace Traces/20261010-180956/t2-backchannel-fan15.jsonl
/// 49.6–51.0): "Keep going, I'm listening." split by the server into "Keep going." | "I'm with some."
/// (the second item's audio_start 49620 ms, the first's audio_end 49632 ms). Decision: a short item
/// right after a recognised continuer in the same hold is the rest of that backchannel; everything
/// else stays "unsure → stop and answer". One rule for the voice's hold and the brain.
struct Tune12VoiceTests {
    static let short = FragmentSound(voiced: 0.7, syllables: 3, pitchEnd: .flat)

    @Test func theTailRuleByWordsAndSound() {
        // Live: three syllables, so `questionLike` — the syllable count is not what decides here.
        #expect(Self.short.questionLike)
        #expect(Backchannel.isContinuerTail("I'm with some.", sound: Self.short))
        #expect(Backchannel.isContinuerTail("I'm listening.", sound: Self.short))
        // A question, a stop / call / question word, a number: never.
        for t in ["Wait, who made you?", "Who made you", "Wait.", "No.", "Stop it.", "Hey Dee.", "What's that",
                  "Tell me more", "Call at 5.", "Is it?"] {
            #expect(!Backchannel.isContinuerTail(t, sound: Self.short), "\(t)")
        }
        // Long words, a long voice, a rising end, no sound at all: a turn.
        #expect(!Backchannel.isContinuerTail("I had the strangest dream.", sound: Self.short))
        #expect(!Backchannel.isContinuerTail("I'm with some.", sound: FragmentSound(voiced: 1.6, syllables: 3, pitchEnd: .flat)))
        #expect(!Backchannel.isContinuerTail("I'm with some.", sound: FragmentSound(voiced: 0.7, syllables: 3, pitchEnd: .rising)))
        #expect(!Backchannel.isContinuerTail("I'm with some.", sound: nil))
        #expect(!Backchannel.isContinuerTail("  ", sound: Self.short))
    }

    /// The live hold: "Keep going." (ended at 10.00) | "I'm with some." (began at 9.99).
    static func liveHold(first: String = "Keep going.", start: Double = 9.988, second: String = "I'm with some.",
                         sound: FragmentSound = short) -> CloudVoice.FloorHold {
        var h = CloudVoice.FloorHold(itemID: "item_k", since: 8.5)
        h.final["item_k"] = first
        h.ends["item_k"] = 10.0
        h.add("item_s")
        h.starts["item_s"] = start
        h.sounds["item_s"] = sound
        h.final["item_s"] = second
        return h
    }

    @Test func theHoldGoesOnForTheSplitOffRestOfKeepGoing() {
        let h = Self.liveHold()
        #expect(h.followsContinuer("item_s"))
        #expect(!h.followsContinuer("item_k"), "the first item follows nothing")
        #expect(h.verdict(settled: true, quiet: true) == .resume)
        // 0.8 s after the end of "Keep going." is still its rest; later is a turn of its own.
        #expect(Self.liveHold(start: 10.8).verdict(settled: true, quiet: true) == .resume)
        #expect(Self.liveHold(start: 10.9).verdict(settled: true, quiet: true) == .answer)
        // Not after a recognised continuer ("Grand." is only a misheard one): a turn.
        #expect(Self.liveHold(first: "I'm hungry.").verdict(settled: true, quiet: true) == .answer)
        #expect(Self.liveHold(first: "Grand.").verdict(settled: true, quiet: true) == .answer)
        // A real question or a long statement after "Keep going." is still answered.
        #expect(Self.liveHold(second: "Wait, who made you?").verdict(settled: true, quiet: true) == .answer)
        #expect(Self.liveHold(sound: FragmentSound(voiced: 1.9, syllables: 6, pitchEnd: .falling))
            .verdict(settled: true, quiet: true) == .answer)
    }

    @Test func noTimesNoTail() {
        var h = Self.liveHold()
        h.starts["item_s"] = nil
        #expect(!h.followsContinuer("item_s"))
        #expect(h.verdict(settled: true, quiet: true) == .answer)
    }
}
