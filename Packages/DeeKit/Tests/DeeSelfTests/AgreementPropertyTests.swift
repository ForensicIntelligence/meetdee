import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// SELF.md §12.3 — 10,000 random seeded percept sequences of 200 steps each; the §5
/// agreement invariants must hold at every step. Split into 16 parallel chunks: ≈ 2 M Cortex
/// steps, ≈ 1,300 CPU-s in a debug build (≈ 80 s wall on a 16+ core Mac). It is the slowest
/// test by design (§12.3 fixes the size); more chunks only starve the other suites.
@Suite struct AgreementPropertyTests {
    static let sequences = 10_000
    static let steps = 200
    static let chunks = 16

    /// A fixed pool of moods (building snapshots is the expensive part).
    static let pool: [MindSnapshot] = {
        var rng = Rand(seed: 0xA9_EE)
        var out = [Kit.snap(), Kit.angry, Kit.sad, Kit.happyNeutralRegard, Kit.fondButCross, CueWriterTests.worstMood]
        for _ in 0..<58 { out.append(MindSnapshot(code: CueWriterTests.randomCode(&rng), age: rng.chance(0.3) ? rng.double(in: 0...90) : nil)) }
        return out
    }()

    static let words = ["look", "at", "this", "painting", "I", "made", "you're", "so", "funny", "haha", "my", "job", "interview",
                        "is", "tomorrow", "and", "um", "the", "dog", "rain", "sorry", "thanks", "stupid", "love", "you", "what"]

    static func sentence(_ rng: inout Rand, _ n: Int) -> String {
        (0..<n).map { _ in words[rng.index(words.count)] }.joined(separator: " ")
    }

    static func randomPercept(_ rng: inout Rand) -> Percept {
        let emotions = Emotion.allCases
        switch rng.index(22) {
        case 0, 1: return .partial(sentence(&rng, 1 + rng.index(6)))
        case 2: return .pause(turnEnd: rng.unit(), hesitation: rng.unit())
        case 3: return .heard(text: sentence(&rng, 1 + rng.index(10)), durationS: rng.double(in: 0.3...6), loudnessVsBaseline: rng.double(in: -1...1), appraisal: Appraisal())
        case 4: return .sound(label: ["doorbell", "dog", "siren", "music", "laughter"][rng.index(5)], unexpected: rng.chance(0.5))
        case 5: return .sight(camera: rng.chance(0.5) ? .front : .back, things: ["guitar", "lamp", "cat"].filter { _ in rng.chance(0.5) }, novel: rng.chance(0.3) ? ["guitar"] : [])
        case 6: return .head(yaw: rng.double(in: -60...60), pitch: rng.double(in: -30...20))
        case 7: return rng.chance(0.5) ? .faceLost : .presence(arrived: rng.chance(0.5))
        case 8: return .identified(rng.chance(0.7) ? Kit.john : nil, distance: Float(rng.unit()))
        case 9: return .touch(kind: "tap", gentle: rng.chance(0.5), at: rng.chance(0.7) ? SIMD2(rng.unit(), rng.unit()) : nil)
        case 10: return .gesture(["wave", "palm", "thumbsUp"][rng.index(3)])
        case 11, 12: return .promptSubmitted
        case 13, 14: return .deeSaid(tag: rng.chance(0.7) ? emotions[rng.index(emotions.count)] : nil, sentence: sentence(&rng, 4))
        case 15: return .deeTurnFinished(text: sentence(&rng, 8))
        case 16: return .speakingStarted
        case 17: return .speakingFinished
        case 18: return .bargeIn
        case 19: return rng.chance(0.1) ? .conversationStarted(Kit.t0) : .asleep(rng.chance(0.2))
        default: return .tick
        }
    }

    static func randomNotes(_ rng: inout Rand) -> [Note] {
        (0..<(1 + rng.index(4))).map { _ in
            let k = Note.Kind.allCases[rng.index(Note.Kind.allCases.count)]
            return Note(k, slots: NoteTemplates.longestSlots(k), episode: rng.uuid(), facet: rng.uuid(), gag: rng.uuid())
        }
    }

    /// Returns a description of the first violation, or nil.
    static func check(sequence seed: UInt64) -> String? {
        var rng = Rand(seed: seed)
        var cx = Kit.cortex(seed: seed &* 31, mind: pool[0])
        var t = 0.0
        var seq: UInt64 = 0
        for i in 0..<steps {
            t += rng.double(in: 0.05...3)
            if rng.chance(0.3) { seq += 1 }
            var mind = pool[rng.index(pool.count)].with(seq: seq)
            mind.reflex = rng.chance(0.1) ? Emotion.allCases[rng.index(Emotion.allCases.count)] : nil
            let p = randomPercept(&rng)
            let now = Kit.t0.addingTimeInterval(t)
            let floorBefore = cx.moment.momentary.floor
            _ = cx.step(p, mind: mind, at: now)
            let s = cx.stance
            let mo = cx.moment.momentary
            let face = Projection.expression(s)
            let voice = Projection.voice(s)
            func fail(_ why: String) -> String { "seed \(seed) step \(i) \(describe(p)): \(why)" }

            // Face emotion == voice emotion == stance.expression.
            if face.emotion != s.expression || voice.emotion != s.expression { return fail("face/voice disagree") }
            // Transcript tag == reconciled tag. (A sentence arriving after a barge-in is
            // stale: Dee already stopped, so it is never spoken or shown.)
            let stale: Bool = if case .yielding = floorBefore { true } else { false }
            if case .deeSaid(let tag?, _) = p, !stale {
                let want = TagReconciler.reconcile(tag, mind: cx.moment.ongoing.mind, liveReflex: mo.reflex?.live(at: cx.moment.now)).emotion
                if cx.reconciledTag != want { return fail("transcript tag \(String(describing: cx.reconciledTag)) != reconciled \(want)") }
                if mo.reflex?.live(at: cx.moment.now) == nil, s.beatStep?.overlay == nil, s.expression != want {
                    return fail("face \(s.expression) != spoken tag \(want)")
                }
            }
            // Gaze consistent with focus and floor.
            let touching = mo.touchPoint?.live(at: cx.moment.now) != nil
            if !touching, s.beatStep == nil {
                switch s.floor {
                case .userSpeaking, .userPaused:
                    if s.gaze.target != .user { return fail("gaze \(s.gaze.target.name) while the user speaks") }
                case .deeSpeaking:
                    if s.gaze.target != .user && s.gaze.target != .away { return fail("gaze \(s.gaze.target.name) while Dee speaks") }
                case .idle:
                    if case .sound = s.focus, case .side = s.gaze.target {} else if case .sound = s.focus { return fail("sound focus without side gaze") }
                default: break
                }
            }
            if s.gaze.target == .wander, s.floor.isUserTurn { return fail("wander during the user's turn") }
            if s.listen != nil, !s.floor.isUserTurn { return fail("listen preview outside the user's turn") }

            // Notes and the cue.
            if rng.chance(0.05) {
                var m = cx.moment
                m.ongoing.noteCandidates += randomNotes(&rng)
                cx = Cortex.restoring(cx, moment: m)
            }
            if case .promptSubmitted = p {
                let cue = cx.cueText(at: now)
                let notes = cx.stance.notes
                if notes.count > 2 || notes.filter({ $0.role == .aim }).count > 1 { return fail("notes \(notes.map(\.kind))") }
                if CueWriter.estimateTokens(cue) > CueWriter.maxTokens { return fail("cue \(cue.count) chars") }
                let mind = cx.moment.ongoing.mind
                // The reunion turn leaves "lonely" out of the mood (review finding 3).
                let moods = [CueWriter.mood(mind), CueWriter.mood(code: mind.code, age: mind.age, omit: ["lonely"])]
                guard let mood = moods.first(where: { cue.hasPrefix(CueWriter.open + $0) }) else { return fail("mood sentence missing") }
                let tail = CueWriter.notesPart(of: cue, mood: mood).lowercased()
                if let w = CueWriter.reproachWords.first(where: tail.contains) { return fail("reproach '\(w)' in \(tail)") }
            }
        }
        return nil
    }

    @Test(arguments: 0..<chunks)
    func agreementHoldsEverywhere(chunk: Int) {
        let per = Self.sequences / Self.chunks
        for i in 0..<per {
            if let why = Self.check(sequence: UInt64(chunk * per + i) &+ 0x5E1F) {
                Issue.record(Comment(rawValue: why))
                return
            }
        }
    }
}
