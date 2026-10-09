import DeeCore
import DeeMind
import Foundation

/// Sub-reducer 5 — relationship repair and boundaries (SELF.md §7.8, step 0.5.5).
///
/// Owns: `ongoing.repair`, `ongoing.awkwardness`, `enduring.boundaries`.
/// Reads: the heard appraisal and text (RAM only), the mood snapshot (anger, resentment,
/// regard, assertiveness), `ongoing.misreadThisTurn`, floor events, touches, gestures,
/// laughter sounds, Dee's sentence tags, `ongoing.person` / `promptPerson`.
///
/// **Awkwardness** (0…1, half-life 3 min): Dee interrupted +0.2, a misread +0.25, an
/// awkward silence +0.15 (Listener's signal), a failed joke +0.2 (a joke — ≥ 2 playful
/// sentences: playful / mischievous / giddy — answered clearly negative, hostile or
/// dismissive, or "not funny" after any playful sentence; a neutral reply is no evidence).
/// `fine → strained` at ≥ 0.5, `strained → fine` below 0.2 with a one-time self-repair
/// note when Dee caused it (misread, failed joke, or an interruption she has not already
/// apologised for: Beats' `"sorrySaid"` clears that cause).
///
/// **Rupture** (`* → ruptured`) only on a user-caused step (heard, touch, gesture): a
/// hostile utterance (hostility or threat ≥ 0.5), anger rising past 0.5 on that step, or
/// regard ≥ 0.4 below its 10-minute high. Hostility is Interpreter's `"hostility"` signal
/// (softened after a tookLiterally lesson) when present. A mood that was already cross before the user
/// did anything is not a rupture, and nothing ever ruptures on a tick or with time:
/// absence is not a quarrel. `ruptured → repairing` on a reconciliation bid (apology,
/// gentle pet or hold, shared laughter, thumbs-up, "are we ok", "friends?", "I didn't mean
/// it"); `repairing → reconciled` on a calm mood (resentment < 0.2, anger < 0.1) at a
/// later user step, or a second bid. Laughter is a bid (and a social step) only within
/// 15 s of Dee speaking (not a laughing TV). After 10 min of together time with anger
/// < 0.1 and resentment < 0.2 a rupture ends silently (`→ fine`, no note: a false alarm
/// must not mute her for days). Reconciled raises the reconciled note (issued at
/// most once) and a `contentSquint`, deactivates Dee's own boundary (no sulking), and
/// returns to fine after 2 min (or at the next conversation). A repair under way
/// (`repairing`: they already made a bid) ends silently with its conversation, also when
/// carried across a relaunch, so the reconciled note never surfaces days later.
///
/// **Dee's boundary**: a second hostile utterance within 10 min while ruptured, with
/// effective assertiveness ≥ 0.35, at most once per rupture and once per 10 min: the
/// boundary note, a `Boundary(owner: .dee)` (persisted when the person is known) and a
/// "deeBoundary" signal for EpisodeBuilder.
///
/// **User boundaries**: "don't ask me about X", "I don't want to talk about X", "stop
/// asking about X" (and a few close variants; "it" → the current topic) create or
/// reactivate a `Boundary(owner: .user)` → `.persist(.boundary)`, a "userBoundary" signal
/// (IntentionBoard drops matching subjects), that turn's context note, `avoid` (the
/// CuriosityDirector avoid list, read by the app) and, through `enduring.boundaries`, the
/// self block's "Don't bring up" line from the next conversation. "You can ask me about X
/// again" lifts it. An unidentified speaker's boundaries live in RAM for the session and
/// are stored for them once they are identified. When the frozen prompt lacks the
/// identified person's line, each of their turns raises it as a context note
/// (review finding 10).
///
/// **Open rupture across relaunches**: a ruptured / repairing phase with a known person
/// is persisted (`.openRepair`, together-seconds left) and restored when that person is
/// identified, for up to 6 h of *together* time (seconds with recent contact, never wall
/// time); after that it ends silently. Switching to another person parks it for its owner.
///
/// Pronoun boundaries ("… about it") come only from Interpreter's signal; our own reading
/// takes explicit subjects, so the two never disagree.
///
/// Signals raised: "repairPhase" (label = new phase), "deeBoundary" (id = boundary),
/// "userBoundary" / "userBoundaryLifted" (subject), "jokeFlopped" (for Learner).
/// Signals read (from Interpreter / Listener / Learner, deduplicated against its own
/// detection): "reconciliationBid", "userBoundary" / "userBoundaryLifted" (subject),
/// "misread" (id), "awkwardSilence", "laughter", "hostility" (Interpreter), "sorrySaid" (Beats).
public struct RepairKeeper: SubReducer {
    public static let name = "RepairKeeper"

    // MARK: Constants (§7.8)

    public static let awkwardHalfLife: TimeInterval = 180
    public static let strainAt = 0.5
    public static let easeBelow = 0.2
    public static let interruptAwkwardness = 0.2
    public static let misreadAwkwardness = 0.25
    public static let silenceAwkwardness = 0.15
    public static let failedJokeAwkwardness = 0.2
    /// A heard reply this long after a playful sentence still judges the joke.
    public static let jokeWindow: TimeInterval = 60
    /// Playful sentences in one reply that make it a joke (review finding 2).
    public static let jokeSentences = 2
    /// Laughter is a reconciliation bid (and a social step) only this soon after Dee spoke:
    /// a laughing TV is not making up with her (review finding 13).
    public static let laughBidWindow: TimeInterval = 15
    /// A rupture eases silently (no "made up" note) after this much together time with
    /// her anger and resentment calm (review finding 13).
    public static let calmExit: TimeInterval = 600

    public static let hostileAt = 0.5
    public static let angerRupture = 0.5
    public static let regardDrop = 0.4
    public static let regardWindow: TimeInterval = 600
    public static let calmResentment = 0.2
    public static let calmAnger = 0.1
    public static let bidsToReconcile = 2
    public static let reconciledHold: TimeInterval = 120

    public static let deeBoundaryWindow: TimeInterval = 600
    public static let deeBoundaryAssertiveness = 0.35
    /// The topic stored on Dee's own boundary.
    public static let deeBoundaryTopic = Subject("how i'm spoken to")!

    /// An open rupture lasts at most this much together time (also across relaunches).
    public static let openTogether: TimeInterval = 6 * 3600
    /// Contact within this long counts as being together.
    public static let togetherGrace: TimeInterval = 60
    /// At most this much together time is credited per step (no jumps over gaps).
    public static let maxStepCredit: TimeInterval = 30
    /// The together-seconds left are re-persisted after this much is used.
    public static let persistEvery: TimeInterval = 300

    /// How long an unissued note of ours is re-raised after a cue passed it over.
    static let awkwardNoteLife: TimeInterval = 300
    static let reconciledNoteLife: TimeInterval = 600
    static let deeBoundaryNoteLife: TimeInterval = 600

    // MARK: State (RAM)

    /// Open ruptures not currently active: loaded from the store (applied when the person
    /// is identified) or parked when another person took over.
    public internal(set) var carried: [PersonID: RepairPhase] = [:]
    /// Together-seconds left for `carried` entries parked this session (loaded ones get
    /// the full window: `Carried` has no seconds; see the 0.5.5 shared-change request).
    public internal(set) var carriedLeft: [PersonID: Double] = [:]
    /// The CuriosityDirector avoid list for the current speaker: their active user
    /// boundaries plus this session's unattributed ones. The app copies it into
    /// `CuriosityDirector.avoid` after each step (`cortex.repairKeeper.avoid`).
    public private(set) var avoid: Set<String> = []
    /// Whose rupture the current open phase is (nil while the speaker is unknown).
    public private(set) var ruptureOwner: PersonID?
    /// Together-seconds left for the current open phase.
    public private(set) var togetherLeft: Double = RepairKeeper.openTogether
    /// Reconciliation bids since the rupture.
    public private(set) var bids = 0
    /// Boundaries set by a speaker not yet identified (RAM; stored once identified).
    public private(set) var sessionBoundaries: [Subject] = []

    var lastUpdate: Date?
    var lastContact: Date?
    var lastPerson: PersonID?
    var deeCausedStrain = false
    /// Strain from Dee interrupting; cleared when Beats already said sorry for it
    /// (`"sorrySaid"`), so it never earns a second apology (review finding 14).
    var interruptStrain = false
    var playfulSentences = 0
    /// Any playful sentence (an explicit "not funny" judges even a one-liner).
    var anyPlayfulAt: Date?
    var lastDeeSpoke: Date?
    /// Together-seconds of calm while ruptured (the silent exit).
    var calmTogether: Double = 0
    var phaseSince: Date?
    var hostileTimes: [Date] = []
    var lastDeeBoundaryAt: Date?
    var deeBoundaryThisRupture = false
    var regardSamples: [RegardSample] = []
    var lastAnger: Double?
    var seenMisreads: [UUID] = []
    var playfulAt: Date?
    var pending: [PendingNote] = []
    var persistedLeft: Double = RepairKeeper.openTogether
    /// Carried phases from an earlier conversation (or launch). A `.repairing` one — they
    /// already apologised — ends silently when its person is back: "they made up with
    /// you" three days later is stale (live transcript, Fri cue).
    var carriedFromEarlier: Set<PersonID> = []

    struct RegardSample: Sendable, Equatable {
        var at: Date
        var regard: Double
    }

    struct PendingNote: Sendable, Equatable {
        var kind: Note.Kind
        var until: Date
    }

    public init() {}

    // MARK: - reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var effects: [Effect] = []
        let phaseAtStart = m.ongoing.repair
        let dt = lastUpdate.map { max(0, now.timeIntervalSince($0)) } ?? 0
        if dt > 0 { m.ongoing.awkwardness *= halfLife(dt, Self.awkwardHalfLife) }
        lastUpdate = now

        noteContact(p, now: now)
        let isTogether = together(at: now)
        if Self.isOpen(m.ongoing.repair), isTogether { togetherLeft -= min(dt, Self.maxStepCredit) }
        switch p {
        case .deeSaid, .speakingFinished, .deeTurnFinished: lastDeeSpoke = now
        case .promptSubmitted: playfulSentences = 0
        default: break
        }

        followPerson(&m, &effects, &rng)
        // Our own signals come back next step: never read them as input.
        let inbox = m.inbox(for: Self.name).filter { $0.owner != Self.name }

        // Awkwardness.
        if m.momentary.floorEvents.contains(.deeInterrupted) {
            m.ongoing.awkwardness = clamp01(m.ongoing.awkwardness + Self.interruptAwkwardness)
            interruptStrain = true
        }
        if inbox.contains(where: { $0.name == "sorrySaid" }) { interruptStrain = false }
        var misreads: [UUID] = []
        if let mr = m.ongoing.misreadThisTurn { misreads.append(mr.id) }
        for s in inbox where s.name == "misread" { if let id = s.id { misreads.append(id) } }
        for id in misreads where !seenMisreads.contains(id) {
            seenMisreads = Array((seenMisreads + [id]).suffix(16))
            addAwkwardness(Self.misreadAwkwardness, deeCaused: true, &m)
        }
        for s in inbox where s.name == "awkwardSilence" { addAwkwardness(Self.silenceAwkwardness, deeCaused: false, &m) }

        let laughedNow = inbox.contains { Self.isSignal($0, "laughter") } || Self.isLaughter(p)
        // Laughter answers Dee only shortly after she spoke (not a laughing TV).
        let laughed = laughedNow && (lastDeeSpoke.map { now.timeIntervalSince($0) <= Self.laughBidWindow } ?? false)
        if laughed { playfulAt = nil; anyPlayfulAt = nil }
        if let at = playfulAt, now.timeIntervalSince(at) > Self.jokeWindow { playfulAt = nil }
        if let at = anyPlayfulAt, now.timeIntervalSince(at) > Self.jokeWindow { anyPlayfulAt = nil }
        if case .deeSaid(let raw, _) = p, let tag = m.momentary.llmTag?.live(at: now) ?? raw, Self.playfulTags.contains(tag) {
            playfulSentences += 1
            anyPlayfulAt = now
            if playfulSentences >= Self.jokeSentences { playfulAt = now }
        }

        // The user-caused part: rupture, bids, Dee's boundary, user boundaries.
        let social = Self.isSocial(p) || laughed
        var hostile = false
        if case .heard(let text, _, _, let a) = p {
            // Interpreter's hostility, softened after a tookLiterally lesson, wins over the raw one.
            let hostility = inbox.last { $0.name == "hostility" && $0.owner == Interpreter.name }?.value ?? a.hostility
            hostile = hostility >= Self.hostileAt || a.threat >= Self.hostileAt
            if playfulAt != nil || (anyPlayfulAt != nil && Self.saysNotFunny(text)) {
                if Self.jokeFlopped(text: text, appraisal: a) {
                    addAwkwardness(Self.failedJokeAwkwardness, deeCaused: true, &m)
                    m.signal("jokeFlopped", by: Self.name)
                }
                playfulAt = nil
            }
            anyPlayfulAt = nil
        }
        if social { evaluateRelationship(p, hostile: hostile, laughed: laughed, inbox: inbox, phaseAtStart: phaseAtStart, &m, &effects, &rng) }

        if case .heard(let text, _, _, _) = p {
            let changed = userBoundaries(text: text, inbox: inbox, &m, &effects, &rng)
            raiseBoundaryNote(new: changed, &m)
        } else {
            let changed = userBoundaries(text: nil, inbox: inbox, &m, &effects, &rng)
            if !changed.isEmpty { raiseBoundaryNote(new: changed, &m) }
        }

        // Time-driven transitions (never into a rupture).
        switch m.ongoing.repair {
        case .reconciled where now.timeIntervalSince(phaseSince ?? now) >= Self.reconciledHold:
            setPhase(.fine, &m, &effects)
        case .ruptured, .repairing:
            let calm = m.ongoing.feeling(.resentment) < Self.calmResentment && m.ongoing.feeling(.anger) < Self.calmAnger
            if m.ongoing.repair == .ruptured, calm, isTogether { calmTogether += min(dt, Self.maxStepCredit) } else if !calm { calmTogether = 0 }
            if togetherLeft <= 0 || (m.ongoing.repair == .ruptured && calmTogether >= Self.calmExit) {
                // Ends silently: no reconciled note, no "made up" (nothing was said).
                setPhase(.fine, &m, &effects)
            } else if let owner = ruptureOwner, persistedLeft - togetherLeft >= Self.persistEvery {
                persistedLeft = togetherLeft
                effects.append(.persist(.openRepair(owner, m.ongoing.repair, togetherSecondsLeft: max(0, togetherLeft))))
            }
        default:
            break
        }
        switch m.ongoing.repair {
        case .fine where m.ongoing.awkwardness >= Self.strainAt:
            setPhase(.strained, &m, &effects)
        case .strained where m.ongoing.awkwardness < Self.easeBelow:
            setPhase(.fine, &m, &effects)
            if deeCausedStrain || interruptStrain { addPending(.awkwardRepair, life: Self.awkwardNoteLife, now: now) }
            deeCausedStrain = false
            interruptStrain = false
        default:
            break
        }

        raisePending(&m)
        sampleRegard(m, social: social)
        lastAnger = m.ongoing.feeling(.anger)
        avoid = Self.avoidTopics(m.enduring, person: m.ongoing.person, session: sessionBoundaries)
        return effects
    }

    // MARK: Relationship

    mutating func evaluateRelationship(_ p: Percept, hostile: Bool, laughed: Bool, inbox: [Signal], phaseAtStart: RepairPhase,
                                       _ m: inout Moment, _ effects: inout [Effect], _ rng: inout Rand) {
        let now = m.now
        let anger = m.ongoing.feeling(.anger)
        hostileTimes.removeAll { now.timeIntervalSince($0) > Self.deeBoundaryWindow }

        if hostile {
            let assertiveness = m.ongoing.effectivePersonality[.assertiveness]
            let cooled = lastDeeBoundaryAt.map { now.timeIntervalSince($0) >= Self.deeBoundaryWindow } ?? true
            if phaseAtStart == .ruptured, !hostileTimes.isEmpty, assertiveness >= Self.deeBoundaryAssertiveness, cooled,
               !deeBoundaryThisRupture {
                stateDeeBoundary(&m, &effects, &rng)
            }
            hostileTimes.append(now)
        }

        let angerRose = anger > Self.angerRupture && (lastAnger.map { anger > $0 } ?? false)
        let peak = regardSamples.filter { now.timeIntervalSince($0.at) <= Self.regardWindow }.map(\.regard).max()
        let regardFell = peak.map { $0 - m.ongoing.mind.regard >= Self.regardDrop } ?? false
        if hostile || angerRose || regardFell {
            // A fresh offence restarts the together-time window; the regard high is
            // forgotten so one drop ruptures once, not on every step of the next 10 min.
            regardSamples = []
            togetherLeft = Self.openTogether
            persistedLeft = togetherLeft
            bids = 0
            if m.ongoing.repair != .ruptured { setPhase(.ruptured, &m, &effects) }
            return
        }

        let bid = Self.isBid(p, laughed: laughed) || inbox.contains { Self.isSignal($0, "reconciliationBid") && $0.owner == Interpreter.name }
        switch phaseAtStart {
        case .ruptured where bid:
            bids += 1
            setPhase(.repairing, &m, &effects)
        case .repairing:
            if bid { bids += 1 }
            let calm = m.ongoing.feeling(.resentment) < Self.calmResentment && anger < Self.calmAnger
            if bids >= Self.bidsToReconcile || calm { reconcile(&m, &effects) }
        default:
            break
        }
    }

    mutating func reconcile(_ m: inout Moment, _ effects: inout [Effect]) {
        let owner = ruptureOwner ?? m.ongoing.person
        setPhase(.reconciled, &m, &effects)
        m.momentary.requestMannerism(.contentSquint, rank: .reaction, by: Self.name)
        pending.removeAll { $0.kind == .deeBoundary }
        addPending(.reconciled, life: Self.reconciledNoteLife, now: m.now)
        // No sulking: Dee's own boundary is not raised again after making up.
        if let owner {
            for i in m.enduring.boundaries.indices
            where m.enduring.boundaries[i].person == owner && m.enduring.boundaries[i].owner == .dee && m.enduring.boundaries[i].active {
                m.enduring.boundaries[i].active = false
                effects.append(.persist(.boundary(m.enduring.boundaries[i])))
            }
        }
    }

    mutating func stateDeeBoundary(_ m: inout Moment, _ effects: inout [Effect], _ rng: inout Rand) {
        deeBoundaryThisRupture = true
        lastDeeBoundaryAt = m.now
        addPending(.deeBoundary, life: Self.deeBoundaryNoteLife, now: m.now)
        var id: UUID?
        if let person = m.ongoing.person {
            let b = upsertBoundary(person: person, topic: Self.deeBoundaryTopic, owner: .dee, &m, &rng)
            effects.append(.persist(.boundary(b)))
            id = b.id
        }
        m.signal("deeBoundary", id: id, by: Self.name)
    }

    /// Moves the phase, keeping the open-repair row and the signal in step.
    mutating func setPhase(_ new: RepairPhase, _ m: inout Moment, _ effects: inout [Effect]) {
        let old = m.ongoing.repair
        guard new != old else { return }
        m.ongoing.repair = new
        phaseSince = m.now
        m.signal("repairPhase", label: new.rawValue, by: Self.name)
        if new == .ruptured { calmTogether = 0 }
        if new == .ruptured, !Self.isOpen(old) {
            ruptureOwner = m.ongoing.person
            togetherLeft = Self.openTogether
            persistedLeft = togetherLeft
            bids = 0
            deeBoundaryThisRupture = false
            deeCausedStrain = false
            interruptStrain = false
            pending.removeAll { $0.kind == .reconciled || $0.kind == .awkwardRepair }
        }
        if Self.isOpen(new) {
            if ruptureOwner == nil { ruptureOwner = m.ongoing.person }
            if let owner = ruptureOwner {
                persistedLeft = togetherLeft
                effects.append(.persist(.openRepair(owner, new, togetherSecondsLeft: max(0, togetherLeft))))
            }
        } else if Self.isOpen(old) {
            if let owner = ruptureOwner { effects.append(.persist(.clearOpenRepair(owner))) }
            ruptureOwner = nil
            bids = 0
            if new == .fine { pending.removeAll { $0.kind == .deeBoundary } }
        }
    }

    mutating func addAwkwardness(_ x: Double, deeCaused: Bool, _ m: inout Moment) {
        m.ongoing.awkwardness = clamp01(m.ongoing.awkwardness + x)
        if deeCaused { deeCausedStrain = true }
    }

    // MARK: People and the open rupture

    mutating func noteContact(_ p: Percept, now: Date) {
        switch p {
        case .heard, .partial, .touch, .gesture, .head, .pause, .bargeIn, .presence(arrived: true):
            lastContact = now
        case .identified(let id, _) where id != nil:
            lastContact = now
        case .presence(arrived: false), .asleep(true):
            lastContact = nil
        default:
            break
        }
    }

    func together(at now: Date) -> Bool {
        lastContact.map { now.timeIntervalSince($0) <= Self.togetherGrace } ?? false
    }

    /// Parks an open rupture when someone else is speaking, restores a carried one when
    /// its person is back, and stores session boundaries once the speaker is known.
    mutating func followPerson(_ m: inout Moment, _ effects: inout [Effect], _ rng: inout Rand) {
        let person = m.ongoing.person
        defer { lastPerson = person }
        guard let person else { return }
        if person != lastPerson {
            if Self.isOpen(m.ongoing.repair), let owner = ruptureOwner, owner != person {
                carried[owner] = m.ongoing.repair
                carriedLeft[owner] = togetherLeft
                carriedFromEarlier.remove(owner)
                effects.append(.persist(.openRepair(owner, m.ongoing.repair, togetherSecondsLeft: max(0, togetherLeft))))
                m.ongoing.repair = .fine
                phaseSince = m.now
                ruptureOwner = nil
                bids = 0
                pending.removeAll { $0.kind == .deeBoundary || $0.kind == .reconciled }
                m.signal("repairPhase", label: RepairPhase.fine.rawValue, by: Self.name)
            } else if Self.isOpen(m.ongoing.repair), ruptureOwner == nil {
                ruptureOwner = person
                effects.append(.persist(.openRepair(person, m.ongoing.repair, togetherSecondsLeft: max(0, togetherLeft))))
            }
        }
        if !Self.isOpen(m.ongoing.repair), let phase = carried[person], phase == .repairing, carriedFromEarlier.contains(person) {
            // They apologised in an earlier conversation: that is made up, silently.
            carried[person] = nil
            carriedLeft[person] = nil
            carriedFromEarlier.remove(person)
            effects.append(.persist(.clearOpenRepair(person)))
        }
        if !Self.isOpen(m.ongoing.repair), let phase = carried.removeValue(forKey: person) {
            carriedFromEarlier.remove(person)
            let left = carriedLeft.removeValue(forKey: person) ?? Self.openTogether
            m.ongoing.repair = phase
            phaseSince = m.now
            ruptureOwner = person
            togetherLeft = left
            persistedLeft = left
            bids = phase == .repairing ? 1 : 0
            deeBoundaryThisRupture = false
            m.signal("repairPhase", label: phase.rawValue, by: Self.name)
        }
        if !sessionBoundaries.isEmpty {
            for topic in sessionBoundaries {
                effects.append(.persist(.boundary(upsertBoundary(person: person, topic: topic, owner: .user, &m, &rng))))
            }
            sessionBoundaries = []
        }
    }

    // MARK: User boundaries

    /// Applies this step's boundary requests (own detection on `text` plus signals);
    /// returns the topics newly set (for the context note).
    mutating func userBoundaries(text: String?, inbox: [Signal], _ m: inout Moment, _ effects: inout [Effect],
                                 _ rng: inout Rand) -> [Subject] {
        var set: [Subject] = []
        var lift: [Subject] = []
        // Pronouns ("don't ask me about it") are resolved once, by Interpreter, and
        // arrive as its signal; our own reading takes explicit subjects only (review
        // finding 7), so the two can never store different boundaries.
        if let text, let r = Self.boundaryRequest(in: text, topic: nil) {
            if r.lift { lift.append(r.topic) } else { set.append(r.topic) }
        }
        for s in inbox {
            guard let subject = s.subject else { continue }
            if s.name == "userBoundary", !set.contains(subject) { set.append(subject) }
            if s.name == "userBoundaryLifted", !lift.contains(subject) { lift.append(subject) }
        }
        var added: [Subject] = []
        for topic in set {
            if let person = m.ongoing.person {
                effects.append(.persist(.boundary(upsertBoundary(person: person, topic: topic, owner: .user, &m, &rng))))
            } else if !sessionBoundaries.contains(topic) {
                sessionBoundaries.append(topic)
            }
            m.signal("userBoundary", subject: topic, by: Self.name)
            added.append(topic)
        }
        for topic in lift {
            sessionBoundaries.removeAll { $0.overlaps(topic) }
            if let person = m.ongoing.person {
                for i in m.enduring.boundaries.indices {
                    let b = m.enduring.boundaries[i]
                    guard b.person == person, b.owner == .user, b.active, b.topic.overlaps(topic) else { continue }
                    m.enduring.boundaries[i].active = false
                    effects.append(.persist(.boundary(m.enduring.boundaries[i])))
                }
            }
            m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .userBoundary && $0.mentions(topic) }
            m.signal("userBoundaryLifted", subject: topic, by: Self.name)
        }
        return added
    }

    /// Creates the boundary or reactivates the existing (person, topic, owner) row.
    mutating func upsertBoundary(person: PersonID, topic: Subject, owner: Boundary.Owner, _ m: inout Moment,
                                 _ rng: inout Rand) -> Boundary {
        if let i = m.enduring.boundaries.firstIndex(where: { $0.person == person && $0.topic == topic && $0.owner == owner }) {
            if !m.enduring.boundaries[i].active {
                m.enduring.boundaries[i].active = true
                m.enduring.boundaries[i].createdAt = m.now
            }
            return m.enduring.boundaries[i]
        }
        let b = Boundary(id: rng.uuid(), person: person, topic: topic, owner: owner, createdAt: m.now)
        m.enduring.boundaries.append(b)
        return b
    }

    /// One "Don't bring up" context note per user turn: topics set this turn first, then
    /// (when the frozen prompt lacks the person's line) their active boundaries, then the
    /// unidentified speaker's session boundaries.
    mutating func raiseBoundaryNote(new: [Subject], _ m: inout Moment) {
        var topics = new
        if m.ongoing.promptRendered, let person = m.ongoing.person, person != m.ongoing.promptPerson {
            topics += m.enduring.boundaries
                .filter { $0.person == person && $0.owner == .user && $0.active }
                .sorted { ($0.createdAt, $0.topic.text) > ($1.createdAt, $1.topic.text) }
                .map(\.topic)
        }
        topics += sessionBoundaries.reversed()
        var unique: [Subject] = []
        for t in topics where !unique.contains(t) { unique.append(t) }
        guard !unique.isEmpty else { return }
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .userBoundary }
        m.ongoing.raise(.userBoundaries(Array(unique.prefix(SelfBlock.maxBoundaries))), by: Self.name)
    }

    // MARK: Notes

    mutating func addPending(_ kind: Note.Kind, life: TimeInterval, now: Date) {
        pending.removeAll { $0.kind == kind }
        pending.append(PendingNote(kind: kind, until: now.addingTimeInterval(life)))
    }

    /// Keeps our unissued aims among the candidates (a cue may pass one over) until
    /// they are issued or go stale.
    mutating func raisePending(_ m: inout Moment) {
        let now = m.now
        pending.removeAll { now >= $0.until }
        pending.removeAll { $0.kind == .deeBoundary && !Self.isOpen(m.ongoing.repair) }
        let kinds = pending.map(\.kind)
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && Self.managedNotes.contains($0.kind) && !kinds.contains($0.kind) }
        for n in pending where !m.ongoing.noteCandidates.contains(where: { $0.owner == Self.name && $0.kind == n.kind }) {
            switch n.kind {
            case .deeBoundary: m.ongoing.raise(.deeBoundary(), by: Self.name)
            case .reconciled: m.ongoing.raise(.reconciled(), by: Self.name)
            case .awkwardRepair: m.ongoing.raise(.awkwardRepair(), by: Self.name)
            default: break
            }
        }
    }

    /// Our aims kept in step with `pending` (a stale one is withdrawn).
    static let managedNotes: [Note.Kind] = [.deeBoundary, .reconciled, .awkwardRepair]

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        guard n.owner == Self.name else { return [] }
        pending.removeAll { $0.kind == n.kind }
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == n.kind }
        return []
    }

    // MARK: Hooks

    public mutating func seed(from c: Carried, _ m: inout Moment) {
        carried = c.openRepair
        carriedLeft = [:]
        carriedFromEarlier = Set(c.openRepair.keys)
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        // Conversation-scoped: awkwardness and its strain, a finished reconciliation, and
        // a repair under way (they already apologised: it ends silently with the
        // conversation, so no "they made up with you" days later). An unrepaired rupture
        // carries on (it ends by repair or after 6 h together).
        var effects: [Effect] = []
        if m.ongoing.repair == .repairing {
            setPhase(.fine, &m, &effects)
        }
        if m.ongoing.repair == .strained || m.ongoing.repair == .reconciled {
            m.ongoing.repair = .fine
            phaseSince = m.now
        }
        carriedFromEarlier.formUnion(carried.keys)
        m.ongoing.awkwardness = 0
        deeCausedStrain = false
        interruptStrain = false
        playfulAt = nil
        anyPlayfulAt = nil
        playfulSentences = 0
        pending = []
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && Self.managedNotes.contains($0.kind) }
        return effects
    }

    public mutating func flush(_ m: inout Moment) -> [Effect] {
        guard Self.isOpen(m.ongoing.repair), let owner = ruptureOwner else { return [] }
        persistedLeft = togetherLeft
        return [.persist(.openRepair(owner, m.ongoing.repair, togetherSecondsLeft: max(0, togetherLeft)))]
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        carried[id] = nil
        carriedLeft[id] = nil
        if ruptureOwner == id {
            ruptureOwner = nil
            if Self.isOpen(m.ongoing.repair) { m.ongoing.repair = .fine }
            bids = 0
            hostileTimes = []
            pending = []
        }
        if lastPerson == id { lastPerson = nil }
        avoid = Self.avoidTopics(m.enduring, person: m.ongoing.person, session: sessionBoundaries)
    }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        if let phase = carried.removeValue(forKey: from), carried[into] == nil {
            carried[into] = phase
            if let left = carriedLeft[from] { carriedLeft[into] = left }
        }
        carriedLeft[from] = nil
        if carriedFromEarlier.remove(from) != nil, carried[into] != nil { carriedFromEarlier.insert(into) }
        if ruptureOwner == from { ruptureOwner = into }
        if lastPerson == from { lastPerson = into }
        avoid = Self.avoidTopics(m.enduring, person: m.ongoing.person, session: sessionBoundaries)
    }

    public mutating func forgetAll(_ m: inout Moment) {
        let keep = (lastUpdate, lastContact)
        self = RepairKeeper()
        (lastUpdate, lastContact) = keep
        lastPerson = m.ongoing.person
    }

    // MARK: Traces

    public static func slice(of m: Moment) -> [String: String] {
        ["repair": m.ongoing.repair.rawValue, "awkwardness": String(format: "%.3f", m.ongoing.awkwardness)]
    }

    /// `slice` plus our note candidates and the speaker's active boundaries, for this
    /// reducer's whole-pipeline goldens (`slice` stays two keys: it is in every default
    /// Cortex trace).
    public static func traceSlice(of m: Moment) -> [String: String] {
        var s = slice(of: m)
        s["notes"] = m.ongoing.noteCandidates.filter { $0.owner == name }.map(\.kind.rawValue).joined(separator: ",")
        s["boundaries"] = m.enduring.boundaries
            .filter { $0.person == m.ongoing.person && $0.active }
            .map { "\($0.owner.rawValue):\($0.topic.text)" }
            .sorted()
            .joined(separator: ",")
        return s
    }

    // MARK: - Pure helpers (public so Interpreter's RepairDetector can share them)

    public static func isOpen(_ p: RepairPhase) -> Bool { p == .ruptured || p == .repairing }

    /// The CuriosityDirector avoid list for `person`: active user boundaries + `session`.
    public static func avoidTopics(_ e: Enduring, person: PersonID?, session: [Subject] = []) -> Set<String> {
        var out = Set(session.map(\.text))
        if let person {
            for b in e.boundaries where b.person == person && b.owner == .user && b.active { out.insert(b.topic.text) }
        }
        return out
    }

    static let playfulTags: Set<Emotion> = [.playful, .mischievous, .giddy]
    static let laughterLabels: Set<String> = Laughter.labels
    static let gentleTouches: Set<String> = ["pet", "petting", "stroke", "stroking", "hug", "hold", "holding", "cuddle"]

    static func isSignal(_ s: Signal, _ name: String) -> Bool { s.name == name }

    static func isLaughter(_ p: Percept) -> Bool {
        if case .sound(let label, _) = p { return Laughter.isLaughter(label) }
        return false
    }

    /// A step the user caused (rupture triggers and bids are evaluated only here).
    /// Laughter counts only right after Dee spoke (`reduce` adds it).
    static func isSocial(_ p: Percept) -> Bool {
        switch p {
        case .heard, .touch, .gesture: true
        default: false
        }
    }

    /// A reconciliation bid in this percept (§7.8).
    public static func isBid(_ p: Percept, laughed: Bool = false) -> Bool {
        switch p {
        case .heard(let text, _, _, let a):
            if a.hostility >= hostileAt || a.threat >= hostileAt { return false }
            if a.apology >= 0.3 { return true }
            if a.humor >= 0.5 || laughed { return true }
            return isBidText(text)
        case .touch(let kind, let gentle, _):
            return gentle && gentleTouches.contains(kind.lowercased())
        case .gesture(let g):
            return g.lowercased() == "thumbsup" || g.lowercased() == "thumbs up"
        case .sound:
            // Only laughter that answers Dee (`laughed`, within 15 s of her speaking).
            return laughed && isLaughter(p)
        default:
            return laughed
        }
    }

    static let bidPhrases = ["are we ok", "are we okay", "are we good", "are we cool", "are we alright", "friends?",
                             "still friends", "be friends", "i didn't mean it", "i didnt mean it", "i did not mean it",
                             "didn't mean that", "didnt mean that", "i'm sorry", "im sorry", "sorry about that",
                             "forgive me", "make up"]

    public static func isBidText(_ text: String) -> Bool {
        let t = normalize(text)
        return bidPhrases.contains { t.contains($0) }
    }

    /// A joke landed badly: "not funny", or a clearly negative, hostile or dismissive
    /// reply without humour. A neutral reply ("yeah so anyway…") is no evidence
    /// (review finding 2).
    public static func jokeFlopped(text: String, appraisal a: Appraisal) -> Bool {
        if saysNotFunny(text) { return true }
        return a.humor < 0.2 && (a.valence < -0.2 || a.hostility >= 0.3 || a.dismissal >= 0.3)
    }

    public static func saysNotFunny(_ text: String) -> Bool {
        let t = normalize(text)
        return t.contains("not funny") || t.contains("isn't funny") || t.contains("wasn't funny") || t.contains("not that funny")
    }

    // MARK: Boundary phrases

    static let setPhrases = [
        "don't ask me about ", "dont ask me about ", "do not ask me about ", "don't ask about ", "dont ask about ",
        "do not ask about ", "i don't want to talk about ", "i dont want to talk about ", "i do not want to talk about ",
        "i'd rather not talk about ", "i would rather not talk about ", "stop asking me about ", "stop asking about ",
        "quit asking me about ", "quit asking about ", "don't bring up ", "dont bring up ", "do not bring up ",
        "stop bringing up ", "please don't mention ", "don't mention ", "dont mention ",
    ]
    static let liftPhrases = [
        "you can ask me about ", "you can ask about ", "you can talk about ", "you can bring up ", "you can mention ",
        "it's ok to ask about ", "its ok to ask about ", "it's okay to ask about ", "its okay to ask about ",
        "it's fine to ask about ", "feel free to ask about ", "feel free to ask me about ",
    ]
    /// Words that end the topic phrase.
    static let stopWords: Set<String> = [
        "and", "because", "cause", "cuz", "since", "ok", "okay", "please", "anymore", "again", "now", "today", "tonight",
        "that", "which", "who", "when", "where", "if", "with", "either", "ever", "for", "right", "or", "but", "so",
        "except", "any", "alright", "thanks", "thank",
        "under", "in", "on", "at", "from", "to", "of", "into", "over", "near", "behind", "after", "before", "during",
    ]
    static let leading: Set<String> = ["my", "the", "a", "an", "your", "our", "his", "her", "their", "all", "about"]

    /// "Don't ask me about X" → (X, lift: false); "you can ask me about X again" →
    /// (X, lift: true). A pronoun ("it", "that") stands for `topic` (the current topic).
    /// nil when nothing matches or no subject can be formed. The text stays in RAM.
    /// "Don't mention it" / "you can mention it" is politeness, not a boundary: the
    /// "mention" phrases need an explicit subject (review finding 7).
    public static func boundaryRequest(in text: String, topic: Subject? = nil) -> (topic: Subject, lift: Bool)? {
        let t = " " + normalize(text) + " "
        for (phrases, lift) in [(liftPhrases, true), (setPhrases, false)] {
            for ph in phrases {
                guard let r = t.range(of: " " + ph) else { continue }
                if lift, !t[r.upperBound...].contains("again"), !ph.hasPrefix("it"), !ph.hasPrefix("feel") { continue }
                let explicit = subject(after: String(t[r.upperBound...]))
                if let s = explicit ?? (ph.contains("mention") ? nil : topic) { return (s, lift) }
                return nil
            }
        }
        return nil
    }

    static func subject(after rest: String) -> Subject? {
        var words: [String] = []
        for raw in rest.split(separator: " ") {
            let w = String(raw)
            let clean = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
            if clean.isEmpty || stopWords.contains(clean) { break }
            if words.isEmpty, leading.contains(clean) { continue }
            words.append(clean)
            if words.count == Subject.maxWords || w.last.map({ ",.!?;:".contains($0) }) == true { break }
        }
        return words.isEmpty ? nil : Subject(words.joined(separator: " "))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: Regard window

    mutating func sampleRegard(_ m: Moment, social: Bool) {
        let now = m.now
        // Samples are in time order: drop the stale head only.
        if let i = regardSamples.firstIndex(where: { now.timeIntervalSince($0.at) <= Self.regardWindow }) {
            if i > 0 { regardSamples.removeFirst(i) }
        } else {
            regardSamples.removeAll()
        }
        let r = m.ongoing.mind.regard
        if social || regardSamples.last.map({ now.timeIntervalSince($0.at) >= 2 || abs($0.regard - r) > 0.02 }) ?? true {
            regardSamples.append(RegardSample(at: now, regard: r))
        }
        if regardSamples.count > 300 { regardSamples.removeFirst(regardSamples.count - 300) }
    }
}
