import DeeCore
import DeeMemory
import DeeMind
import Foundation

/// Sub-reducer 6 — intentions, anticipation follow-through and initiative (SELF.md §7.5, §7.6).
///
/// Owns: `ongoing.intentions`, `ongoing.expectations` (status, and records created from a
/// `plan` signal), `ongoing.followUpsThisConversation`. Requests: initiative
/// (`requestInitiative`); raises aim notes (`followUp` / `followUpGentle` / `intention`).
/// Reads: curiosity candidates (its own seeded `CuriosityDirector`), topic, focus, person,
/// floor, mutual gaze, hypotheses (busy / wantsQuiet), repair, boundaries, lessons
/// (`askedTooMuch`), interests, misreads, episode index, `urgeToTalk`.
///
/// **Sources** (§7.6):
/// - *follow-ups*: every pending `Expectation` gets one `Intention(.followUp, notBefore:
///   due + 2 h, expires: due + 7 d, priority 0.8)`, whether the expectation was appended by
///   Interpreter or created here from a `plan` signal;
/// - *curiosity*: `CuriosityDirector.candidates` (sight, sound, touch, music, greeting, and
///   the general human / game / thought / feeling topics). The director is private to the
///   board, fed from percepts and seeded from the board's stream; its cooldowns are
///   committed only when the note is actually issued (`noteIssued`). Candidates are RAM
///   only — never an `Intention` row;
/// - *repair*: `.repair` intentions jump the queue (priority 1, relevance 1); while a
///   rupture is open (`ruptured` / `repairing`) nothing else is aimed;
/// - *learn*: an interest > 0.6 that she knows < 2 things about (episodes on the subject,
///   or the `facts` signal) → `.learn`, 2 steps (one short question each);
/// - *share*: a completed learn intention queues a `.share` about the same subject;
/// - *skill*: ≥ 2 misreads of one situation with one person in 7 days → `.skill`, done after
///   5 clean conversations with them (no aim note: practice is behavioural, via lessons);
/// - *ritual*: Learner performs rituals and raises the goodnight aim itself (same step);
///   the board only lets a morning / welcome-home ritual count as the arrival greeting.
/// At most 3 self-motivated (learn / skill / share) live, at most one born per 24 h;
/// ≤ 16 live intentions and ≤ 8 pending expectations (lowest priority / oldest dropped
/// silently).
///
/// **Score** `p = priority × relevance × timing × (0.5 + urgeToTalk)`; relevance 1 for a
/// subject match (topic or focus), 0.6 for a person match, 0.3 otherwise.
/// - On a user turn (`.heard`) the best option with p > 0.35 is raised as the aim note
///   (timing 1; general curiosity topics excluded — she answers what was said).
/// - Idle (`.tick`, floor idle, someone present, mutual gaze, awake, ≥ 3 s after anyone
///   spoke): the best option with p > 0.6 (0.85 with a busy hypothesis; +0.1 after an
///   `askedTooMuch` lesson for the person; never with `wantsQuiet` or a stated busy) becomes an initiative
///   request. Board and general topics are paced: ≥ 20 s between initiatives, doubled per
///   unanswered one (cap 10 min), none after 3 unanswered until the user engages; fresh
///   stimuli (sight / sound / touch / greeting) are paced by the director alone.
///
/// **Follow-ups** (§7.5) fire only when `now ≥ notBefore`, the intention's person is the
/// identified speaker, `turnsThisConversation ≥ 1`, no other follow-up was issued this
/// conversation, and (for initiative) not within 10 s of arrival; on their first turn it
/// rides along with the reunion context note. An outcome report that does not name the
/// subject ("it went really well!", "they want a second round") resolves the one due
/// expectation of theirs (`Interpreter.OutcomeReport`), so a moot aim is never issued. Health (and funeral / court / vet)
/// subjects use the gentle variant, which counts as asked when the reply asks anything.
/// An undated plan gets a dormant follow-up (notBefore = expires): it resolves only when
/// they bring it up. Listener's `questionLetGo` drops the aim it names. The initiative
/// back-off resets only after ≥ 60 s of absence (a flapping presence does not).
/// The reply asking about it moves the expectation to `asked`; the appraisal of the next
/// user turn is the outcome (`resolved`, `.appraise(.internal(relief:))` when they were
/// nervous and it went well, `followUpResolved` signal). A user mentioning the subject
/// first (after it was due) resolves it the same way and the intention is `done`.
///
/// **Follow-through** (deterministic): issue → `issued`, `issuedCount += 1`; on
/// `.deeTurnFinished` only this turn's aims are checked: `done` when the reply mentions the
/// subject; else re-eligible after ≥ 2 user turns; dropped silently once issued twice.
/// `done` advances learn / skill / share steps; completion fires `.internal(pride:)`.
///
/// **Silence:** intentions and expectations past `expires` expire silently on every step
/// (before anything is raised), so nothing that lapsed while the user was away is ever
/// mentioned. Topics under an active user boundary are dropped silently and avoided.
///
/// Signals read: `plan` (Interpreter, decoded with `Interpreter.plan(from:)`; id = the
/// expectation's id), `expectationOutcome` (Interpreter: id, value = outcome valence,
/// label "asked" / "unprompted" — the board's own check is the fallback when it is
/// absent), `facts` (subject, value = how many facts DeeMemory holds on it), `ritual`
/// (Learner: label = `Ritual.Trigger`; a morning / welcome-home ritual consumes the
/// pending greeting), `questionLetGo` (Listener: id = the aim to drop). Signals raised: `followUpResolved`
/// (subject, value = outcome valence, id = expectation id, label = framing) for
/// EpisodeBuilder; `intentionDone` (subject, id, label = kind) for EpisodeBuilder / Learner.
public struct IntentionBoard: SubReducer {
    public static let name = "IntentionBoard"

    // MARK: Tuning

    public static let aimThreshold = 0.35
    public static let initiativeThreshold = 0.6
    public static let busyInitiativeThreshold = 0.85
    public static let askedTooMuchPenalty = 0.1
    public static let relevanceSubject = 1.0
    public static let relevancePerson = 0.6
    public static let relevanceOther = 0.3
    /// Follow-ups: due + 2 h … due + 7 d (§7.5).
    public static let followUpDelay: TimeInterval = 2 * 3600
    public static let followUpLifetime: TimeInterval = 7 * 86_400
    public static let followUpPriority = 0.8
    public static let defaultDue: TimeInterval = 86_400
    public static let arrivalGrace: TimeInterval = 10
    /// Turns before an issued, unanswered aim may be issued again.
    public static let reissueAfterTurns = 2
    public static let quietAfterSpeech = CuriosityDirector.quietAfterSpeech
    public static let initiativeSpacing: TimeInterval = 20
    public static let maxInitiativeGap: TimeInterval = 10 * 60
    public static let unansweredLimit = 3
    /// Self-motivated births.
    public static let birthSpacing: TimeInterval = 86_400
    public static let learnInterest = 0.6
    public static let learnKnownFacts = 2
    public static let learnSteps = 2
    public static let learnPriority = 0.55
    public static let learnLifetime: TimeInterval = 14 * 86_400
    /// Between two steps of a multi-step intention.
    public static let stepRest: TimeInterval = 10 * 60
    public static let sharePriority = 0.6
    public static let shareLifetime: TimeInterval = 7 * 86_400
    public static let skillMisreads = 2
    public static let skillWindow: TimeInterval = 7 * 86_400
    public static let skillSteps = 5
    public static let skillPriority = 0.4
    public static let skillLifetime: TimeInterval = 60 * 86_400
    public static let ritualPriority = 0.7
    public static let ritualLifetime: TimeInterval = 10 * 60
    public static let learnPride = 0.4
    public static let sharePride = 0.3
    public static let skillPride = 0.6
    /// Max characters of an `intention` note's action (the template's slot cap).
    public static let maxAction = NoteTemplates.slotCaps(.intention)[0]

    /// Subjects that get the gentle follow-up ("Gently ask how they've been feeling."):
    /// serious health and heavy events only. Tune 4 decision (a): an ordinary appointment
    /// (dentist, check-up, doctor, vet, haircut, jab) is followed up by name ("How did the
    /// dentist go?"); live, the oblique wording never named the dentist at all.
    public static let healthWords: Set<String> = [
        "surgery", "operation", "hospital", "scan", "mri", "x-ray", "biopsy", "therapy", "therapist", "treatment", "chemo",
        "chemotherapy", "results", "diagnosis", "procedure", "blood", "clinic", "rehab", "ultrasound", "transplant",
        "cancer", "tumour", "tumor", "specialist", "oncologist", "oncology", "ivf", "miscarriage",
        // Not health, but "how did it go?" is just as wrong (review finding 10).
        "funeral", "hearing", "court", "trial", "memorial",
    ]
    /// Ordinary appointments: asked by name even when an older build persisted them as
    /// health (`healthReason`), unless a serious word is in the subject too.
    public static let ordinaryAppointmentWords: Set<String> = [
        "dentist", "dentist's", "dental", "checkup", "check-up", "doctor", "doctor's", "gp", "vet", "vet's", "haircut",
        "hairdresser", "barber", "physio", "jab", "vaccine", "flu", "optician", "eye", "teeth", "orthodontist",
    ]
    /// Absence this long resets the initiative back-off (a flapping presence does not).
    public static let absenceResetsBackoff: TimeInterval = 60

    // MARK: Private state (RAM only)

    /// Intentions whose aim note was issued since the last `.deeTurnFinished`.
    public private(set) var aimedThisTurn: [UUID] = []
    /// User turns seen (monotonic; re-eligibility).
    public private(set) var turn = 0
    /// Turn at which each intention was last issued.
    var issuedAtTurn: [UUID: Int] = [:]
    /// Intentions followed up this conversation (a re-issue of the same one is allowed).
    public private(set) var followedUpThisConversation: [UUID] = []
    /// The expectation whose follow-up Dee just asked: the next user turn is its outcome.
    public private(set) var awaitingOutcome: UUID?
    /// Curiosity candidates behind aim notes raised but not yet issued (≤ 4).
    var curiosityAims: [(id: UUID, candidate: CuriosityDirector.Candidate)] = []
    /// The aim of the latest initiative request (its issue is an initiative, not a reply).
    var initiativeAim: UUID?
    var director = CuriosityDirector()
    var directorSeeded = false
    public private(set) var present = false
    var asleep = false
    var arrivedAt: Date?
    var lastSpeechAt: Date?
    public private(set) var lastInitiativeAt: Date?
    public internal(set) var unansweredInitiatives = 0
    /// Last self-motivated birth.
    public private(set) var lastBirth: Date?
    /// Subjects whose share intention waits for the next birth slot.
    public private(set) var shareQueue: [Subject] = []
    /// From the `facts` signal.
    var knownFacts: [(subject: Subject, count: Int)] = []
    /// People identified in the current conversation, and its user turns.
    var peopleThisConversation: [PersonID] = []
    var userTurnsThisConversation = 0
    /// Misreads seen this conversation (`misreadThisTurn`), for skills.
    var misreadsThisConversation: [Misread] = []
    /// "Forget that" subjects: never raised again this session.
    var forgotten: [Subject] = []
    /// Plan subjects the `plan` signal flagged as health (until their follow-up exists).
    var healthSubjects: [Subject] = []
    /// Undated plan subjects (until their dormant follow-up exists).
    var undatedSubjects: [Subject] = []
    /// When the user was last seen leaving (presence false).
    var leftAt: Date?
    /// The due follow-up raised on `.promptSubmitted` for the reply being built (fast
    /// mode picks a reply's notes before its words arrive). Withdrawn on the next step
    /// if no cue took it, so it never rides on a later initiative.
    var preAim: UUID?
    /// Her sentences heard since the last `.deeTurnFinished` (follow-through reads them
    /// when the finished text is empty, and a reply with none was never delivered).
    var saidThisTurn: [String] = []
    /// What each aim issued since the last `.deeTurnFinished` changed, so an undelivered
    /// reply (cancelled before a sentence was heard) gives it back.
    var issueUndo: [UUID: (status: Intention.Status, issuedAt: Int?, newFollowUp: Bool)] = [:]

    public init() {}

    // MARK: Reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        if !directorSeeded {
            // Seeded from (a copy of) the board's stream without drawing from it, so the
            // board's stream only moves when it creates something.
            var peek = rng
            director = CuriosityDirector(seed: peek.next())
            directorSeeded = true
        }
        var fx: [Effect] = []
        if let id = preAim {
            m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.intention == id }
            preAim = nil
        }
        fx += expire(&m)
        observe(p, &m)
        fx += readSignals(&m, &rng)
        fx += linkExpectations(&m, &rng)
        fx += dropBoundaryTopics(&m)
        director.avoid = avoidSet(m)

        switch p {
        case .tick:
            housekeeping(&m)
            fx += birthSelfMotivated(&m, &rng)
            considerInitiative(&m, &rng)
        case .conversationStarted:
            fx += closeConversation(&m)
            housekeeping(&m)
        case .heard(let text, _, _, let appraisal):
            fx += outcome(text: text, appraisal: appraisal, &m)
            raiseAim(&m, &rng)
        case .promptSubmitted:
            raiseDueFollowUp(&m)
        case .deeTurnFinished(let text):
            let said = saidThisTurn
            saidThisTurn = []
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? said.joined(separator: " ") : text
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fx += undeliveredReply(&m)
            } else {
                issueUndo = [:]
                fx += followThrough(reply.lowercased(), &m)
            }
        default:
            break
        }
        return fx
    }

    // MARK: Hooks

    public mutating func seed(from c: Carried, _ m: inout Moment) {
        m.ongoing.intentions = c.intentions
        m.ongoing.expectations = c.expectations
        lastBirth = c.intentions.filter(\.isSelfMotivated).map(\.created).max()
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.followUpsThisConversation = 0
        followedUpThisConversation = []
        peopleThisConversation = m.ongoing.person.map { [$0] } ?? []
        userTurnsThisConversation = 0
        misreadsThisConversation = []
        awaitingOutcome = nil
        saidThisTurn = []
        issueUndo = [:]
        // Repair aims belong to the conversation they were born in (never "make things
        // right" days later).
        var fx: [Effect] = []
        for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].kind == .repair && m.ongoing.intentions[i].isLive {
            fx += settle(i, .dropped, &m)
        }
        return fx
    }

    /// An aim note was issued: the board's own intention, or one of its curiosity aims.
    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        guard let id = n.intention else { return [] }
        let byInitiative = id == initiativeAim
        if let k = curiosityAims.firstIndex(where: { $0.id == id }) {
            director.commit(curiosityAims[k].candidate, at: m.now, asReply: !byInitiative)
            curiosityAims.remove(at: k)
            if byInitiative { initiativeSpoken(m.now) }
            return []
        }
        guard let i = m.ongoing.intentions.firstIndex(where: { $0.id == id }) else { return [] }
        if issueUndo[id] == nil {
            issueUndo[id] = (m.ongoing.intentions[i].status, issuedAtTurn[id],
                             m.ongoing.intentions[i].kind == .followUp && !followedUpThisConversation.contains(id))
        }
        m.ongoing.intentions[i].status = .issued
        m.ongoing.intentions[i].issuedCount += 1
        m.ongoing.intentions[i].updated = m.now
        issuedAtTurn[id] = turn
        if !aimedThisTurn.contains(id) { aimedThisTurn.append(id) }
        if m.ongoing.intentions[i].kind == .followUp, !followedUpThisConversation.contains(id) {
            followedUpThisConversation.append(id)
            m.ongoing.followUpsThisConversation += 1
        }
        if byInitiative { initiativeSpoken(m.now) }
        return [.persist(.intention(m.ongoing.intentions[i]))]
    }

    public mutating func forget(subject: Subject, _ m: inout Moment) {
        scrubIDs(m)
        curiosityAims.removeAll { c in Subject(c.candidate.label).map { $0.overlaps(subject) } ?? false }
        shareQueue.removeAll { $0.overlaps(subject) }
        healthSubjects.removeAll { $0.overlaps(subject) }
        undatedSubjects.removeAll { $0.overlaps(subject) }
        knownFacts.removeAll { $0.subject.overlaps(subject) }
        misreadsThisConversation.removeAll { $0.topic?.overlaps(subject) ?? false }
        if !forgotten.contains(subject) { forgotten.append(subject) }
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        scrubIDs(m)
        peopleThisConversation.removeAll { $0 == id }
        misreadsThisConversation.removeAll { $0.person == id }
    }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        peopleThisConversation = peopleThisConversation.map { $0 == from ? into : $0 }
        var unique: [PersonID] = []
        for p in peopleThisConversation where !unique.contains(p) { unique.append(p) }
        peopleThisConversation = unique
        for i in misreadsThisConversation.indices where misreadsThisConversation[i].person == from {
            misreadsThisConversation[i].person = into
        }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        self = IntentionBoard()
    }

    /// Ids the board holds that no longer exist in RAM (Cortex already scrubbed them).
    mutating func scrubIDs(_ m: Moment) {
        let live = m.ongoing.intentions.map(\.id)
        aimedThisTurn.removeAll { !live.contains($0) }
        issuedAtTurn = issuedAtTurn.filter { live.contains($0.key) }
        followedUpThisConversation.removeAll { !live.contains($0) }
        issueUndo = issueUndo.filter { live.contains($0.key) }
        if let a = preAim, !live.contains(a) { preAim = nil }
        if let a = awaitingOutcome, !m.ongoing.expectations.contains(where: { $0.id == a }) { awaitingOutcome = nil }
    }

    // MARK: Percept bookkeeping

    mutating func observe(_ p: Percept, _ m: inout Moment) {
        let now = m.now
        switch p {
        case .presence(let arrived):
            present = arrived
            if arrived {
                // Only a real absence resets the back-off (review finding 16).
                if let left = leftAt, now.timeIntervalSince(left) >= Self.absenceResetsBackoff { unansweredInitiatives = 0 }
                leftAt = nil
                arrivedAt = now
                director.note(.userArrived, at: now)
            } else if leftAt == nil {
                leftAt = now
            }
        case .identified(let id, _):
            if id != nil { present = true }
        case .head:
            present = true
        case .heard:
            present = true
            turn += 1
            userTurnsThisConversation += 1
            lastSpeechAt = now
            unansweredInitiatives = 0
            director.note(.userSpoke, at: now)
        case .speakingFinished, .deeTurnFinished:
            lastSpeechAt = now
            director.note(.deeSpoke, at: now)
        case .deeSaid(_, let sentence):
            saidThisTurn.append(sentence)
        case .sight(let camera, _, let novel):
            if !novel.isEmpty { director.noteSight(novel, camera: camera.rawValue, novelty: nil, at: now) }
        case .sound(let label, let unexpected):
            director.noteSound(label, unexpected: unexpected, loudness: nil, at: now)
        case .touch(let kind, _, _):
            unansweredInitiatives = 0
            director.note(.touched(kind), at: now)
        case .asleep(let a):
            asleep = a
            director.asleepSince = a ? now : nil
        default:
            break
        }
        if let person = m.ongoing.person, !peopleThisConversation.contains(person) { peopleThisConversation.append(person) }
        if let mr = m.ongoing.misreadThisTurn, !misreadsThisConversation.contains(where: { $0.id == mr.id }) {
            misreadsThisConversation.append(mr)
        }
    }

    mutating func initiativeSpoken(_ now: Date) {
        lastInitiativeAt = now
        unansweredInitiatives += 1
        initiativeAim = nil
    }

    // MARK: Expiry and housekeeping

    /// Silent expiry (never a note). Runs first on every step.
    mutating func expire(_ m: inout Moment) -> [Effect] {
        let now = m.now
        var fx: [Effect] = []
        for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].isLive && now >= m.ongoing.intentions[i].expires {
            m.ongoing.intentions[i].status = .dropped
            m.ongoing.intentions[i].updated = now
            fx.append(.persist(.intention(m.ongoing.intentions[i])))
        }
        for i in m.ongoing.expectations.indices
        where (m.ongoing.expectations[i].status == .pending || m.ongoing.expectations[i].status == .asked) && now >= m.ongoing.expectations[i].expires {
            m.ongoing.expectations[i].status = .expired
            fx.append(.persist(.expectation(m.ongoing.expectations[i])))
            if awaitingOutcome == m.ongoing.expectations[i].id { awaitingOutcome = nil }
        }
        return fx
    }

    /// Finished intentions and settled expectations leave the board (they are persisted).
    mutating func housekeeping(_ m: inout Moment) {
        m.ongoing.intentions.removeAll { !$0.isLive }
        m.ongoing.expectations.removeAll { $0.status == .expired || $0.status == .resolved }
        scrubIDs(m)
    }

    // MARK: Signals

    mutating func readSignals(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        for s in m.inbox(for: Self.name) {
            switch s.name {
            case "plan":
                if let plan = Interpreter.plan(from: s) { fx += self.plan(plan, id: s.id, &m, &rng) }
            case "expectationOutcome":
                fx += outcomeSignal(s, &m)
            case "facts":
                guard let subject = s.subject else { continue }
                knownFacts.removeAll { $0.subject == subject }
                knownFacts.append((subject, max(0, Int(s.value))))
            case "ritual":
                fx += ritual(s, &m, &rng)
            case "questionLetGo":
                // Listener gave up on an unanswered question: never re-ask that aim.
                if let id = s.id, let i = m.ongoing.intentions.firstIndex(where: { $0.id == id }), m.ongoing.intentions[i].isLive,
                   m.ongoing.intentions[i].kind != .followUp {
                    fx += settle(i, .dropped, &m)
                }
            default:
                continue
            }
        }
        return fx
    }

    /// A plan the user mentioned (Interpreter's PlanDetector) → a pending expectation; its
    /// follow-up comes from `linkExpectations` in the same step.
    mutating func plan(_ plan: Interpreter.Plan, id: UUID?, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let subject = plan.subject
        guard let person = m.ongoing.person, !isAvoided(subject, person: person, m) else { return [] }
        if m.ongoing.expectations.contains(where: { $0.person == person && $0.subject.overlaps(subject) && ($0.status == .pending || $0.status == .asked) }) {
            return []
        }
        if plan.health { healthSubjects.append(subject) }
        if !plan.dated { undatedSubjects.append(subject) }
        let x = plan.expectation(id: id ?? rng.uuid(), person: person)
        m.ongoing.expectations.append(x)
        var fx: [Effect] = [.persist(.expectation(x))]
        fx += capExpectations(&m)
        return fx
    }

    /// Interpreter's outcome check: the user turn after the follow-up was asked, or the
    /// user bringing a due subject up first. Resolves it (and the follow-up, if unprompted).
    mutating func outcomeSignal(_ s: Signal, _ m: inout Moment) -> [Effect] {
        guard let id = s.id, let x = m.ongoing.expectations.firstIndex(where: { $0.id == id }),
              m.ongoing.expectations[x].status == .pending || m.ongoing.expectations[x].status == .asked else { return [] }
        var fx: [Effect] = []
        if let j = Self.followUp(for: m.ongoing.expectations[x], in: m), m.ongoing.intentions[j].isLive { fx += settle(j, .done, &m) }
        if awaitingOutcome == id { awaitingOutcome = nil }
        fx += resolve(x, valence: s.value, &m)
        return fx
    }

    /// Learner performs the ritual itself: the mannerism, a canned line for the morning
    /// hello and welcome home (which then counts as the arrival greeting), and the
    /// goodnight aim on the same step (review finding 15: an aim created here, a step
    /// later, made her say goodnight a second time when they kept talking).
    mutating func ritual(_ s: Signal, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        guard let trigger = s.label.flatMap(Ritual.Trigger.init(rawValue:)), trigger != .goodnight else { return [] }
        // The morning hello / welcome home ritual *was* the greeting: consume the
        // director's pending greeting so no second hello follows as an initiative.
        if let g = director.candidates(at: m.now, snapshot: m.ongoing.mind, userPresent: true, busy: false)
            .first(where: { $0.kind == .greeting }) {
            director.commit(g, at: m.now, asReply: true)
        }
        return []
    }

    static func ritualSubject(_ t: Ritual.Trigger) -> Subject? {
        switch t {
        case .firstSightOfDay: Subject("morning hello")
        case .goodnight: Subject("goodnight")
        case .returnHome: Subject("welcome home")
        }
    }

    // MARK: Follow-ups from expectations

    /// The follow-up intention serving `x`, if any (same person, same subject).
    static func followUp(for x: Expectation, in m: Moment) -> Int? {
        m.ongoing.intentions.firstIndex { $0.kind == .followUp && $0.person == x.person && $0.subject == x.subject }
    }

    /// The pending expectation a follow-up serves.
    static func expectation(for it: Intention, in m: Moment) -> Int? {
        guard it.kind == .followUp else { return nil }
        return m.ongoing.expectations.firstIndex { $0.person == it.person && $0.subject == it.subject && ($0.status == .pending || $0.status == .asked) }
    }

    /// Every pending expectation without a follow-up gets one.
    mutating func linkExpectations(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        for x in m.ongoing.expectations where x.status == .pending && Self.followUp(for: x, in: m) == nil {
            // An undated plan gets a dormant follow-up (never eligible: notBefore =
            // expires), so it is only resolved when they bring it up, and a relaunch
            // does not mint a timed one for it.
            let dormant = undatedSubjects.contains(x.subject)
            undatedSubjects.removeAll { $0 == x.subject }
            let notBefore = dormant ? x.expires : x.due.addingTimeInterval(Self.followUpDelay)
            guard dormant || notBefore < x.expires, m.now < x.expires else { continue }
            let health = healthSubjects.contains(x.subject) || Self.isHealth(x.subject)
            healthSubjects.removeAll { $0 == x.subject }
            let it = Intention(id: rng.uuid(), kind: .followUp, subject: x.subject, person: x.person,
                               reason: health ? Self.healthReason : Self.reason(x.framing),
                               notBefore: notBefore, expires: x.expires, priority: Self.followUpPriority, source: "plan", created: m.now)
            fx += add(it, &m)
        }
        return fx
    }

    /// Marks a follow-up as health-related (persisted, so the gentle wording survives a relaunch).
    public static let healthReason = "it was about their health"

    static func reason(_ f: Expectation.Framing) -> String {
        switch f {
        case .nervous: "they were nervous about it"
        case .excited: "they were excited about it"
        case .neutral: "they mentioned it was coming up"
        }
    }

    mutating func capExpectations(_ m: inout Moment) -> [Effect] {
        var fx: [Effect] = []
        while m.ongoing.expectations.filter({ $0.status == .pending }).count > Ongoing.maxPendingExpectations {
            // The stalest goes: the longest past due, else the furthest in the future.
            let pending = m.ongoing.expectations.indices.filter { m.ongoing.expectations[$0].status == .pending }
            let xs = m.ongoing.expectations
            let key = { (i: Int) in (xs[i].due, xs[i].id.uuidString) }
            let now = m.now
            let past = pending.filter { xs[$0].due < now }
            guard let i = past.isEmpty ? pending.max(by: { key($0) < key($1) }) : past.min(by: { key($0) < key($1) }) else { break }
            m.ongoing.expectations[i].status = .expired
            fx.append(.persist(.expectation(m.ongoing.expectations[i])))
            if let j = Self.followUp(for: m.ongoing.expectations[i], in: m), m.ongoing.intentions[j].isLive {
                fx += settle(j, .dropped, &m)
            }
        }
        return fx
    }

    /// Adds an intention (persisted), keeping ≤ 16 live (the lowest priority is dropped).
    mutating func add(_ it: Intention, _ m: inout Moment) -> [Effect] {
        m.ongoing.intentions.append(it)
        var fx: [Effect] = [.persist(.intention(it))]
        while m.ongoing.intentions.filter(\.isLive).count > Ongoing.maxOpenIntentions {
            let live = m.ongoing.intentions.indices.filter { m.ongoing.intentions[$0].isLive }
            guard let i = live.min(by: { (m.ongoing.intentions[$0].priority, m.ongoing.intentions[$0].created.timeIntervalSince1970)
                < (m.ongoing.intentions[$1].priority, m.ongoing.intentions[$1].created.timeIntervalSince1970) }) else { break }
            fx += settle(i, .dropped, &m)
        }
        return fx
    }

    /// Done or dropped, silently; a follow-up's expectation follows a drop.
    mutating func settle(_ i: Int, _ status: Intention.Status, _ m: inout Moment) -> [Effect] {
        m.ongoing.intentions[i].status = status
        m.ongoing.intentions[i].updated = m.now
        var fx: [Effect] = [.persist(.intention(m.ongoing.intentions[i]))]
        if status == .dropped, let x = Self.expectation(for: m.ongoing.intentions[i], in: m), m.ongoing.expectations[x].status == .pending {
            m.ongoing.expectations[x].status = .expired
            fx.append(.persist(.expectation(m.ongoing.expectations[x])))
        }
        return fx
    }

    // MARK: Boundaries

    /// Active user boundaries of `person` (or of the identified speaker for person-less intentions).
    static func boundaries(_ m: Moment, person: PersonID?) -> [Subject] {
        guard let p = person ?? m.ongoing.person else { return [] }
        return m.enduring.boundaries.filter { $0.person == p && $0.owner == .user && $0.active }.map(\.topic)
    }

    func isAvoided(_ s: Subject, person: PersonID?, _ m: Moment) -> Bool {
        forgotten.contains { $0.overlaps(s) } || Self.boundaries(m, person: person).contains { $0.overlaps(s) }
    }

    func avoidSet(_ m: Moment) -> Set<String> {
        Set(Self.boundaries(m, person: nil).map(\.text) + forgotten.map(\.text))
    }

    /// Live intentions on a topic the user asked her not to bring up are dropped silently.
    mutating func dropBoundaryTopics(_ m: inout Moment) -> [Effect] {
        var fx: [Effect] = []
        for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].isLive {
            let it = m.ongoing.intentions[i]
            let blocked = (it.person.map { Self.boundaries(m, person: $0) } ?? Self.boundaries(m, person: nil)).contains { $0.overlaps(it.subject) }
            if blocked { fx += settle(i, .dropped, &m) }
        }
        return fx
    }

    // MARK: Outcome (§7.5)

    mutating func outcome(text: String, appraisal: Appraisal, _ m: inout Moment) -> [Effect] {
        var fx: [Effect] = []
        if let id = awaitingOutcome, let x = m.ongoing.expectations.firstIndex(where: { $0.id == id && $0.status == .asked }) {
            awaitingOutcome = nil
            fx += resolve(x, valence: appraisal.valence, &m)
            return fx
        }
        // Unprompted: they bring it up first, once it has happened.
        guard let person = m.ongoing.person else { return fx }
        let lowered = text.lowercased()
        for x in m.ongoing.expectations.indices {
            let e = m.ongoing.expectations[x]
            guard e.person == person, e.status == .pending, m.now >= e.due, Self.mentions(lowered, e.subject) else { continue }
            if let j = Self.followUp(for: e, in: m), m.ongoing.intentions[j].isLive { fx += settle(j, .done, &m) }
            fx += resolve(x, valence: appraisal.valence, &m)
            return fx
        }
        // "It went really well!" without the subject: the one due expectation of theirs
        // (Interpreter's signal normally got here first; this is the fallback).
        guard Interpreter.OutcomeReport.detect(text) else { return fx }
        let due = m.ongoing.expectations.indices.filter { i in
            let e = m.ongoing.expectations[i]
            return e.person == person && (e.status == .asked || (e.status == .pending && m.now >= e.due))
        }
        guard due.count == 1, let x = due.first else { return fx }
        if let j = Self.followUp(for: m.ongoing.expectations[x], in: m), m.ongoing.intentions[j].isLive { fx += settle(j, .done, &m) }
        if awaitingOutcome == m.ongoing.expectations[x].id { awaitingOutcome = nil }
        fx += resolve(x, valence: appraisal.valence - 0.5 * appraisal.distress, &m)
        return fx
    }

    /// "How did it go?" asks a follow-up without naming its subject.
    static let howDidItGo = ["how did it go", "how'd it go", "how did that go", "how was it", "how did it all go", "how did everything go",
                             "how'd that go", "how did you get on", "how did you do"]

    mutating func resolve(_ x: Int, valence: Double, _ m: inout Moment) -> [Effect] {
        let v = clamp(valence, -1, 1)
        m.ongoing.expectations[x].outcomeValence = v
        m.ongoing.expectations[x].status = .resolved
        let e = m.ongoing.expectations[x]
        var fx: [Effect] = [.persist(.expectation(e))]
        if e.framing == .nervous, v > 0.2 { fx.append(.appraise(.internal(relief: 0.3 + 0.5 * v))) }
        // Tell long-term memory how it went, so later conversations don't ask again.
        let outcome = v > 0.1 ? "went well" : v < -0.1 ? "didn't go well" : "is over"
        fx.append(.remember(ExtractedFact(text: "their \(e.subject.text) \(outcome)", category: .event), person: e.person))
        m.signal("followUpResolved", subject: e.subject, value: v, id: e.id, label: e.framing.rawValue, by: Self.name)
        return fx
    }

    // MARK: Follow-through (§7.6)

    mutating func followThrough(_ reply: String, _ m: inout Moment) -> [Effect] {
        let aimed = aimedThisTurn
        aimedThisTurn = []
        var fx: [Effect] = []
        for id in aimed {
            guard let i = m.ongoing.intentions.firstIndex(where: { $0.id == id }), m.ongoing.intentions[i].status == .issued else { continue }
            let it = m.ongoing.intentions[i]
            // The gentle follow-up does not name its subject ("Gently ask how they've been
            // feeling."), so any question in the reply asked it (review finding 11).
            let gentleAsked = it.kind == .followUp && (Self.isGentle(it) ? reply.contains("?") : Self.howDidItGo.contains { reply.contains($0) })
            // "How did the dentist go?" names the dentist appointment by its first word (tune 4).
            let namedAsked = it.kind == .followUp && reply.contains("?") && Self.mentionsAnyWord(reply, it.subject)
            if Self.mentions(reply, it.subject) || gentleAsked || namedAsked {
                fx += stepDone(i, &m)
                if it.kind == .followUp, let x = Self.expectation(for: it, in: m), m.ongoing.expectations[x].status == .pending {
                    m.ongoing.expectations[x].status = .asked
                    awaitingOutcome = m.ongoing.expectations[x].id
                    fx.append(.persist(.expectation(m.ongoing.expectations[x])))
                }
            } else if it.issuedCount >= Intention.maxIssues {
                fx += settle(i, .dropped, &m)
            }
        }
        return fx
    }

    /// One step of an intention done: more steps reopen it (after a rest), the last one
    /// completes it (pride for self-motivated work).
    mutating func stepDone(_ i: Int, _ m: inout Moment) -> [Effect] {
        m.ongoing.intentions[i].stepsDone += 1
        let it = m.ongoing.intentions[i]
        if it.stepsDone < it.stepsNeeded {
            m.ongoing.intentions[i].status = .open
            m.ongoing.intentions[i].issuedCount = 0
            m.ongoing.intentions[i].notBefore = m.now.addingTimeInterval(Self.stepRest)
            m.ongoing.intentions[i].updated = m.now
            issuedAtTurn[it.id] = nil
            return [.persist(.intention(m.ongoing.intentions[i]))]
        }
        var fx = settle(i, .done, &m)
        m.signal("intentionDone", subject: it.subject, id: it.id, label: it.kind.rawValue, by: Self.name)
        switch it.kind {
        case .learn:
            fx.append(.appraise(.internal(pride: Self.learnPride)))
            if !shareQueue.contains(it.subject) { shareQueue.append(it.subject) }
        case .share: fx.append(.appraise(.internal(pride: Self.sharePride)))
        case .skill: fx.append(.appraise(.internal(pride: Self.skillPride)))
        default: break
        }
        return fx
    }

    // MARK: Self-motivated intentions

    static func selfMotivatedLive(_ m: Moment) -> Int { m.ongoing.intentions.filter { $0.isLive && $0.isSelfMotivated }.count }

    func mayBeBorn(_ m: Moment) -> Bool {
        Self.selfMotivatedLive(m) < Ongoing.maxSelfMotivated && (lastBirth.map { m.now.timeIntervalSince($0) >= Self.birthSpacing } ?? true)
    }

    /// What she knows about `s`: the `facts` signal, else episodes on the subject.
    func known(_ s: Subject, _ m: Moment) -> Int {
        let facts = knownFacts.filter { $0.subject.overlaps(s) }.map(\.count).max() ?? 0
        let episodes = m.enduring.episodeIndex.filter { $0.topics.contains { $0.overlaps(s) } }.count
        return max(facts, episodes)
    }

    /// At most one birth per call (and per 24 h): skill, then share, then learn.
    mutating func birthSelfMotivated(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        guard mayBeBorn(m) else { return [] }
        let now = m.now
        let live = m.ongoing.intentions.filter(\.isLive)
        func taken(_ s: Subject, _ kind: Intention.Kind, _ person: PersonID?) -> Bool {
            live.contains { $0.kind == kind && $0.subject.overlaps(s) && $0.person == person } || isAvoided(s, person: person, m)
                || (kind != .skill && SensitiveSubjects.contains(s))   // no "learn more about chemo" (finding 21)
        }
        var born: Intention?
        // Skill: ≥ 2 misreads of one situation with one person in 7 days.
        var seen: [Misread] = []
        for mr in m.ongoing.recentMisreads + misreadsThisConversation where !seen.contains(where: { $0.id == mr.id }) { seen.append(mr) }
        let recent = seen.filter { $0.person != nil && now.timeIntervalSince($0.at) <= Self.skillWindow && $0.at <= now }
        var groups: [(PersonID, Lesson.Situation)] = []
        for mr in recent.sorted(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) {
            guard let p = mr.person, !groups.contains(where: { $0.0 == p && $0.1 == mr.situation }) else { continue }
            groups.append((p, mr.situation))
        }
        for (p, situation) in groups where recent.filter({ $0.person == p && $0.situation == situation }).count >= Self.skillMisreads {
            let subject = Self.skillSubject(situation)
            guard !taken(subject, .skill, p) else { continue }
            born = Intention(id: rng.uuid(), kind: .skill, subject: subject, person: p, reason: "I keep misreading them",
                             notBefore: now, expires: now.addingTimeInterval(Self.skillLifetime), priority: Self.skillPriority,
                             stepsNeeded: Self.skillSteps, source: "misread", created: now)
            break
        }
        if born == nil, let s = shareQueue.first(where: { !taken($0, .share, nil) }) {
            shareQueue.removeAll { $0 == s }
            born = Intention(id: rng.uuid(), kind: .share, subject: s, person: nil, reason: "I've been learning about it",
                             notBefore: now, expires: now.addingTimeInterval(Self.shareLifetime), priority: Self.sharePriority,
                             source: "interest", created: now)
        }
        if born == nil {
            let interests = m.ongoing.interests
                .filter { $0.weight > Self.learnInterest }
                .sorted { ($0.weight, $1.subject.text) > ($1.weight, $0.subject.text) }
            for i in interests where known(i.subject, m) < Self.learnKnownFacts && !taken(i.subject, .learn, nil) {
                born = Intention(id: rng.uuid(), kind: .learn, subject: i.subject, person: nil, reason: "I'm curious and know little about it",
                                 notBefore: now, expires: now.addingTimeInterval(Self.learnLifetime), priority: Self.learnPriority,
                                 stepsNeeded: Self.learnSteps, source: "interest", created: now)
                break
            }
        }
        guard let it = born else { return [] }
        lastBirth = now
        return add(it, &m)
    }

    public static func skillSubject(_ s: Lesson.Situation) -> Subject {
        switch s {
        case .moodGuess: Subject("reading their mood")!
        case .tookLiterally: Subject("spotting their jokes")!
        case .wrongReferent: Subject("following their pointing")!
        case .interruptedThem: Subject("waiting my turn")!
        case .jokeFlopped: Subject("reading the room")!
        case .askedTooMuch: Subject("giving them space")!
        }
    }

    static func skillSituation(_ s: Subject) -> Lesson.Situation? {
        Lesson.Situation.allCases.first { skillSubject($0) == s }
    }

    /// Closing a conversation: each skill whose person took part without a repeat of
    /// that misread advances one clean conversation.
    mutating func closeConversation(_ m: inout Moment) -> [Effect] {
        guard userTurnsThisConversation > 0 else { return [] }
        let start = m.ongoing.conversationStarted
        var fx: [Effect] = []
        for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].kind == .skill && m.ongoing.intentions[i].isLive {
            let it = m.ongoing.intentions[i]
            guard let p = it.person, peopleThisConversation.contains(p), let situation = Self.skillSituation(it.subject) else { continue }
            let slipped = (misreadsThisConversation + m.ongoing.recentMisreads.filter { $0.at >= start })
                .contains { $0.person == p && $0.situation == situation }
            guard !slipped else { continue }
            fx += stepDone(i, &m)
        }
        return fx
    }

    // MARK: Options and scoring

    /// `p = priority × relevance × timing × (0.5 + urgeToTalk)` (§7.6).
    public static func score(priority: Double, relevance: Double, timing: Double, urge: Double) -> Double {
        clamp01(priority) * clamp01(relevance) * clamp01(timing) * (0.5 + clamp01(urge))
    }

    /// Subject words of the current topic and focus.
    static func inPlay(_ m: Moment) -> [Subject] {
        var out = m.ongoing.topic
        switch m.momentary.focus {
        case .referent(let s, _), .sound(let s): out.append(s)
        default: break
        }
        return out
    }

    /// 1 for a subject match, 0.6 for a person match, 0.3 otherwise.
    static func relevance(_ it: Intention, _ m: Moment) -> Double {
        if it.kind == .repair { return relevanceSubject }
        if inPlay(m).contains(where: { $0.overlaps(it.subject) }) { return relevanceSubject }
        if let p = m.ongoing.person, it.person == p || it.person == nil { return relevancePerson }
        return relevanceOther
    }

    struct Option {
        var note: Note
        var score: Double
        var candidate: CuriosityDirector.Candidate?
        var paced: Bool
        var order: String
    }

    /// The board's intentions that may be aimed now.
    func eligible(_ it: Intention, _ m: Moment, userTurn: Bool, replyPending: Bool = false) -> Bool {
        let now = m.now
        guard it.isLive, it.kind != .skill, now >= it.notBefore, now < it.expires, it.issuedCount < Intention.maxIssues else { return false }
        if it.status == .issued {
            if aimedThisTurn.contains(it.id) { return false }
            if let at = issuedAtTurn[it.id], turn - at < Self.reissueAfterTurns { return false }
        }
        if let p = it.person, p != m.ongoing.person { return false }
        if isAvoided(it.subject, person: it.person, m) { return false }
        switch m.ongoing.repair {
        case .ruptured, .repairing: if it.kind != .repair { return false }
        default: break
        }
        if it.kind == .followUp {
            guard let x = Self.expectation(for: it, in: m), m.ongoing.expectations[x].status == .pending else { return false }
            // A reply being built is their turn even before its words arrive (fast mode).
            guard m.ongoing.turnsThisConversation >= 1 || replyPending else { return false }
            if m.ongoing.followUpsThisConversation > 0, !followedUpThisConversation.contains(it.id) { return false }
            // The arrival grace keeps her from pouncing as they walk in; once they have
            // spoken, their first turn is the natural place to ask (with the reunion note).
            if !userTurn, let a = arrivedAt, now.timeIntervalSince(a) < Self.arrivalGrace { return false }
        }
        return true
    }

    func note(for it: Intention, _ m: Moment) -> Note {
        switch it.kind {
        case .followUp:
            let x = Self.expectation(for: it, in: m).map { m.ongoing.expectations[$0] }
            let gentle = Self.isGentle(it)
            return .followUp(it.subject, framing: x?.framing ?? .neutral, gentle: gentle, intention: it.id)
        default:
            return .intention(nextAction: Self.action(for: it), intention: it.id)
        }
    }

    public static func isHealth(_ s: Subject) -> Bool { s.words.contains { healthWords.contains($0) } }

    static func isGentle(_ it: Intention) -> Bool {
        isHealth(it.subject) || (it.reason == healthReason && !isOrdinaryAppointment(it.subject))
    }

    public static func isOrdinaryAppointment(_ s: Subject) -> Bool { s.words.contains { ordinaryAppointmentWords.contains($0) } }

    /// The aim's wording for a non-follow-up intention (≤ 88 characters).
    public static func action(for it: Intention) -> String {
        let s = it.subject.text
        switch it.kind {
        case .learn: return "Ask one short question to learn more about \(s)."
        case .share: return "Share one small thought you've had about \(s)."
        case .ask, .followUp: return "Ask one short question about \(s)."
        case .repair: return "Make things right with them, briefly and warmly."
        case .ritual: return "Do your usual \(s), briefly."
        case .skill: return "Take your time reading them before you answer."
        }
    }

    /// A curiosity candidate's stage direction as an aim (≤ 88 characters).
    public static func action(for c: CuriosityDirector.Candidate) -> String {
        var body = c.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("(") { body.removeFirst() }
        if body.hasSuffix(")") { body.removeLast() }
        if body.hasSuffix(" One short sentence.") { body = String(body.dropLast(" One short sentence.".count)) }
        body = body.trimmingCharacters(in: .whitespaces)
        if !body.isEmpty, body.count <= maxAction { return body }
        let label = NoteTemplates.fit(c.label, 30)
        switch c.kind {
        case .sight: return "Ask one short question about the \(label) you just noticed."
        case .sound, .callout: return "Ask your human what that \(label) sound was."
        case .touch: return "React out loud to how your human is touching you."
        case .music: return "Mention the \(label) you can hear and ask about it."
        case .greeting: return "Say hello; you're glad to see them."
        case .human: return "Ask your human one friendly question about their day."
        case .game: return "Suggest a quick little game."
        case .thought: return "Share one small thought of your own."
        case .feeling: return "Tell them you're glad of their company."
        }
    }

    static func isGeneral(_ k: CuriosityDirector.Candidate.Kind) -> Bool {
        switch k {
        case .human, .game, .thought, .feeling: true
        default: false
        }
    }

    /// The board's options for a user turn (`userTurn`) or for initiative.
    mutating func options(_ m: Moment, userTurn: Bool) -> [Option] {
        let urge = m.ongoing.mind.urgeToTalk
        let timingIdle = lastSpeechAt.map { m.now.timeIntervalSince($0) >= Self.quietAfterSpeech } ?? true
        var out: [Option] = []
        for it in m.ongoing.intentions where eligible(it, m, userTurn: userTurn) {
            let priority = it.kind == .repair ? 1 : it.priority
            let timing = userTurn ? 1.0 : (timingIdle ? 1 : 0)
            let p = Self.score(priority: priority, relevance: Self.relevance(it, m), timing: timing, urge: urge)
            out.append(Option(note: note(for: it, m), score: p, candidate: nil, paced: true, order: "0" + it.subject.text + "|" + it.id.uuidString))
        }
        switch m.ongoing.repair {
        case .ruptured, .repairing: return out
        default: break
        }
        let busy: Bool = { if case .idle = m.momentary.floor { false } else { true } }()
        let candidates = director.candidates(at: m.now, snapshot: m.ongoing.mind, userPresent: present, busy: !userTurn && busy)
        let topical = Self.inPlay(m)
        for c in candidates where c.kind != .callout {
            if userTurn, Self.isGeneral(c.kind) || c.kind == .greeting { continue }
            if let s = Subject(c.label), isAvoided(s, person: nil, m) { continue }
            let general = Self.isGeneral(c.kind) || c.kind == .music
            let matches = Subject(c.label).map { s in topical.contains { $0.overlaps(s) } } ?? false
            let aboutThem = [.greeting, .human, .feeling].contains(c.kind)
            let personFocus: Bool = { if case .person = m.momentary.focus { true } else { false } }()
            let relevance = matches || (aboutThem && personFocus) ? Self.relevanceSubject : (present ? Self.relevancePerson : Self.relevanceOther)
            // General topics sit on the director's 0.1…0.55 scale; once due (urgency 1)
            // they are a moderate want on the board's scale.
            let priority = general ? min(0.9, 0.5 + c.priority) : c.priority
            let timing = userTurn ? 1 : c.urgency
            let p = Self.score(priority: priority, relevance: relevance, timing: timing, urge: urge)
            let note = Note(.intention, slots: [Self.action(for: c)])
            out.append(Option(note: note, score: p, candidate: c, paced: general, order: "1" + c.subject))
        }
        return out.sorted { ($0.score, $1.order) > ($1.score, $0.order) }
    }

    /// Gives a curiosity option a fresh id and remembers its candidate (≤ 4 pending).
    mutating func bind(_ o: Option, _ rng: inout Rand) -> Note {
        guard let c = o.candidate else { return o.note }
        var n = o.note
        let id = rng.uuid()
        n.intention = id
        curiosityAims.append((id, c))
        if curiosityAims.count > 4 { curiosityAims.removeFirst(curiosityAims.count - 4) }
        return n
    }

    // MARK: Aim on a user turn

    mutating func raiseAim(_ m: inout Moment, _ rng: inout Rand) {
        // A due follow-up is the aim of the first reply it can ride on, whatever the
        // score (tune 3: live it lost to the threshold or never got a cue).
        if let it = dueFollowUp(m, replyPending: false) {
            m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.intention == it.id }
            m.ongoing.raise(note(for: it, m), by: Self.name)
            return
        }
        guard let best = options(m, userTurn: true).first, best.score > Self.aimThreshold else { return }
        let n = bind(best, &rng)
        m.ongoing.raise(n, by: Self.name)
    }

    /// The due follow-up of the identified speaker that may be asked on this reply.
    func dueFollowUp(_ m: Moment, replyPending: Bool) -> Intention? {
        guard let person = m.ongoing.person else { return nil }
        return m.ongoing.intentions
            .filter { $0.kind == .followUp && $0.person == person && eligible($0, m, userTurn: true, replyPending: replyPending) }
            .min { ($0.notBefore, $0.id.uuidString) < ($1.notBefore, $1.id.uuidString) }
    }

    /// `.promptSubmitted`: a reply's notes are picked now, in fast mode before `.heard`.
    /// The due follow-up rides on it (with the reunion note) instead of waiting for a
    /// cue that never comes (tune 2 live: exam and dentist both missed).
    mutating func raiseDueFollowUp(_ m: inout Moment) {
        guard present, !asleep, let it = dueFollowUp(m, replyPending: true) else { return }
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.intention == it.id }
        m.ongoing.raise(note(for: it, m), by: Self.name)
        preAim = it.id
    }

    /// A reply that ended with no sentence heard (cancelled, refused, superseded) asked
    /// nothing: its aims are given back as they were, so the next reply can carry them.
    mutating func undeliveredReply(_ m: inout Moment) -> [Effect] {
        let undo = issueUndo
        issueUndo = [:]
        aimedThisTurn = []
        var fx: [Effect] = []
        for (id, u) in undo.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let i = m.ongoing.intentions.firstIndex(where: { $0.id == id }), m.ongoing.intentions[i].status == .issued else { continue }
            m.ongoing.intentions[i].status = u.status
            m.ongoing.intentions[i].issuedCount = max(0, m.ongoing.intentions[i].issuedCount - 1)
            m.ongoing.intentions[i].updated = m.now
            issuedAtTurn[id] = u.issuedAt
            if u.newFollowUp, let k = followedUpThisConversation.firstIndex(of: id) {
                followedUpThisConversation.remove(at: k)
                m.ongoing.followUpsThisConversation = max(0, m.ongoing.followUpsThisConversation - 1)
            }
            fx.append(.persist(.intention(m.ongoing.intentions[i])))
        }
        return fx
    }

    // MARK: Initiative

    /// The threshold for speaking first now, or nil when she should not.
    func initiativeThreshold(_ m: Moment) -> Double? {
        let now = m.now
        let live = m.ongoing.hypotheses.filter { now < $0.expires }
        // "Not now" / "I'm busy" said out loud means not now (review finding 17).
        if live.contains(where: { $0.kind == .wantsQuiet || ($0.kind == .busy && $0.stated) }) { return nil }
        var t = live.contains(where: { $0.kind == .busy }) ? Self.busyInitiativeThreshold : Self.initiativeThreshold
        if let p = m.ongoing.person, m.enduring.lessons.contains(where: { $0.person == p && $0.situation == .askedTooMuch }) {
            t += Self.askedTooMuchPenalty
        }
        return t
    }

    /// Board and general topics wait out the (backed-off) spacing after an initiative.
    func paceAllows(_ now: Date) -> Bool {
        guard unansweredInitiatives < Self.unansweredLimit else { return false }
        guard let last = lastInitiativeAt else { return true }
        let gap = min(Self.maxInitiativeGap, Self.initiativeSpacing * pow(2, Double(max(0, unansweredInitiatives - 1))))
        return now.timeIntervalSince(last) >= gap
    }

    mutating func considerInitiative(_ m: inout Moment, _ rng: inout Rand) {
        initiativeAim = nil
        guard case .idle = m.momentary.floor, present, !asleep, m.momentary.mutualGazeSince != nil,
              let threshold = initiativeThreshold(m) else { return }
        let paced = paceAllows(m.now)
        guard let best = options(m, userTurn: false).first(where: { paced || !$0.paced }), best.score > threshold else { return }
        let n = bind(best, &rng)
        initiativeAim = n.intention
        m.momentary.requestInitiative(score: best.score, aim: n, by: Self.name)
    }

    // MARK: Text

    /// The reply mentions the subject: every word of it, or its last word (the head
    /// noun: "job interview" → "interview"), as whole words, plural tolerated.
    /// Any distinctive word of the subject (3+ letters, not "appointment"-like filler).
    static func mentionsAnyWord(_ reply: String, _ subject: Subject) -> Bool {
        let words = Set(reply.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0) })
        let filler: Set<String> = ["appointment", "appointments", "the", "and", "visit", "thing", "day"]
        return subject.words.contains { w in
            let bare = w.hasSuffix("'s") ? String(w.dropLast(2)) : w
            guard bare.count >= 3, !filler.contains(bare) else { return false }
            return words.contains(bare) || words.contains(bare + "'s") || words.contains(bare + "s")
        }
    }

    public static func mentions(_ reply: String, _ subject: Subject) -> Bool {
        let words = Set(reply.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0) })
        func has(_ w: String) -> Bool { words.contains(w) || words.contains(w + "s") || words.contains(w + "es") }
        let sw = subject.words
        if sw.allSatisfy(has) { return true }
        if let head = sw.last, head.count >= 3 { return has(head) }
        return false
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "intentions": m.ongoing.intentions
                .map { "\($0.kind.rawValue):\($0.subject.text):\($0.status.rawValue):\($0.issuedCount):\($0.stepsDone)/\($0.stepsNeeded)" }
                .joined(separator: ","),
            "expectations": m.ongoing.expectations
                .map { "\($0.subject.text):\($0.status.rawValue)\($0.outcomeValence.map { String(format: ":%.2f", $0) } ?? "")" }
                .joined(separator: ","),
            "followUps": String(m.ongoing.followUpsThisConversation),
            "initiative": m.momentary.initiative.map { String(format: "%.2f", $0.score) } ?? "-",
            "candidates": m.ongoing.noteCandidates.filter { $0.owner == name }.map(\.kind.rawValue).joined(separator: ","),
        ]
    }
}
