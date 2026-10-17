import Foundation
import Testing
@testable import DeeVoice

// Tune 9 (scratchpad/tune8-live.md T8-1; report Tools/voice-harness/Reports/20261010-080526,
// traces Tools/voice-harness/Traces/20261010-080526): interrupt-echo20 q08 "Who made you?"
// (AEC off, echo −20 dB) came back as **"Movie."**; `Backchannel.isMisheardFragment` took
// any single leftover word for a misheard "go on" (`guard kept.count > 1 else { return true }`),
// the brain resumed Dee (`backchannel("continued")` 51.50) and the question was never
// answered. Now one word is "go on" only when the words know it ("Grand.", "She.",
// "Done.", "Yeah.", a hum, or a misspelling of one) or when it *sounded* like a
// backchannel (`FragmentSound`: ≤ 0.45 s of voice, ≤ 2 syllables, not rising).

/// Over-Dee's words of tunes 6–8 live (every barge-in fixture's transcript in
/// Reports/*/report.json, `/tmp/dee-t9-voice/bi.py`).
enum LiveOverHer {
    /// Backchannels (bc01 "Go on.", bc02 "Mm-hm.", c02 "Don't stop, keep going.", c05
    /// "Keep going, I'm listening.") as they came back: Dee must go on.
    static let goOn = [
        "Grand.", "Jeron.", "Yeah.", "She.", "Done.", "Sheep.", "Cheap.", "Going.", "MMHM.", "MMHN.", "HM.", "MHM.",
        "Put going.", "Sheupr and going.", "I'm listen.", "Sometimes listening.", "Sheep going.", "Cheap going.",
        "Going on.", "Um, grand.",
    ]
    /// q08 "Who made you?" over Dee, every way it came back in tunes 6–8: never "go on".
    static let q08 = ["Movie.", "To making.", "Too much.", "What do?", "Who are you?", "It's too new.", "Too late.",
                      "Who made you?"]
    /// Content words heard live (not over Dee) that a misheard question could be: a turn
    /// without a backchannel's sound.
    static let contentWords = ["Movie.", "Music.", "Weather.", "Lettuce.", "Football.", "Tomatoes.", "Store.", "Team.",
                               "Billy.", "Tidy.", "Something."]
}

// MARK: - The rule, from the live strings

@Suite struct Tune9FragmentRuleTests {
    /// The live T8-1 string, words only (the brain's `TurnPolicy.isMisheardFragment`):
    /// "Movie." is a turn.
    @Test func movieIsNotAFragmentByItsWords() {
        #expect(!Backchannel.isMisheardFragment("Movie."))
        #expect(!Backchannel.isBackchannel("Movie.", inHold: true))
        #expect(!Backchannel.isBackchannel("Movie.", inHold: true, final: true, sound: nil))
    }

    @Test func liveBackchannelsStillGoOn() {
        for t in LiveOverHer.goOn {
            #expect(Backchannel.isMisheardFragment(t) || Backchannel.isBackchannel(t), "\(t)")
            #expect(Backchannel.isBackchannel(t, inHold: true), "\(t)")
            // Their sound never makes a known "go on" a turn (words know it).
            #expect(Backchannel.isBackchannel(t, inHold: true, sound: Self.question), "\(t)")
        }
    }

    @Test func q08MishearsAreNeverGoOn() {
        for t in LiveOverHer.q08 + LiveOverHer.contentWords {
            #expect(!Backchannel.isMisheardFragment(t), "\(t)")
            #expect(!Backchannel.isMisheardFragment(t, sound: Self.question), "\(t)")
            #expect(!Backchannel.isBackchannel(t, inHold: true, sound: Self.question), "\(t)")
        }
    }

    /// A word the words don't know decides by its sound: short, ≤ 2 syllables, flat or
    /// falling is "go on"; long, rising, 3 syllables or no sound at all is a turn.
    @Test func anUnknownWordDecidesByItsSound() {
        let short = FragmentSound(voiced: 0.2, syllables: 1, pitchEnd: .unknown)
        let mmhm = FragmentSound(voiced: 0.4, syllables: 2, pitchEnd: .flat)
        #expect(Backchannel.isMisheardFragment("Bread.", sound: short))
        #expect(Backchannel.isMisheardFragment("Movie.", sound: mmhm))
        #expect(Backchannel.isBackchannel("Movie.", inHold: true, sound: mmhm))
        #expect(!Backchannel.isBackchannel("Movie.", inHold: true, final: false, sound: mmhm), "a partial never")
        for s in [Self.question,                                                          // q08 live-like
                  FragmentSound(voiced: 0.3, syllables: 2, pitchEnd: .rising, endSemitones: 4),   // "Lettuce?"
                  FragmentSound(voiced: 0.4, syllables: 3, pitchEnd: .falling),                // 3 syllables
                  FragmentSound(voiced: 0.5, syllables: 1, pitchEnd: .flat),                   // too long
                  FragmentSound(voiced: 0.04, syllables: 1, pitchEnd: .unknown)] {             // nothing heard
            #expect(!Backchannel.isMisheardFragment("Movie.", sound: s), "\(s)")
        }
        #expect(!Backchannel.isMisheardFragment("Movie.", sound: nil))
    }

    /// A misspelling of a known "go on" is one by its words, unless it sounded like a question.
    @Test func misspellingsOfKnownWordsGoOnUnlessTheySoundLikeAQuestion() {
        for w in ["Listenin.", "Sleep.", "Gooing.", "Absolutly.", "Grant."] {
            #expect(Backchannel.isMisheardFragment(w), "\(w)")
            #expect(!Backchannel.isMisheardFragment(w, sound: Self.question), "\(w)")
        }
        for w in ["Movie.", "Music.", "Mine.", "Year.", "None.", "Eight."] {
            #expect(!Backchannel.isMisheardFragment(w), "\(w)")
        }
    }

    @Test func soundShapes() {
        #expect(Self.question.questionLike && !Self.question.backchannelLike)
        #expect(FragmentSound(voiced: 0.3, syllables: 1, pitchEnd: .rising, endSemitones: 3).questionLike)
        #expect(!FragmentSound(voiced: 0.0, syllables: 0, pitchEnd: .unknown).questionLike)
        #expect(FragmentSound(voiced: 0.45, syllables: 2, pitchEnd: .falling).backchannelLike)
    }

    /// q08 in the tune-8 RoomSim: ~0.6 s of voice, 2–3 syllables, falling.
    static let question = FragmentSound(voiced: 0.6, syllables: 3, pitchEnd: .falling, endSemitones: -6)
}

// MARK: - The analyzer on frames

@Suite struct FragmentSoundAnalyzeTests {
    private func frames(_ spec: [(db: Double, f0: Double?)]) -> [FragmentSound.Frame] {
        spec.enumerated().map { i, s in
            FragmentSound.Frame(t: Double(i + 1) * 0.04, dt: 0.04, db: s.db, near: s.db > -60,
                                pitched: s.db > -60 && s.f0 != nil, f0: s.f0)
        }
    }

    @Test func countsSyllablesByEnergyDipsAndGaps() {
        // "who | made you": a gap, then a dip inside one run of voice.
        let x = frames([(-30, 200), (-28, 200), (-70, nil), (-70, nil), (-29, 190), (-27, 185), (-34, 180),
                        (-36, 170), (-28, 150), (-29, 145)])
        let s = FragmentSound.analyze(x)
        #expect(s.syllables == 3, "\(s)")
        #expect(abs(s.voiced - 0.32) < 1e-9)
        #expect(s.pitchEnd == .falling, "\(s)")
    }

    @Test func aRisingEndIsRising() {
        let x = frames([(-30, 180), (-29, 180), (-29, 182), (-30, 185), (-30, 200), (-31, 215), (-31, 225)])
        let s = FragmentSound.analyze(x)
        #expect(s.pitchEnd == .rising, "\(s)")
        #expect(s.syllables == 1)
    }

    @Test func unpitchedSoundIsNoSyllable() {
        let s = FragmentSound.analyze(frames([(-30, nil), (-30, nil), (-31, nil)]))
        #expect(s.syllables == 0 && s.voiced == 0 && !s.heard)
    }
}

// MARK: - Real speech in the room (the harness's fixtures, the way tune 8 played them)

@Suite(.serialized) struct FragmentSoundRoomTests {
    /// Fixture `id` said 2.2 s into Dee's reply (l02), its server item from 0.3 s before
    /// its onset to 0.15 s after its end; what the ear says it sounded like.
    private func sound(_ id: String, _ cond: String) throws -> FragmentSound? {
        var sim = RoomSim(seconds: 7, aec: cond != "echo20")
        if cond == "fan15" { sim.setBed(try HarnessFixture.wav("noise/fan.wav"), snrDB: 15) }
        if cond == "echo20" { sim.setEcho(gainDB: -20, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav")) }
        RoomSim.place(try herReply("l02", seconds: 6), into: &sim.her, at: RoomSim.sample(0.3))
        let u = try sim.say(id, at: 2.5)
        sim.server = [(u.onset + RoomSim.sample(0.3), .start("item_u", onsetSample: u.onset - RoomSim.sample(0.3))),
                      (u.end + RoomSim.sample(0.45), .stop("item_u", endSample: u.end + RoomSim.sample(0.15)))]
        sim.run()
        return sim.core.itemSound(itemID: "item_u", until: RoomSim.time(u.end + RoomSim.sample(0.5)))
    }

    /// interrupt-echo20 q08 (live T8-1) and fan15 / clean: "Who made you?" never sounds like
    /// a backchannel, so "Movie." is a turn even with its sound; "Go on." (bc01) always does,
    /// so even a word the words don't know would let Dee go on.
    @Test(arguments: ["clean", "fan15", "echo20"])
    func whoMadeYouNeverSoundsLikeABackchannel(cond: String) throws {
        let q08 = try #require(try sound("q08", cond))
        #expect(!q08.backchannelLike, "\(cond): \(q08)")
        #expect(q08.voiced > FragmentSound.backchannelMaxVoiced, "\(cond): \(q08)")
        #expect(!Backchannel.isMisheardFragment("Movie.", sound: q08))
        #expect(!Backchannel.isBackchannel("Movie.", inHold: true, sound: q08))
        let goOn = try #require(try sound("bc01", cond))
        #expect(goOn.backchannelLike, "\(cond): \(goOn)")
        #expect(Backchannel.isMisheardFragment("Bread.", sound: goOn))
        // A longer question too (q04 "Do you like music?" → "Music.").
        let q04 = try #require(try sound("q04", cond))
        #expect(q04.questionLike && !q04.backchannelLike, "\(cond): \(q04)")
    }
}

// MARK: - The live loop: "Who made you?" heard as "Movie." in a hold

extension LoopRig {
    /// Fixture `id` at the microphone (24 kHz → the rig's 48 kHz), from just before its
    /// onset to just after its end, 20 ms at a time.
    func say(_ id: String) throws {
        let u = try HarnessFixture.utterance(id)
        let a = max(0, u.onset - 480), b = min(u.samples.count, u.end + 480)
        let x = Array(u.samples[a..<b])
        var up = [Float](repeating: 0, count: x.count * 2)
        for i in 0..<x.count {
            up[2 * i] = x[i]
            up[2 * i + 1] = i + 1 < x.count ? (x[i] + x[i + 1]) / 2 : x[i]
        }
        for f in Signal.frames(up, size: Int(Self.rate * 0.02)) { try step(f) }
    }
}

@Suite(.serialized) struct MovieOverHerLoopTests {
    /// t2-interrupt-echo20 50.0–51.9 (tune 8): onset 50.16 over Dee's reply, the voice's quick
    /// commit 51.09, partial "Movie." 51.29, final 51.54 → Dee went on and the question was
    /// never answered. Here: the real "Who made you?" pauses Dee, its words come back as
    /// "Movie." — Dee stays paused, the hold's verdict is "answer", the voice never resumes,
    /// and the brain's checks (`isHoldBackchannel`, `isMisheardFragment(itemID:text:)`) agree.
    @Test func movieOverHerIsAnsweredNotResumed() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 8000)])
        try rig.quiet(1.0)
        let micAt = rig.uplinkMsNow
        try rig.say("q08")
        rig.push(Srv.speechStarted("item_u2", ms: micAt + 100))
        await rig.settle()
        try #require(rig.voice.floorHold?.itemID == "item_u2", "Dee was not paused")
        let commit = try #require(try await rig.stepUntil(0.8) { !rig.sent("input_audio_buffer.commit").isEmpty },
                                  "never committed their words")
        _ = commit
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.2)
        rig.deltas("item_u2", ["Movie", "."])
        try rig.quiet(0.25)
        await rig.settle()
        let sound = try #require(rig.voice.itemSound(itemID: "item_u2"))
        #expect(!sound.backchannelLike, "\(sound)")
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Movie."), "\(sound)")
        #expect(!rig.voice.isHoldBackchannel(itemID: "item_u2", text: "Movie."), "\(sound)")
        rig.push(Srv.userTranscript("item_u2", "Movie."))
        try rig.quiet(0.15)
        await rig.settle()
        #expect(rig.voice.floorHold?.wordsAt != nil, "\"Movie.\" was not taken as a real turn")
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Movie."))
        #expect(!rig.voice.isHoldBackchannel(itemID: "item_u2", text: "Movie."))
        #expect(!holds.all.contains { if case .resumed = $0 { true } else { false } }, "\(holds.all)")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u2"))
        rig.voice.shutdown()
    }

    /// The control: the real "Go on." (bc01) over Dee whose words come back as a word the
    /// rule doesn't know ("Bread.") sounded like a backchannel: Dee goes on, by its words
    /// and sound, as before tune 8 (decision: backchannels continue Dee).
    @Test func goOnHeardAsAnUnknownWordStillResumesByItsSound() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 8000)])
        try rig.quiet(1.0)
        let micAt = rig.uplinkMsNow
        try rig.say("bc01")
        rig.push(Srv.speechStarted("item_u2", ms: micAt + 100))
        await rig.settle()
        try #require(rig.voice.floorHold?.itemID == "item_u2", "Dee was not paused")
        #expect(try await rig.stepUntil(0.8) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", ["Bread", "."])
        try rig.quiet(0.25)
        rig.push(Srv.userTranscript("item_u2", "Bread."))
        let resumed = try await rig.stepUntil(1.0) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "never went on: \(String(describing: rig.voice.itemSound(itemID: "item_u2")))")
        #expect(holds.all.contains { if case .resumed(["item_u2"], _, "words") = $0 { true } else { false } }, "\(holds.all)")
        #expect(rig.voice.wasBackchannel(itemID: "item_u2"))
        #expect(rig.voice.isMisheardFragment(itemID: "item_u2", text: "Bread."))
        rig.voice.shutdown()
    }
}
