import DeeCore
import Foundation

// SELF.md §3.2 — the momentary timescale (seconds). RAM only, never stored.

public enum Floor: Sendable, Equatable {
    case idle
    case userSpeaking(since: Date)
    case userPaused(since: Date, turnEnd: Double, hesitation: Double)
    /// Prompt submitted, no audio yet.
    case deeThinking(since: Date)
    case deeSpeaking(since: Date)
    /// The user barged in; Dee stopped.
    case yielding(since: Date)

    public var isUserTurn: Bool {
        switch self {
        case .userSpeaking, .userPaused: true
        default: false
        }
    }

    public var since: Date? {
        switch self {
        case .idle: nil
        case .userSpeaking(let s), .deeThinking(let s), .deeSpeaking(let s), .yielding(let s): s
        case .userPaused(let s, _, _): s
        }
    }

    /// Stable short name (traces, tests).
    public var name: String {
        switch self {
        case .idle: "idle"
        case .userSpeaking: "userSpeaking"
        case .userPaused: "userPaused"
        case .deeThinking: "deeThinking"
        case .deeSpeaking: "deeSpeaking"
        case .yielding: "yielding"
        }
    }
}

public enum Focus: Sendable, Equatable {
    /// nil = an unidentified face.
    case person(PersonID?)
    case referent(Subject, CameraSide)
    case sound(Subject)
    case touch(SIMD2<Double>)
    /// Recalling / thinking.
    case inward
    case none

    public var name: String {
        switch self {
        case .person: "person"
        case .referent(let s, let c): "referent(\(s.text),\(c.rawValue))"
        case .sound(let s): "sound(\(s.text))"
        case .touch: "touch"
        case .inward: "inward"
        case .none: "none"
        }
    }
}

public struct Referent: Sendable, Equatable {
    public enum Source: String, Sendable, Codable, CaseIterable { case sawFront, sawBack, mentioned, heldUp, deeMentioned }
    public var subject: Subject
    public var camera: CameraSide?
    public var sources: Set<Source>
    /// 0…1, half-life 20 s.
    public var salience: Double
    public var lastSeen: Date
    /// Common ground: the user mentioned it, held it up, or replied after Dee named it.
    public var sharedWithUser: Bool

    public init(subject: Subject, camera: CameraSide?, sources: Set<Source>, salience: Double, lastSeen: Date, sharedWithUser: Bool = false) {
        self.subject = subject
        self.camera = camera
        self.sources = sources
        self.salience = salience
        self.lastSeen = lastSeen
        self.sharedWithUser = sharedWithUser
    }
}

public struct ListenPreview: Sendable, Equatable {
    /// −1…1, from a copy of the Appraiser over the partial.
    public var valence: Double
    /// ≤ 0.5.
    public var intensity: Double
    /// Sign flips need a 0.6 s hold.
    public var signSince: Date

    public init(valence: Double, intensity: Double, signSince: Date) {
        self.valence = valence
        self.intensity = intensity
        self.signSince = signSince
    }
}

public struct BeatStep: Sendable, Equatable {
    public enum Gaze: Sendable, Equatable { case user, referent, down, away, keep }
    public var gaze: Gaze
    /// Expression override for this step.
    public var overlay: Emotion?
    public var intensityBoost: Double
    public var mannerism: Mannerism?
    public var duration: TimeInterval

    public init(gaze: Gaze, overlay: Emotion? = nil, intensityBoost: Double = 0, mannerism: Mannerism? = nil, duration: TimeInterval) {
        self.gaze = gaze
        self.overlay = overlay
        self.intensityBoost = intensityBoost
        self.mannerism = mannerism
        self.duration = duration
    }
}

public struct Beat: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case examine, recognize, brighten, listenHesitant, sorryGoOn, reunion }
    public var kind: Kind
    public var steps: [BeatStep]
    public var started: Date

    public init(kind: Kind, steps: [BeatStep], started: Date) {
        self.kind = kind
        self.steps = steps
        self.started = started
    }

    /// Index and step active at `now`, or nil before the start / after the end.
    public func step(at now: Date) -> (index: Int, step: BeatStep)? {
        var t = now.timeIntervalSince(started)
        guard t >= 0 else { return nil }
        for (i, s) in steps.enumerated() {
            if t < s.duration { return (i, s) }
            t -= s.duration
        }
        return nil
    }

    public var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }
}

/// Something that happened to the floor in this step (FloorKeeper writes, any later
/// sub-reducer reads). Cleared at the start of every step.
public enum FloorEvent: String, Sendable, Equatable, Codable {
    /// The user started a turn.
    case userStarted
    /// The user's turn ended (`.heard`).
    case userFinished
    /// The user resumed within 1 s of Dee starting to speak: Dee interrupted them.
    case deeInterrupted
    /// The user barged in while Dee was speaking; Dee was cut off.
    case cutOff
    /// Dee started a sentence.
    case deeSentence
    /// A sentence's LLM tag was replaced by the mood-band substitute.
    case tagSubstituted
    /// Dee finished speaking.
    case deeFinished
}

public struct Momentary: Sendable, Equatable {
    public var floor: Floor = .idle
    public var focus: Focus = .none
    public var focusSince: Date = .distantPast
    /// Cap 12, LRU.
    public var referents: [Referent] = []
    /// From `MindSnapshot.reflex`, 4 s.
    public var reflex: Timed<Emotion>?
    /// Reconciled tag, until speech end + 1.5 s.
    public var llmTag: Timed<Emotion>?
    public var preview: ListenPreview?
    // `uncertainty` (0…1) is the max of this step's `uncertaintyRequests` (Requests.swift).
    public var beat: Beat?
    /// Degrees, front camera.
    public var headYaw: Double?
    public var headPitch: Double?
    public var mutualGazeSince: Date?
    public var lastBackchannel: Date = .distantPast
    /// Waiting for a glanceNow result (≤ 1.2 s).
    public var pendingGlance: Timed<CameraSide>?

    // --- Additions beyond SELF.md §3.2 (see docs/contracts-0.5/self.md, "Deviations") ---

    /// Floor events of the current step (written by FloorKeeper; cleared each step).
    public var floorEvents: [FloorEvent] = []
    /// The last signature mannerisms shown (newest last, ≤ 2), for the no-3-in-a-row rule.
    /// Written by Cortex after `Stance.resolve`.
    public var recentMannerisms: [Mannerism] = []
    /// Index of the beat step whose mannerism was already requested (Beats; once per step).
    public var beatStepShown: Int?
    /// Thinking aversion: gaze `.away` until this time (sentence starts, 30%). FloorKeeper.
    public var aversionUntil: Date?
    /// The touch point while a touch is live (gaze priority 1). Attention.
    public var touchPoint: Timed<SIMD2<Double>>?

    // --- Request channels (Requests.swift). Per step: cleared by `beginStep`. ---

    /// Gaze targets asked for this step; `Stance.resolve` picks by `ChannelPriority`.
    public var gazeRequests: [GazeRequest] = []
    /// Face modifiers (ready face, lid softening, tilt) asked for this step.
    public var faceRequests: [FaceRequest] = []
    /// Mannerisms / signature reactions asked for this step (beat > backchannel > reaction).
    public var mannerismRequests: [MannerismRequest] = []
    /// Uncertainty levels asked for this step (max wins).
    public var uncertaintyRequests: [LevelRequest] = []
    /// "Speak first now" (best score of this step).
    public var initiative: InitiativeRequest?

    // --- Not per step ---

    /// Beat requests; consumed and cleared by `Beats` only.
    public var beatRequests: [BeatRequest] = []
    /// Inter-reducer signals; kept for one extra step (exactly-once via `Moment.inbox(for:)`).
    public var signals: [Signal] = []

    public init() {}
}
