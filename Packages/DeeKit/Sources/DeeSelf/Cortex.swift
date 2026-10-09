import DeeCore
import DeeMind
import Foundation

/// One sub-reducer of the fixed Cortex pipeline (SELF.md §4.2). Each lives in its own
/// file under `Reducers/`, owns the `Moment` fields listed in its header, and has its
/// own test file and golden traces. Adding behaviour to one never touches Cortex,
/// Stance, CueWriter, Notes or Basics: it talks to the rest only through the request
/// channels, note candidates and signals (Requests.swift) and the hooks below.
/// See docs/contracts-0.5/self.md, "Reducer author guide".
public protocol SubReducer: Sendable {
    /// Short stable name ("FloorKeeper"); also its RNG stream key and golden-fixture folder.
    static var name: String { get }
    /// Every percept, in pipeline order. `rng` is this reducer's own stream.
    mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect]
    /// The slice of `Moment` this reducer owns, as stable strings for golden traces.
    static func slice(of m: Moment) -> [String: String]

    /// Once, from `Cortex.init`: take your part of the persisted carried state.
    mutating func seed(from carried: Carried, _ m: inout Moment)
    /// After every reducer has reduced `.conversationStarted(d)` (so `reduce` can still
    /// close the old conversation): reset your conversation-scoped fields.
    mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect]
    /// A note NotePicker just issued (every reducer sees every issued note; act on the
    /// ones you own: `n.owner == Self.name` or a linked id you hold). Persist your
    /// bookkeeping here (issued counts, reveal times, recall and gag uses).
    mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect]
    /// Write anything you hold back (throttled profile writes…). Called by `Cortex.flush`.
    mutating func flush(_ m: inout Moment) -> [Effect]
    /// Privacy: drop private state about `subject` (Cortex already scrubbed shared fields).
    mutating func forget(subject: Subject, _ m: inout Moment)
    /// Privacy: drop private state about one person.
    mutating func forgetPerson(_ id: PersonID, _ m: inout Moment)
    /// DeeMemory folded `from` into `into`: re-point private state.
    mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment)
    /// Privacy: drop everything learnt that you hold privately.
    mutating func forgetAll(_ m: inout Moment)
    /// Pre-commit appraisal adjustment (e.g. a `tookLiterally` lesson softening
    /// hostility), run by `Cortex.adjust(_:)` before the app hands the appraisal to Mind.
    func adjust(_ a: inout Appraisal, _ m: Moment)
}

extension SubReducer {
    public static func slice(of m: Moment) -> [String: String] { [:] }
    public mutating func seed(from carried: Carried, _ m: inout Moment) {}
    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] { [] }
    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] { [] }
    public mutating func flush(_ m: inout Moment) -> [Effect] { [] }
    public mutating func forget(subject: Subject, _ m: inout Moment) {}
    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {}
    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {}
    public mutating func forgetAll(_ m: inout Moment) {}
    public func adjust(_ a: inout Appraisal, _ m: Moment) {}
}

/// Persisted ongoing state handed to a new Cortex (from `SelfStore.loadCarried`).
/// Each reducer takes its own part in `seed(from:_:)`.
public struct Carried: Sendable, Equatable {
    /// IntentionBoard.
    public var intentions: [Intention]
    /// IntentionBoard (status) / Interpreter (checks).
    public var expectations: [Expectation]
    /// Learner.
    public var interests: [Interest]
    /// RepairKeeper: an open rupture that survives a relaunch (§7.8), per person.
    public var openRepair: [PersonID: RepairPhase]
    /// Learner: misreads of the last 14 days (lesson minting, skill intentions).
    public var misreads: [Misread]

    public init(intentions: [Intention] = [], expectations: [Expectation] = [], interests: [Interest] = [],
                openRepair: [PersonID: RepairPhase] = [:], misreads: [Misread] = []) {
        self.intentions = intentions
        self.expectations = expectations
        self.interests = interests
        self.openRepair = openRepair
        self.misreads = misreads
    }
}

/// SELF.md §4.2 — the pure reducer. A value type owned by the @MainActor DeeModel:
/// `step` is synchronous, never awaits, never reads the clock and draws randomness
/// only from its seeded streams, so a percept timeline replays bit-identically.
public struct Cortex: Sendable {
    public internal(set) var moment: Moment
    public private(set) var stance: Stance
    /// One seeded stream per sub-reducer (pipeline order), so one reducer's extra draw
    /// never shifts another's: `Rand(seed: base ^ StableHash.of(name))`.
    public private(set) var streams: [Rand]
    /// `Stance.resolve`'s own stream (signature picks).
    public private(set) var stanceRNG: Rand
    /// NotePicker's own stream (wording variants).
    public private(set) var pickerRNG: Rand
    /// Highest `MindSnapshot.sequence` accepted; older snapshots are ignored.
    public private(set) var mindSequence: UInt64 = 0
    /// `MindSnapshot.reflexAt` of the last reflex started.
    public private(set) var lastReflexAt: Date?
    /// The enduring self as it was after the last `.conversationStarted` step (or init):
    /// `selfLines` renders from it, so the system prompt is frozen per conversation.
    public private(set) var frozenEnduring: Enduring
    public private(set) var picker = NotePicker()
    /// Effects of a `cueText(at:)` call, returned (first) by the next `step`.
    public private(set) var queuedEffects: [Effect] = []
    /// Budget and counter for cues Cortex builds itself (initiative) and the default for
    /// `cue(at:)`. The app sets the real tokenizer here (`SelfBudget`).
    public var cueBudget = CueWriter.maxTokens
    public var tokenCounter: @Sendable (String) -> Int = CueWriter.estimateTokens

    // The fixed pipeline (order is part of the contract; see §4.2).
    public private(set) var floorKeeper = FloorKeeper()
    public private(set) var listener = Listener()
    public private(set) var attention = Attention()
    public private(set) var interpreter = Interpreter()
    public private(set) var repairKeeper = RepairKeeper()
    public private(set) var intentionBoard = IntentionBoard()
    public private(set) var beats = Beats()
    public private(set) var episodeBuilder = EpisodeBuilder()
    public private(set) var learner = Learner()

    /// Names in pipeline order.
    public static let pipeline = [FloorKeeper.name, Listener.name, Attention.name, Interpreter.name, RepairKeeper.name,
                                  IntentionBoard.name, Beats.name, EpisodeBuilder.name, Learner.name]
    /// The `owner` of requests and signals Cortex itself raises (reflex reactions).
    public static let owner = "Cortex"

    /// The base of every stream: the enduring seed mixed with a per-launch session
    /// counter (`SelfStore.nextSession()`), so each launch is a different sequence.
    public static func baseSeed(_ enduringSeed: UInt64, session: UInt64) -> UInt64 {
        enduringSeed ^ 0xC0_87_E7_00_5E_1F_00_01 ^ (session &* 0x9E37_79B9_7F4A_7C15)
    }

    /// The stream a component named `name` draws from.
    public static func stream(_ name: String, base: UInt64) -> Rand { Rand(seed: base ^ StableHash.of(name)) }

    public init(enduring: Enduring, mind: MindSnapshot, at now: Date, carried: Carried = Carried(), session: UInt64 = 0) {
        let base = Self.baseSeed(enduring.seed, session: session)
        moment = Moment(ongoing: Ongoing(mind: mind, conversationStarted: now), enduring: enduring, now: now)
        streams = Self.pipeline.map { Self.stream($0, base: base) }
        stanceRNG = Self.stream("Stance", base: base)
        pickerRNG = Self.stream("NotePicker", base: base)
        frozenEnduring = enduring
        mindSequence = mind.sequence
        lastReflexAt = mind.reflexAt
        stance = Stance()
        _ = visit { r, m, _ in
            r.seed(from: carried, &m)
            return []
        }
        stance = Stance.resolve(moment, &stanceRNG)
    }

    /// Pure and synchronous. `mind` must be the newest snapshot (by `sequence`); older
    /// ones are ignored. Order of sub-reducers is fixed. Effects come back in order:
    /// queued `cueText` effects, the reducers' effects, then initiative.
    public mutating func step(_ p: Percept, mind: MindSnapshot, at now: Date) -> [Effect] {
        var effects = queuedEffects
        queuedEffects = []
        ingest(mind, at: now)
        if case .conversationStarted = p { moment.ongoing.noteCandidates = [] }

        var m = moment
        effects += floorKeeper.reduce(p, &m, &streams[0])
        effects += listener.reduce(p, &m, &streams[1])
        effects += attention.reduce(p, &m, &streams[2])
        effects += interpreter.reduce(p, &m, &streams[3])
        effects += repairKeeper.reduce(p, &m, &streams[4])
        effects += intentionBoard.reduce(p, &m, &streams[5])
        effects += beats.reduce(p, &m, &streams[6])
        effects += episodeBuilder.reduce(p, &m, &streams[7])
        effects += learner.reduce(p, &m, &streams[8])
        moment = m

        if case .conversationStarted(let d) = p {
            moment.ongoing.conversationStarted = d
            moment.ongoing.promptRendered = false
            effects += visit { r, m, rng in r.conversationStarted(at: d, &m, &rng) }
            // Frozen after the pipeline, so what reducers loaded or learnt on this step
            // reaches this conversation's prompt.
            frozenEnduring = moment.enduring
        }

        let resolved = Stance.resolveDetailed(moment, &stanceRNG)
        stance = resolved.stance
        if resolved.signature, let man = stance.mannerism {
            moment.momentary.recentMannerisms = Array((moment.momentary.recentMannerisms + [man]).suffix(2))
        }

        effects += takeInitiative()
        return effects
    }

    /// Turns this step's best `InitiativeRequest` into `.initiative(cue:)` (plus the
    /// issued notes' bookkeeping). Generic part only: the floor is idle and the aim
    /// still passes NotePicker's generic rules; the requester applied its thresholds.
    mutating func takeInitiative() -> [Effect] {
        guard let req = moment.momentary.initiative, case .idle = moment.momentary.floor,
              req.aim.map({ picker.eligible($0, moment: moment) }) ?? true else { return [] }
        moment.momentary.initiative = nil
        let built = issue(aim: req.aim, budget: cueBudget, count: tokenCounter)
        return [.initiative(cue: built.cue)] + built.effects
    }

    /// Builds the `<dee_state>` for the next LLM turn: NotePicker arbitrates the note
    /// candidates, each issued note goes to every reducer's `noteIssued` (whose
    /// bookkeeping comes back as `effects` — execute them like `step`'s), and the
    /// candidates are cleared. `budget`/`count` default to `cueBudget`/`tokenCounter`.
    public mutating func cue(at now: Date, budget: Int? = nil,
                             count: (@Sendable (String) -> Int)? = nil) -> (cue: String, effects: [Effect]) {
        moment.now = max(moment.now, now)
        return issue(aim: nil, budget: budget ?? cueBudget, count: count ?? tokenCounter)
    }

    /// Convenience: the cue text only. Its effects are queued and returned first by
    /// the next `step`, so nothing is lost.
    public mutating func cueText(at now: Date, budget: Int? = nil, count: (@Sendable (String) -> Int)? = nil) -> String {
        let r = cue(at: now, budget: budget, count: count)
        queuedEffects += r.effects
        return r.cue
    }

    mutating func issue(aim: Note?, budget: Int, count: @Sendable (String) -> Int) -> (cue: String, effects: [Effect]) {
        let mood = CueWriter.mood(moment.ongoing.mind)
        var candidates = moment.ongoing.noteCandidates
        if let aim { candidates.append(aim) }
        let notes = picker.pick(candidates, moment: moment, mood: mood, rng: &pickerRNG, budget: budget, count: count)
        moment.ongoing.noteCandidates = []
        var effects: [Effect] = []
        for n in notes {
            effects += visit { r, m, _ in r.noteIssued(n, &m) }
        }
        stance.notes = notes
        return (CueWriter.cue(mood: mood, notes: notes), effects)
    }

    /// The self block for `Persona.selfLines`, rendered from the enduring self frozen
    /// at the last `.conversationStarted`: identical on every call in a conversation.
    public func selfLines(person: PersonID?, at now: Date) -> [String] {
        SelfBlock.render(frozenEnduring, person: person)
    }

    /// The fixed rule lines for `Persona.ruleLines`.
    public static let ruleLines = SelfBlock.ruleLines

    /// `base` with `selfLines` and `ruleLines` set — call once per conversation, after
    /// `.conversationStarted`. Records who the prompt was rendered for
    /// (`Ongoing.promptPerson`), so a person identified later still gets their
    /// boundaries as context notes (RepairKeeper).
    public mutating func persona(_ base: Persona, person: PersonID?, at now: Date) -> Persona {
        moment.ongoing.promptPerson = person
        moment.ongoing.promptRendered = true
        var p = base
        p.selfLines = selfLines(person: person, at: now)
        p.ruleLines = Self.ruleLines
        return p
    }

    /// The reconciled tag of the current sentence: what the transcript shows.
    public var reconciledTag: Emotion? { moment.momentary.llmTag?.live(at: moment.now) }

    /// Replaces the enduring self. Cortex's own `moment.enduring` is the authority while
    /// it runs (every learnt change flows through it and out as `.persist`), so the app
    /// never needs to reload at `newConversation`. Only for an external edit: call
    /// `flush(at:)` and apply all pending writes first. Takes effect for `selfLines` at
    /// the next `.conversationStarted`.
    public mutating func setEnduring(_ e: Enduring) { moment.enduring = e }

    /// Writes reducers hold back (e.g. throttled profiles). Call on background, sleep,
    /// and before `setEnduring`.
    public mutating func flush(at now: Date) -> [Effect] {
        moment.now = max(moment.now, now)
        return visit { r, m, _ in r.flush(&m) }
    }

    /// Runs every reducer's `adjust` over an appraisal before the app commits it to Mind.
    public func adjust(_ appraisal: Appraisal) -> Appraisal {
        var a = appraisal
        floorKeeper.adjust(&a, moment)
        listener.adjust(&a, moment)
        attention.adjust(&a, moment)
        interpreter.adjust(&a, moment)
        repairKeeper.adjust(&a, moment)
        intentionBoard.adjust(&a, moment)
        beats.adjust(&a, moment)
        episodeBuilder.adjust(&a, moment)
        learner.adjust(&a, moment)
        return a
    }

    // MARK: - Privacy and people (call BEFORE the matching SelfStore call; see the contract)

    /// "Forget that": drops `subject` from RAM so nothing re-persists it.
    public mutating func forget(subject: Subject) {
        moment.forget(subject: subject)
        _ = visit { r, m, _ in
            r.forget(subject: subject, &m)
            return []
        }
    }

    /// Drops episode keys `SelfStore.forget(subject:)` deleted by gist.
    public mutating func forget(episodes ids: [UUID]) { moment.forget(episodes: ids) }

    /// Forget one person (DeeMemory `forgetPerson` / `discardPlaceholder`).
    public mutating func forgetPerson(_ id: PersonID) {
        moment.forget(person: id)
        _ = visit { r, m, _ in
            r.forgetPerson(id, &m)
            return []
        }
        frozenEnduring = moment.enduring
    }

    /// DeeMemory merged `from` into `into`.
    public mutating func merge(from: PersonID, into: PersonID) {
        guard from != into else { return }
        moment.merge(from: from, into: into)
        _ = visit { r, m, _ in
            r.merge(from: from, into: into, &m)
            return []
        }
        frozenEnduring = moment.enduring
    }

    /// Forget everything learnt; keeps the seeded self (`Enduring.keepingSeeded()`
    /// unless the reloaded one is passed).
    public mutating func forgetAll(keepingSeeded seeded: Enduring? = nil) {
        moment.forgetAll(keepingSeeded: seeded)
        _ = visit { r, m, _ in
            r.forgetAll(&m)
            return []
        }
        picker = NotePicker()
        queuedEffects.removeAll { if case .persist = $0 { true } else { false } }
        frozenEnduring = moment.enduring
    }

    // MARK: - Internals

    /// Runs `body` on every reducer in pipeline order with its own stream.
    mutating func visit(_ body: (inout any SubReducer, inout Moment, inout Rand) -> [Effect]) -> [Effect] {
        var m = moment
        var rs = streams
        var effects: [Effect] = []
        func go<R: SubReducer>(_ r: R, _ i: Int) -> R {
            var e: any SubReducer = r
            effects += body(&e, &m, &rs[i])
            return e as! R
        }
        floorKeeper = go(floorKeeper, 0)
        listener = go(listener, 1)
        attention = go(attention, 2)
        interpreter = go(interpreter, 3)
        repairKeeper = go(repairKeeper, 4)
        intentionBoard = go(intentionBoard, 5)
        beats = go(beats, 6)
        episodeBuilder = go(episodeBuilder, 7)
        learner = go(learner, 8)
        moment = m
        streams = rs
        return effects
    }

    /// Accepts the newest snapshot, advances the clock, clears per-step channels and
    /// tracks the reflex (`MindSnapshot.reflex`, live 4 s from its stimulus).
    mutating func ingest(_ mind: MindSnapshot, at now: Date) {
        moment.seq &+= 1
        if now > moment.now { moment.now = now }
        moment.momentary.beginStep(seq: moment.seq)
        guard mind.sequence >= mindSequence else { return }
        let previousReflex = moment.ongoing.mind.reflex
        mindSequence = mind.sequence
        moment.ongoing.mind = mind
        guard let r = mind.reflex else {
            moment.momentary.reflex = nil
            return
        }
        let fresh: Bool
        if let at = mind.reflexAt {
            // Stamped: a new stimulus, even of the same emotion, restarts the 4 s.
            fresh = at != lastReflexAt
        } else {
            // Unstamped (snapshots built directly): a reflex an older snapshot already
            // carried does not restart.
            fresh = (r != previousReflex || moment.momentary.reflex == nil) && moment.momentary.reflex?.live(at: moment.now) != r
        }
        guard fresh else { return }
        lastReflexAt = mind.reflexAt
        let start = mind.reflexAt.map { min($0, moment.now) } ?? moment.now
        moment.momentary.reflex = Timed(r, until: start.addingTimeInterval(Mind.reflexDuration))
        if let slot = Self.reactionSlot(for: r) { moment.momentary.requestReaction(slot, by: Self.owner) }
    }

    /// A fresh reflex asks for a signature reaction of the matching slot.
    static func reactionSlot(for e: Emotion) -> Signature.Slot? {
        switch e {
        case .giddy, .joy, .playful, .mischievous: .amused
        case .love, .shy, .relieved, .content: .fond
        case .skeptical, .confused, .unimpressed: .doubtful
        case .curious: .thinking
        default: nil
        }
    }
}
