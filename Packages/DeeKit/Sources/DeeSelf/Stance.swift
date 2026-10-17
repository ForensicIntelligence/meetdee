import DeeCore
import DeeMind
import Foundation

/// SELF.md §3.5 — the resolved interpretation of now. Everything any expressive
/// channel reads; a projection's only parameter is `Stance`.
public struct Stance: Sendable, Equatable {
    /// THE one emotion: face, voice, tag reconciliation.
    public var expression: Emotion
    /// 0…1.
    public var intensity: Double
    /// −1…1 → eye tint.
    public var regard: Double
    public var energy: Double
    /// playfulness·humorReceptiveness > 0.3 && repair == .fine && no distress hypothesis.
    public var playGate: Bool
    public var floor: Floor
    public var focus: Focus
    /// Resolved here, not in the projection, so tests see it.
    public var gaze: GazeIntent
    /// Only while .userSpeaking / .userPaused.
    public var listen: ListenPreview?
    public var beatStep: BeatStep?
    /// Chosen this step (beat > backchannel > signature reaction).
    public var mannerism: Mannerism?
    public var uncertainty: Double
    /// ≤ 2, chosen by NotePicker (set by `Cortex.cue(at:)`).
    public var notes: [Note]
    public var age: Double?
    /// Ready face, lid softening, tilt (winners of `Momentary.faceRequests`).
    public var face: FaceModifiers

    public init(expression: Emotion = .neutral, intensity: Double = 0.3, regard: Double = 0, energy: Double = 0.8,
                playGate: Bool = false, floor: Floor = .idle, focus: Focus = .none,
                gaze: GazeIntent = GazeIntent(target: .wander, hold: 0), listen: ListenPreview? = nil,
                beatStep: BeatStep? = nil, mannerism: Mannerism? = nil, uncertainty: Double = 0,
                notes: [Note] = [], age: Double? = nil, face: FaceModifiers = FaceModifiers()) {
        self.expression = expression
        self.intensity = intensity
        self.regard = regard
        self.energy = energy
        self.playGate = playGate
        self.floor = floor
        self.focus = focus
        self.gaze = gaze
        self.listen = listen
        self.beatStep = beatStep
        self.mannerism = mannerism
        self.uncertainty = uncertainty
        self.notes = notes
        self.age = age
        self.face = face
    }
}

/// Modifiers layered on the expression; each field is the winner of its requests
/// (`ChannelPriority`, ties → last), 0 when nobody asked.
public struct FaceModifiers: Sendable, Equatable {
    /// 0…1.
    public var readyFace: Double
    /// 0…1.
    public var lidSoften: Double
    /// −1…1.
    public var tilt: Double

    public init(readyFace: Double = 0, lidSoften: Double = 0, tilt: Double = 0) {
        self.readyFace = readyFace
        self.lidSoften = lidSoften
        self.tilt = tilt
    }
}

public struct GazeIntent: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Face position from the camera.
        case user
        /// Touch / front-camera hand.
        case point(SIMD2<Double>)
        /// Back-camera referent: eyes drop and narrow (gazeY +0.35, lids 0.2).
        case examineBack
        /// Sound direction guess, −1…1.
        case side(Double)
        /// Thinking aversion, up-left.
        case away
        /// Idle director.
        case wander

        public var name: String {
            switch self {
            case .user: "user"
            case .point: "point"
            case .examineBack: "examineBack"
            case .side: "side"
            case .away: "away"
            case .wander: "wander"
            }
        }
    }
    public var target: Target
    public var hold: TimeInterval

    public init(target: Target, hold: TimeInterval) {
        self.target = target
        self.hold = hold
    }
}

// MARK: - Emotion bands and tag reconciliation (§3.5)

public enum EmotionBand: String, Sendable, Equatable, CaseIterable {
    case positive, neutral, negLow, negHigh

    public init(_ e: Emotion) {
        switch e {
        case .happy, .joy, .love, .excited, .giddy, .playful, .proud, .content, .relieved, .hopeful, .awe, .smug,
             .mischievous, .shy, .dreamy: self = .positive
        case .sad, .hurt, .worried, .lonely, .scared, .overwhelmed: self = .negLow
        case .angry, .grumpy, .unimpressed: self = .negHigh
        case .neutral, .curious, .thinking, .surprised, .confused, .skeptical, .determined, .bored, .sleepy, .dizzy,
             .pleading, .listening, .asleep: self = .neutral
        }
    }

    /// The mood band from the snapshot: anger > 0.4 or regard < −0.5 → negHigh;
    /// valence < −0.25 → negLow; valence > 0.2 → positive; else neutral.
    public init(mood m: MindSnapshot) {
        if m.code.feelings[.anger] > 0.4 || m.regard < -0.5 { self = .negHigh }
        else if m.valence < -0.25 { self = .negLow }
        else if m.valence > 0.2 { self = .positive }
        else { self = .neutral }
    }

    /// Band distance: positive–neutral 1, neutral–negLow 1, negLow–negHigh 1,
    /// positive–negLow 2, positive–negHigh 2, neutral–negHigh 1.
    public func distance(to o: EmotionBand) -> Int {
        if self == o { return 0 }
        let pair = Set([self, o])
        if pair == [.positive, .negLow] || pair == [.positive, .negHigh] { return 2 }
        return 1
    }
}

public enum TagReconciler {
    /// Why a tag was kept or replaced (tests, traces).
    public enum Verdict: String, Sendable, Equatable {
        case kept, exemptReflex, exemptAffection, exemptWry, substituted
    }

    /// Reconciles the LLM's sentence tag with Dee's mood (§3.5). Substitutes only at
    /// band distance 2 and only when none of the exemptions hold:
    /// - a reflex in the tag's band is live (≤ 4 s): Dee can laugh while upset;
    /// - the tag is positive and regard > 0.3: affection coexisting with frustration;
    /// - the tag is smug or mischievous while the mood is negHigh: wry.
    public static func reconcile(_ tag: Emotion, mind: MindSnapshot, liveReflex: Emotion?) -> (emotion: Emotion, verdict: Verdict) {
        let tagBand = EmotionBand(tag)
        let moodBand = EmotionBand(mood: mind)
        guard tagBand.distance(to: moodBand) == 2 else { return (tag, .kept) }
        if let r = liveReflex, EmotionBand(r) == tagBand { return (tag, .exemptReflex) }
        if tagBand == .positive, mind.regard > 0.3 { return (tag, .exemptAffection) }
        if (tag == .smug || tag == .mischievous), moodBand == .negHigh { return (tag, .exemptWry) }
        return (substitute(tag, into: moodBand), .substituted)
    }

    /// The nearest emotion in `band` by a fixed table (always lands in `band`).
    public static func substitute(_ tag: Emotion, into band: EmotionBand) -> Emotion {
        switch band {
        case .negLow:
            switch tag {
            case .love, .proud, .smug, .mischievous, .shy: return .hurt
            case .excited, .relieved, .hopeful: return .worried
            case .giddy: return .overwhelmed
            case .awe: return .scared
            case .dreamy: return .lonely
            default: return .sad
            }
        case .negHigh:
            switch tag {
            case .love, .excited, .giddy, .content, .relieved, .hopeful, .shy: return .grumpy
            default: return .unimpressed
            }
        case .positive:
            switch tag {
            case .hurt: return .shy
            case .scared: return .relieved
            case .overwhelmed: return .giddy
            case .angry: return .mischievous
            case .grumpy: return .playful
            case .unimpressed: return .smug
            default: return .hopeful
            }
        case .neutral:
            return EmotionBand(tag) == .neutral ? tag : .neutral
        }
    }
}

// MARK: - Stance.resolve

extension Moment {
    /// §3.5: playfulness·humorReceptiveness > 0.3 && repair == .fine && no distress
    /// hypothesis. Reducers gate playful notes on this (it equals `stance.playGate`).
    public var playGate: Bool {
        let playfulness = ongoing.effectivePersonality[.playfulness]
        return playfulness * profile.humorReceptiveness > 0.3 && ongoing.repair == .fine && !ongoing.distressLive(at: now)
    }
}

/// Emotions calm enough to show the `thinking` face while Dee prepares a reply
/// (same set as `FaceAnimator.calmForThinking`, which is internal to DeeFace).
public let calmForThinking: Set<Emotion> = [.neutral, .happy, .curious, .thinking, .listening, .sleepy, .content, .bored]

extension Stance {
    public static let reflexIntensity = 0.8

    /// THE interpretation of now. Pure: the same moment and rng state give the same stance.
    /// It reads state, never decides policy: gaze, face modifiers, mannerisms and
    /// uncertainty are the winners of the reducers' requests by the §5 tables.
    public static func resolve(_ m: Moment, _ rng: inout Rand) -> Stance {
        resolveDetailed(m, &rng).stance
    }

    /// `resolve`, plus whether the mannerism came from a signature pick (Cortex keeps
    /// `recentMannerisms` for the no-3-in-a-row rule).
    static func resolveDetailed(_ m: Moment, _ rng: inout Rand) -> (stance: Stance, signature: Bool) {
        let now = m.now
        let mo = m.momentary
        let mind = m.ongoing.mind
        let active = mo.beat?.step(at: now)
        let reflex = mo.reflex?.live(at: now)
        let tag = mo.llmTag?.live(at: now)

        // Expression precedence (first match wins).
        var expression: Emotion
        var intensity = clamp01(0.3 + 0.6 * mind.arousal)
        if let reflex {
            expression = reflex
            intensity = max(intensity, reflexIntensity)
        } else if let overlay = active?.step.overlay {
            expression = overlay
        } else if let tag {
            expression = tag
            intensity = max(intensity, 0.6)
        } else {
            switch mo.floor {
            case .userSpeaking, .userPaused:
                expression = .listening
                intensity = mo.preview?.intensity ?? 0.3
            case .deeThinking:
                expression = calmForThinking.contains(mind.emotion) ? .thinking : mind.emotion
            default:
                expression = mind.emotion
            }
        }
        intensity = clamp01(intensity + (active?.step.intensityBoost ?? 0))

        let playGate = m.playGate

        let listen: ListenPreview? = mo.floor.isUserTurn ? mo.preview : nil

        // Mannerism: the best request (beat > backchannel > signature reaction).
        var mannerism: Mannerism?
        var signature = false
        if let r = winner(mo.mannerismRequests, by: { $0.rank.rawValue }) {
            switch r.what {
            case .mannerism(let x):
                mannerism = x
            case .signature(let slot):
                mannerism = m.enduring.signature.pick(slot, energy: mind.mood.energy, playGate: playGate,
                                                      recent: mo.recentMannerisms, rng: &rng)
                signature = mannerism != nil
            }
        }

        let stance = Stance(expression: expression, intensity: intensity, regard: mind.regard, energy: mind.mood.energy,
                            playGate: playGate, floor: mo.floor, focus: mo.focus,
                            gaze: gaze(mo.gazeRequests), listen: listen, beatStep: active?.step,
                            mannerism: mannerism, uncertainty: mo.uncertainty, notes: [], age: mind.age,
                            face: face(mo.faceRequests))
        return (stance, signature)
    }

    /// The request with the lowest rank; among equals the last one appended.
    static func winner<T>(_ items: [T], by rank: (T) -> Int) -> T? {
        var best: T?
        var bestRank = Int.max
        for x in items {
            let r = rank(x)
            if r <= bestRank {
                best = x
                bestRank = r
            }
        }
        return best
    }

    /// Gaze priority (§5) over this step's requests; `.wander` when nobody asked.
    /// Who asks: Attention (touch point 1, sound side / back referent 6), Beats (beat
    /// step 2), FloorKeeper (Dee speaking / thinking 4, user's turn and yielding 5);
    /// triadic joint attention (3) arrives with Attention 0.5.4.
    public static func gaze(_ requests: [GazeRequest]) -> GazeIntent {
        guard let r = winner(requests, by: { $0.priority.rawValue }) else { return GazeIntent(target: .wander, hold: 0) }
        return GazeIntent(target: r.target, hold: r.hold)
    }

    /// Each face field: its best request by `ChannelPriority` (ties → last), else 0.
    public static func face(_ requests: [FaceRequest]) -> FaceModifiers {
        func pick(_ f: FaceField) -> Double { winner(requests.filter { $0.field == f }, by: { $0.priority.rawValue })?.value ?? 0 }
        return FaceModifiers(readyFace: clamp01(pick(.readyFace)), lidSoften: clamp01(pick(.lidSoften)), tilt: clamp(pick(.tilt), -1, 1))
    }

    /// A deterministic direction guess for a sound (no microphone array): −1…1.
    public static func soundSide(_ s: Subject) -> Double { StableHash.unit(s.text, seed: 0x50_55_4E_44) * 0.8 }
}
