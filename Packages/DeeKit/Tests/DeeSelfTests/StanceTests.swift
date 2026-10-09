import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct StanceTests {
    static func resolve(_ m: Moment, seed: UInt64 = 1) -> Stance {
        var rng = Rand(seed: seed)
        return Stance.resolve(m, &rng)
    }

    static func beat(overlay: Emotion? = .excited, gaze: BeatStep.Gaze = .down, mannerism: Mannerism? = .doubleTake, at: Date = Kit.t0) -> Beat {
        Beat(kind: .examine, steps: [BeatStep(gaze: gaze, overlay: overlay, intensityBoost: 0.2, mannerism: mannerism, duration: 1),
                                    BeatStep(gaze: .user, overlay: nil, mannerism: .nod, duration: 1)], started: at)
    }

    // MARK: Expression precedence (first match wins)

    @Test func precedenceTable() {
        let now = Kit.t0
        var m = Kit.moment(mind: Kit.happyNeutralRegard)
        m.momentary.floor = .userSpeaking(since: now)
        m.momentary.llmTag = Timed(.curious, until: now.addingTimeInterval(10))
        m.momentary.beat = Self.beat()
        m.momentary.reflex = Timed(.giddy, until: now.addingTimeInterval(4))
        #expect(Self.resolve(m).expression == .giddy, "1. live reflex")
        m.momentary.reflex = Timed(.giddy, until: now)   // expired
        #expect(Self.resolve(m).expression == .excited, "2. beat overlay")
        m.momentary.beat = Self.beat(overlay: nil)
        #expect(Self.resolve(m).expression == .curious, "3. reconciled tag (beat step without overlay falls through)")
        m.momentary.llmTag = nil
        #expect(Self.resolve(m).expression == .listening, "4. floor overlay: user speaking")
        m.momentary.floor = .userPaused(since: now, turnEnd: 0.2, hesitation: 0)
        #expect(Self.resolve(m).expression == .listening)
        m.momentary.floor = .idle
        #expect(Self.resolve(m).expression == Kit.happyNeutralRegard.emotion, "5. mood")
    }

    @Test func thinkingFaceOnlyWhenCalm() {
        var m = Kit.moment(mind: Kit.snap())
        m.momentary.floor = .deeThinking(since: Kit.t0)
        #expect(calmForThinking.contains(Kit.snap().emotion))
        #expect(Self.resolve(m).expression == .thinking)
        m.ongoing.mind = Kit.angry
        #expect(!calmForThinking.contains(Kit.angry.emotion))
        #expect(Self.resolve(m).expression == Kit.angry.emotion)
    }

    @Test func expiredTagFallsThrough() {
        var m = Kit.moment()
        m.momentary.llmTag = Timed(.excited, until: Kit.t0.addingTimeInterval(1))
        #expect(Self.resolve(m).expression == .excited)
        m.now = Kit.t0.addingTimeInterval(1)
        #expect(Self.resolve(m).expression == Kit.snap().emotion)
    }

    @Test func intensityRulesAndBoost() {
        var m = Kit.moment()
        m.momentary.reflex = Timed(.giddy, until: Kit.t0.addingTimeInterval(4))
        #expect(Self.resolve(m).intensity >= Stance.reflexIntensity)
        m.momentary.reflex = nil
        m.momentary.beat = Self.beat()
        let base = clamp01(0.3 + 0.6 * Kit.snap().arousal)
        #expect(abs(Self.resolve(m).intensity - min(1, base + 0.2)) < 1e-9)
    }

    @Test func listenOnlyDuringUserTurn() {
        var m = Kit.moment()
        m.momentary.preview = ListenPreview(valence: 0.4, intensity: 0.4, signSince: Kit.t0)
        m.momentary.floor = .userSpeaking(since: Kit.t0)
        #expect(Self.resolve(m).listen != nil)
        m.momentary.floor = .deeSpeaking(since: Kit.t0)
        #expect(Self.resolve(m).listen == nil)
    }

    // MARK: playGate

    @Test func playGate() {
        var m = Kit.moment()
        #expect(Self.resolve(m).playGate, "default: playfulness 0.8 × receptiveness 0.5 = 0.4 > 0.3")
        m.ongoing.repair = .strained
        #expect(!Self.resolve(m).playGate)
        m.ongoing.repair = .fine
        m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.6, expires: Kit.t0.addingTimeInterval(60))]
        #expect(!Self.resolve(m).playGate, "distress hypothesis")
        m.ongoing.hypotheses = []
        var p = SocialProfile()
        p.humorReceptiveness = 0.3
        m.enduring.profiles[Kit.john] = p
        m.ongoing.person = Kit.john
        #expect(!Self.resolve(m).playGate, "0.8 × 0.3 = 0.24")
    }

    // MARK: Gaze priority (generic arbitration of requests)

    @Test func gazePriority() {
        var m = Kit.moment()
        #expect(Self.resolve(m).gaze.target == .wander, "7. idle: nobody asked")
        m.momentary.requestGaze(.side(0.3), hold: 1.2, priority: .focus, by: "Attention")
        #expect(Self.resolve(m).gaze == GazeIntent(target: .side(0.3), hold: 1.2), "6. focus")
        m.momentary.requestGaze(.user, hold: 1, priority: .userTurn, by: "FloorKeeper")
        #expect(Self.resolve(m).gaze.target == .user, "5. user's turn")
        m.momentary.requestGaze(.away, hold: 0.6, priority: .deeTurn, by: "FloorKeeper")
        #expect(Self.resolve(m).gaze.target == .away, "4. Dee's turn")
        m.momentary.requestGaze(.user, hold: 0.3, priority: .jointAttention, by: "Attention")
        #expect(Self.resolve(m).gaze == GazeIntent(target: .user, hold: 0.3), "3. joint attention")
        m.momentary.requestGaze(.examineBack, hold: 1, priority: .beat, by: "Beats")
        #expect(Self.resolve(m).gaze.target == .examineBack, "2. beat step")
        m.momentary.requestGaze(.point(SIMD2(0.2, 0.3)), hold: 0.5, priority: .touch, by: "Attention")
        #expect(Self.resolve(m).gaze.target == .point(SIMD2(0.2, 0.3)), "1. touch")
        // Order of arrival never matters across priorities; within one, the later wins.
        let shuffled = m.momentary.gazeRequests.reversed()
        #expect(Stance.gaze(Array(shuffled)).target == .point(SIMD2(0.2, 0.3)))
        #expect(Stance.gaze([GazeRequest(.away, hold: 1, priority: .focus, owner: "A"), GazeRequest(.user, hold: 1, priority: .focus, owner: "B")]).target == .user)
    }

    /// Through the whole pipeline: the user's turn always wins over a focus.
    @Test func neverWanderWhileUserSpeaks() {
        var cx = Kit.cortex()
        _ = cx.step(.sound(label: "dog", unexpected: true), mind: Kit.snap(), at: Kit.t0)
        if case .side = cx.stance.gaze.target {} else { Issue.record("sound focus → side, got \(cx.stance.gaze.target)") }
        _ = cx.step(.partial("hey"), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(0.5))
        #expect(cx.stance.gaze.target == .user)
        _ = cx.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        _ = cx.step(.pause(turnEnd: 0.2, hesitation: 0.8), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1.5))
        #expect(cx.stance.gaze.target == .user)
    }

    // MARK: Face modifiers

    @Test func faceModifiersPickPerFieldByPriority() {
        var m = Kit.moment()
        #expect(Self.resolve(m).face == FaceModifiers())
        m.momentary.requestFace(.readyFace, 0.7, priority: .userTurn, by: "Listener")
        m.momentary.requestFace(.lidSoften, 0.4, priority: .userTurn, by: "Listener")
        m.momentary.requestFace(.lidSoften, 0.9, priority: .beat, by: "Beats")
        m.momentary.requestFace(.tilt, -3, priority: .idle, by: "Listener")
        let f = Self.resolve(m).face
        #expect(f == FaceModifiers(readyFace: 0.7, lidSoften: 0.9, tilt: -1), "beat beats user turn; tilt clamped")
        let e = Projection.expression(Self.resolve(m))
        #expect(e.readyFace == 0.7 && e.lidSoften == 0.9 && e.tilt == -1)
    }

    @Test func uncertaintyIsTheHighestRequest() {
        var m = Kit.moment()
        #expect(Self.resolve(m).uncertainty == 0)
        m.momentary.requestUncertainty(0.6, by: "Attention")
        m.momentary.requestUncertainty(0.8, by: "Interpreter")
        #expect(Self.resolve(m).uncertainty == 0.8)
    }

    // MARK: Mannerism priority (beat > backchannel > signature reaction)

    @Test func mannerismPriority() {
        var m = Kit.moment()
        m.momentary.requestReaction(.amused, by: "Cortex")
        m.momentary.requestMannerism(.nod, by: "Listener")
        m.momentary.requestMannerism(.doubleTake, rank: .beat, by: "Beats")
        #expect(Self.resolve(m).mannerism == .doubleTake)
        m.momentary.mannerismRequests.removeAll { $0.rank == .beat }
        #expect(Self.resolve(m).mannerism == .nod, "backchannel")
        #expect(m.momentary.backchannel == .nod && m.momentary.reaction == .amused)
        m.momentary.mannerismRequests.removeAll { $0.rank == .backchannel }
        let picked = Self.resolve(m).mannerism
        #expect(picked != nil && m.enduring.signature.repertoire[.amused]!.map(\.mannerism).contains(picked!))
        m.momentary.mannerismRequests = []
        #expect(Self.resolve(m).mannerism == nil)
        m.momentary.requestReaction(.amused, by: "Cortex")
        m.momentary.requestReaction(.greeting, by: "Attention")
        var rng = Rand(seed: 1)
        let r = Stance.resolveDetailed(m, &rng)
        #expect(r.signature && m.enduring.signature.repertoire[.greeting]!.map(\.mannerism).contains(r.stance.mannerism!), "equal rank: the later request")
    }

    @Test func signatureNeverThreeInARow() {
        let sig = Kit.enduring().signature
        var rng = Rand(seed: 3)
        for slot in Signature.Slot.allCases {
            var recent: [Mannerism] = []
            for _ in 0..<500 {
                let m = sig.pick(slot, energy: 0.8, playGate: true, recent: recent, rng: &rng)!
                if recent.count == 2 { #expect(!(recent[0] == m && recent[1] == m)) }
                recent = Array((recent + [m]).suffix(2))
            }
        }
    }

    @Test func signatureWeightsShiftWithState() {
        let w = WeightedMannerism(mannerism: .bounce, base: 0.5, energyBias: 0.8, playBias: 0.3)
        #expect(w.weight(energy: 1, playGate: true) > w.weight(energy: 0, playGate: false))
        #expect(w.weight(energy: 0, playGate: false) >= 0.01)
    }
}
