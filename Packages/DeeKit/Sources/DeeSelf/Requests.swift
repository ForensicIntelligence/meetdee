import DeeCore
import Foundation

// The inter-reducer channels (docs/contracts-0.5/self.md, "Reducer author guide").
//
// A sub-reducer never writes a shared expressive field directly. It *requests*: it
// appends a request carrying its own name and a priority from the §5 table, and
// `Stance.resolve` picks the winner generically. Requests are per step: Cortex clears
// them at the start of every step (`Momentary.beginStep`), so a reducer re-asserts a
// request on every step for as long as it wants it.
//
// Tie rule everywhere: among requests of equal priority the one appended *last* wins
// (a later reducer in the pipeline has seen more of this step).

/// SELF.md §5 gaze priority, also used for face modifiers (lower wins).
public enum ChannelPriority: Int, Sendable, Equatable, Comparable, CaseIterable, Codable {
    /// 1. A live touch point.
    case touch = 1
    /// 2. An active beat step.
    case beat = 2
    /// 3. Triadic joint attention after the user acts on a referent.
    case jointAttention = 3
    /// 4. Dee's turn: speaking (user / thinking aversion) and preparing a reply.
    case deeTurn = 4
    /// 5. The user's turn (speaking, paused) and yielding.
    case userTurn = 5
    /// 6. A focus with a direction (sound side, back-camera referent).
    case focus = 6
    /// 7. Idle (the director wanders). Stance falls back to `.wander` with no request.
    case idle = 7

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A gaze target asked for this step.
public struct GazeRequest: Sendable, Equatable {
    public var target: GazeIntent.Target
    public var hold: TimeInterval
    public var priority: ChannelPriority
    /// The requesting reducer's `name`.
    public var owner: String

    public init(_ target: GazeIntent.Target, hold: TimeInterval, priority: ChannelPriority, owner: String) {
        self.target = target
        self.hold = hold
        self.priority = priority
        self.owner = owner
    }
}

/// Face modifiers layered on the expression (they never change *which* emotion shows).
public enum FaceField: String, Sendable, Equatable, CaseIterable, Codable {
    /// 0…1: the attentive "about to answer" face (Listener, near a turn end).
    case readyFace
    /// 0…1: softer, lowered lids (hesitation, `listenHesitant`).
    case lidSoften
    /// −1…1: head/eye tilt (pending question, hesitation after 3.5 s).
    case tilt
}

public struct FaceRequest: Sendable, Equatable {
    public var field: FaceField
    public var value: Double
    public var priority: ChannelPriority
    public var owner: String

    public init(_ field: FaceField, _ value: Double, priority: ChannelPriority, owner: String) {
        self.field = field
        self.value = value
        self.priority = priority
        self.owner = owner
    }
}

/// A one-shot mannerism asked for this step. §5: beat step > backchannel > signature reaction.
public struct MannerismRequest: Sendable, Equatable {
    public enum Rank: Int, Sendable, Equatable, Comparable, CaseIterable {
        case beat = 1, backchannel = 2, reaction = 3
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    public enum What: Sendable, Equatable {
        /// This exact mannerism (beat steps, backchannels).
        case mannerism(Mannerism)
        /// A seeded pick from `Enduring.signature` (never 3 in a row).
        case signature(Signature.Slot)
    }
    public var what: What
    public var rank: Rank
    public var owner: String

    public init(_ what: What, rank: Rank, owner: String) {
        self.what = what
        self.rank = rank
        self.owner = owner
    }
}

/// "Dee wants to speak first now." Cortex turns the best request into
/// `.initiative(cue:)` after the pipeline, only while the floor is idle.
public struct InitiativeRequest: Sendable, Equatable {
    /// The requester's score (IntentionBoard's p); the highest wins.
    public var score: Double
    /// The aim note to lead with (gates already applied by the requester).
    public var aim: Note?
    public var owner: String

    public init(score: Double, aim: Note?, owner: String) {
        self.score = score
        self.aim = aim
        self.owner = owner
    }
}

/// A request for a scripted beat. Consumed (and cleared) only by `Beats`, so a request
/// raised by a reducer after Beats in the pipeline reaches it on the next step.
public struct BeatRequest: Sendable, Equatable {
    public var kind: Beat.Kind
    /// Higher wins when several compete; Beats decides who may preempt a running beat.
    public var priority: Double
    public var owner: String
    public var at: Date

    public init(_ kind: Beat.Kind, priority: Double, owner: String, at: Date) {
        self.kind = kind
        self.priority = priority
        self.owner = owner
        self.at = at
    }
}

/// A level asked for this step (uncertainty): the maximum of the requests wins.
public struct LevelRequest: Sendable, Equatable {
    public var value: Double
    public var owner: String
    public init(_ value: Double, owner: String) {
        self.value = value
        self.owner = owner
    }
}

/// A fact one reducer tells the others ("awkwardSilence", "laughter", "reconciliationBid",
/// "userBoundary", "recallHit", "beatFinished"…). Open-ended by name, so adding one never
/// touches a shared file. Payloads are labels, subjects, ids and numbers — never user text.
///
/// Delivery is exactly once per reader (`Moment.inbox(for:)`): a reducer later in the
/// pipeline than the raiser sees it in the same step; one earlier (or the raiser itself)
/// sees it on the next step. Signals older than that are dropped.
public struct Signal: Sendable, Equatable {
    public var name: String
    public var subject: Subject?
    public var value: Double
    public var id: UUID?
    /// A lexicon label (sound/sight label, enum raw value), never user text.
    public var label: String?
    public var owner: String
    /// `Moment.seq` of the step it was raised in.
    public var seq: UInt64

    public init(_ name: String, subject: Subject? = nil, value: Double = 0, id: UUID? = nil, label: String? = nil,
                owner: String, seq: UInt64) {
        self.name = name
        self.subject = subject
        self.value = value
        self.id = id
        self.label = label
        self.owner = owner
        self.seq = seq
    }
}

// MARK: - Writing requests

extension Momentary {
    /// Clears the per-step channels and drops expired signals. Cortex calls it at the
    /// start of every step (after incrementing `Moment.seq`); test harnesses must too.
    public mutating func beginStep(seq: UInt64) {
        floorEvents = []
        gazeRequests = []
        faceRequests = []
        mannerismRequests = []
        uncertaintyRequests = []
        initiative = nil
        signals.removeAll { $0.seq &+ 1 < seq }
    }

    public mutating func requestGaze(_ target: GazeIntent.Target, hold: TimeInterval, priority: ChannelPriority, by owner: String) {
        gazeRequests.append(GazeRequest(target, hold: hold, priority: priority, owner: owner))
    }

    public mutating func requestFace(_ field: FaceField, _ value: Double, priority: ChannelPriority, by owner: String) {
        faceRequests.append(FaceRequest(field, value, priority: priority, owner: owner))
    }

    /// A specific mannerism (a backchannel by default; Beats uses `.beat`).
    public mutating func requestMannerism(_ m: Mannerism, rank: MannerismRequest.Rank = .backchannel, by owner: String) {
        mannerismRequests.append(MannerismRequest(.mannerism(m), rank: rank, owner: owner))
    }

    /// A signature reaction of `slot` (seeded pick from `Enduring.signature`).
    public mutating func requestReaction(_ slot: Signature.Slot, by owner: String) {
        mannerismRequests.append(MannerismRequest(.signature(slot), rank: .reaction, owner: owner))
    }

    public mutating func requestUncertainty(_ value: Double, by owner: String) {
        uncertaintyRequests.append(LevelRequest(clamp01(value), owner: owner))
    }

    /// Keeps the highest-scoring initiative request of this step.
    public mutating func requestInitiative(score: Double, aim: Note?, by owner: String) {
        if let current = initiative, current.score > score { return }
        var a = aim
        if a != nil, a?.owner == nil { a?.owner = owner }
        initiative = InitiativeRequest(score: score, aim: a, owner: owner)
    }

    public mutating func requestBeat(_ kind: Beat.Kind, priority: Double, at now: Date, by owner: String) {
        beatRequests.append(BeatRequest(kind, priority: priority, owner: owner, at: now))
    }

    // MARK: Read-only views of this step's requests

    /// The signature slot of the winning reaction request this step, if any.
    public var reaction: Signature.Slot? {
        for r in mannerismRequests.reversed() { if case .signature(let s) = r.what { return s } }
        return nil
    }

    /// The last backchannel mannerism requested this step, if any.
    public var backchannel: Mannerism? {
        for r in mannerismRequests.reversed() where r.rank == .backchannel { if case .mannerism(let m) = r.what { return m } }
        return nil
    }

    /// 0…1: the highest uncertainty requested this step.
    public var uncertainty: Double { uncertaintyRequests.map(\.value).max() ?? 0 }
}

extension Moment {
    /// Raises a signal from `owner` (a reducer's `name`) in the current step.
    public mutating func signal(_ name: String, subject: Subject? = nil, value: Double = 0, id: UUID? = nil,
                                label: String? = nil, by owner: String) {
        momentary.signals.append(Signal(name, subject: subject, value: value, id: id, label: label, owner: owner, seq: seq))
    }

    /// The signals `reader` has not seen yet (see `Signal`): raised this step by a reducer
    /// earlier in the pipeline, or last step by `reader` itself or a later one. Signals
    /// raised by Cortex (or anything not in the pipeline) count as earlier than every reducer.
    public func inbox(for reader: String) -> [Signal] {
        let me = Cortex.pipeline.firstIndex(of: reader) ?? Cortex.pipeline.count
        return momentary.signals.filter { s in
            let i = Cortex.pipeline.firstIndex(of: s.owner) ?? -1
            return (s.seq == seq && i < me) || (s.seq &+ 1 == seq && i >= me)
        }
    }
}

extension Ongoing {
    /// Raises a note candidate. The raiser has already applied its own gates
    /// (confidence, playGate, thresholds); NotePicker only arbitrates (§6.3).
    public mutating func raise(_ note: Note, by owner: String) {
        var n = note
        n.owner = owner
        noteCandidates.append(n)
    }
}
