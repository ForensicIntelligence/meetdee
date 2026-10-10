import Foundation
import Testing
@testable import DeeMind

/// Tune 2 (tune1-live.md §F-DNA): taking the floor is not rudeness, and a fresh voice
/// baseline does not hear ordinary speech as shouting.
struct Tune2FloorControlTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    /// The harness's neutral fixtures: −24 dBFS active level; "loud" −17; "soft" −32.
    static let normal = Prosody(loudnessDB: -24, peakDB: -14, speechRate: 2.8, pitchVariability: 4)
    static let fast = Prosody(loudnessDB: -24.8, peakDB: -14, speechRate: 3.6, pitchVariability: 4)
    static let loud = Prosody(loudnessDB: -17, peakDB: -6, speechRate: 3.0, pitchVariability: 4)
    static let dog = "So I've been thinking about getting a dog, but my apartment is pretty small. And I work long hours, so I'm not sure it would be fair to the dog. What do you think I should do?"

    /// long-clean, verbatim: the first question and c03. Live: "being shouted at" +
    /// "being brushed off", rude 2 times, regard +0.01 → −0.39.
    @Test func liveLongCleanStopTalkingKeepsRegard() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let before = await mind.snapshot(at: Self.t0).regard
        let (first, _) = await mind.hear(Self.dog, prosody: Self.normal, at: Self.t0.addingTimeInterval(16))
        #expect(first.loudness < 0.3, "−24 dBFS is ordinary speech on a fresh baseline: \(first.loudness)")
        #expect(first.hostility < 0.05, "a worried question is not an attack: \(first.hostility)")
        let (stop, snap) = await mind.hear("Wait, stop talking for a second.", prosody: Self.fast, at: Self.t0.addingTimeInterval(22))
        #expect(stop.floorControl)
        #expect(stop.dismissal < 0.1 && stop.hostility < 0.05, "dismissal \(stop.dismissal) hostility \(stop.hostility)")
        #expect(stop.kindness > -0.1)
        #expect(snap.regard > before - 0.05, "regard \(before) → \(snap.regard)")
        #expect(await mind.state.hostileInteractions == 0)
        // Two ordinary turns later (as live), "Stop." said loudly over her voice (c01):
        // getting a word in, not shouting at her.
        _ = await mind.hear("Okay, so today at work, my boss called a meeting at 4:30 on a Friday.", prosody: Self.normal,
                            at: Self.t0.addingTimeInterval(45))
        _ = await mind.hear("I'm trying to plan a little garden on my balcony.", prosody: Self.normal, at: Self.t0.addingTimeInterval(93))
        let (bare, after) = await mind.hear("Stop.", prosody: Self.loud, at: Self.t0.addingTimeInterval(97))
        #expect(bare.floorControl && bare.loudness <= 0.3 && bare.intensity <= 0.3 && bare.hostility == 0)
        #expect(after.regard > before - 0.05, "regard \(before) → \(after.regard)")
        #expect(await mind.state.hostileInteractions == 0)
    }

    @Test(arguments: ["Stop.", "Wait, stop talking for a second.", "hold on", "Be quiet for a sec.", "Dee, shh.",
                      "Hang on, let me finish.", "can you just stop talking please", "Hold on, hold on."])
    func floorControlIsNeutral(_ text: String) {
        var a = Appraiser()
        let x = a.appraise(text, prosody: Self.normal)
        #expect(x.floorControl, "\(text)")
        #expect(x.hostility == 0 && x.dismissal == 0 && x.threat == 0, "\(text): h \(x.hostility) d \(x.dismissal)")
        #expect(x.kindness >= 0, "\(text): \(x.kindness)")
    }

    @Test(arguments: ["Shut up.", "Stop talking, you're so annoying.", "Just stop, you stupid robot.", "Stop it, I hate you."])
    func hostileWordsStillCountWithFloorControl(_ text: String) {
        var a = Appraiser()
        let x = a.appraise(text)
        #expect(!x.floorControl, "\(text)")
        #expect(x.hostility >= 0.3, "\(text): \(x.hostility)")
    }

    @Test(arguments: ["I can't stop laughing!", "I can't wait for the weekend!", "Don't stop. Keep going.",
                      "We had to wait an hour for the bus.", "Wait till you hear this!", "The library was so quiet."])
    func notFloorControl(_ text: String) {
        var a = Appraiser()
        #expect(!a.appraise(text).floorControl, "\(text)")
    }

    /// "At most a tiny patience cost if repeated aggressively."
    @Test func repeatedForcefulStopCostsOnlyALittlePatience() {
        var a = Appraiser()
        for line in ["what time is it", "tell me a story", "what's the weather like"] { _ = a.appraise(line, prosody: Self.normal) }
        let shout = Prosody(loudnessDB: -12, peakDB: -2, speechRate: 3.6, pitchVariability: 5)
        let first = a.appraise("STOP!", prosody: shout)
        #expect(first.hostility == 0, "once is turn-taking")
        let second = a.appraise("STOP! STOP!", prosody: shout)
        #expect(second.hostility > 0 && second.hostility <= Appraiser.floorControlPatienceCost)
        #expect(second.kindness > -0.25, "never a hostile interaction")
        #expect(a.appraise("STOP!", prosody: Self.normal).hostility == 0, "said normally it is just turn-taking")
        #expect(second.hostility < 0.3, "never 'rudeness'")
    }

    @Test func repeatedStopBarelyMovesRegard() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        _ = await mind.hear("tell me about octopuses", prosody: Self.normal, at: Self.t0)
        let before = await mind.snapshot(at: Self.t0.addingTimeInterval(1)).regard
        let shout = Prosody(loudnessDB: -12, peakDB: -2, speechRate: 3.6, pitchVariability: 5)
        _ = await mind.hear("STOP!", prosody: shout, at: Self.t0.addingTimeInterval(5))
        let (_, snap) = await mind.hear("STOP! STOP!", prosody: shout, at: Self.t0.addingTimeInterval(7))
        #expect(snap.regard > before - 0.08, "regard \(before) → \(snap.regard)")
        #expect(snap.regard > -0.1, "never 'upset with them' over a stop")
        #expect(await mind.state.hostileInteractions == 0)
    }

    @Test func freshBaselineReadsOrdinaryAndLoudSpeech() {
        let fresh = Appraiser()
        #expect(abs(fresh.peek("hello there", prosody: Self.normal).loudness) < 0.3)
        #expect(fresh.peek("hello there", prosody: Self.loud).loudness > 0.5)
        #expect(fresh.peek("hello there", prosody: Prosody(loudnessDB: -36, peakDB: -28, speechRate: 2.4)).loudness < -0.3)
    }
}
