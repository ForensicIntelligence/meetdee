import DeeCore
import DeeMemory
import DeeMind
import Foundation

/// Sub-reducer 4 — the tentative model of the user (SELF.md §7.4, §7.5, §10.3; steps
/// 0.5.3 / 0.5.5). Everything here reads the live utterance in RAM only; nothing it
/// raises, stores or signals carries user text — only lexicon values, ≤ 4-word
/// `Subject`s, ids and numbers.
///
/// Owns: `ongoing.person` (identity gate), `ongoing.hypotheses`, `ongoing.topic`,
/// `ongoing.misreadThisTurn`.
/// Reads: heard text + appraisal, head pose, gestures, floor events, referents,
/// expectations (IntentionBoard), lessons and profiles (Learner's published helpers).
///
/// **Identity gate (§10.3).** A person becomes `ongoing.person` only with a match within
/// DeeMemory's face threshold **and** either ≥ 3 consecutive matches of that id or a
/// name confirmation this conversation. Until the app has a percept for it, a name
/// confirmation is `.identified(id, distance: 0)` (`nameConfirmedDistance`: the app sends
/// it after `MemoryStore.confirm` named the speaker; a face match is never exactly 0).
/// The current person is cleared only after 3 identifications in a row that are not
/// theirs (one bad frame never flaps it); a different person needs the same 3-match gate
/// to take over, and a switch between two known people drops the old hypotheses.
///
/// **Hypotheses (§7.4)**, one per kind, each with evidence and an expiry:
/// - *mood, inferred* from the appraisal: distress → "sad" (or "stressed" when loud or
///   intense), quiet and slow speech → "tired", strong humour / valence → "happy".
///   Confidence `(0.35 + 0.1·evidence) × moodInferenceGain`, capped at 0.7; the same
///   value again adds evidence; expires 20 min after the last evidence. A value the
///   user corrected is not inferred again for 20 min.
/// - *mood, stated* ("I'm tired", "I feel a bit down", "…, just tired"): confidence 1.0
///   for 30 min; it overrides inference while live. A stated value equal to the live
///   inferred one is a confirmation — Learner sees it in the hypothesis diff (+0.02 gain).
/// - *busy*: three replies of < 3 words in a row (evidence = streak), or stated ("not
///   now", "I'm busy": 1.0). *wantsQuiet*: the palm gesture (+3 evidence), looking away
///   (|yaw| > 30°) during 2 Dee turns in a row, or stated ("shh", "be quiet"). Both
///   expire after 10 min; a reply of ≥ 8 words clears the inferred ones.
/// - *goal*: "look / check this out / I made…" → shareCreation, "can you…" → task,
///   "guess what…" → news; 0.6, 5 min, cleared at the next conversation.
///
/// **Hypothesis note** `(Maybe they're {value}; don't assume.)`: raised on a user turn
/// for an inferred mood / busy / wantsQuiet hypothesis with confidence ≥ 0.5 × gain —
/// after a moodGuess lesson ≥ max(0.6, 0.5 × gain), so a corrected guess at 0.55 stays
/// silent (§12.4 scenario 3) — and re-raised each turn until issued, then once per
/// value per conversation. (Learner raises the lesson notes.)
///
/// **Corrections (§7.4):** "I'm not X", "I'm fine" (against an inferred distress or
/// tired guess), "no, I meant", "I was joking", "that's not what I said", "you
/// misunderstood", or the same question asked again within 60 s after Dee answered it.
/// The matching hypothesis goes to confidence 0, uncertainty 0.8 is requested until Dee
/// finishes her next reply (≤ 20 s), and — for a mood guess (`moodGuess`) or a joke taken
/// literally (`tookLiterally`, "not serious") — a misread note is raised and
/// `misreadThisTurn` is set (Learner records and persists it and applies gain × 0.85;
/// RepairKeeper adds awkwardness). A stated mood that merely differs from a guess
/// counts as a misread only when the guess was voiced (its note issued). Attention's
/// `"misread"` signal (`wrongReferent`) is recorded as `misreadThisTurn` too. Review
/// finding 8: every mood misread needs the guess to have been voiced (its hypothesis note
/// issued; for "no, I meant…" in her last reply); an unvoiced guess is zeroed silently,
/// with the uncertainty but no misread note or record. "Happy" never gets a note, and a
/// short answer to her own yes/no question does not count toward busy.
///
/// **turnDistress:** a user turn appraised at distress ≥ 0.3 sets `Ongoing.turnDistress`
/// (until their next turn, ≤ 10 min), so `distressLive` gates play and topical notes from
/// the first sad turn (review finding 5).
///
/// **Topic (lexical, deterministic; no NaturalLanguage):** referent labels the user
/// mentions, plan subjects, and up to two content words after "my / the / a / about…",
/// singularised; ≤ 3, newest last.
///
/// **PlanDetector (§7.5):** future-event patterns ("I have / I've got / I'm going to /
/// my … exam|interview|appointment|…", "I'm going to finish …") with a deterministic
/// lexical date parser (NSDataDetector resolves relative dates against the wall
/// clock, so it is not used) in `utcOffset` local time: a weekday or "tomorrow" without
/// a time is due at 17:00 (the follow-up waits until 19:00), "tonight" 20:00, no date →
/// now + 1 d and the label "+undated" (IntentionBoard gives it a dormant follow-up).
/// Negated or cancelled events ("I have no meeting") are not plans. Framing from words,
/// then the appraisal (distress → nervous, joy → excited). For an identified person
/// and a subject not already pending, it raises the `"plan"` signal; IntentionBoard
/// owns expectations and intentions and builds both with `Interpreter.plan(from:)`,
/// `Plan.expectation(id:person:)` and `Plan.followUp(id:person:now:)`.
///
/// **Expectation checks (§7.5):** on the user turn after a follow-up was asked
/// (`status == .asked`), or when the user mentions a pending subject after its due
/// time (unprompted), `"expectationOutcome"` (id, subject, value = outcome valence,
/// label "asked" / "unprompted"), once per expectation. An outcome report that does not
/// name the subject (`OutcomeReport`: "it went really well", "I didn't get it", "they want
/// a second round") counts when exactly one of their expectations is due or asked.
///
/// **RepairDetector (§7.8)** shares RepairKeeper's public phrase helpers, so both
/// detect identically (RepairKeeper deduplicates). Only Interpreter resolves a pronoun
/// ("don't ask me about it"): this turn's newest topic, else the newest topic of the
/// last two turns, else nothing; "don't mention it" is never a boundary. Signals:
/// `"reconciliationBid"` (label),
/// `"userBoundary"` / `"userBoundaryLifted"` (subject), and `"hostility"` (value =
/// hostility after the tookLiterally softening, label "teasing" when softened).
///
/// **adjust (pre-commit):** with a tookLiterally lesson for this person
/// (`Learner.hostilitySoftening`), a teasing turn's hostility is halved when the turn
/// itself is humorous (humor ≥ 0.2) or a play cue (laughter, a playful Dee sentence, a
/// humorous user turn) came within 30 s.
///
/// Signals raised: "plan", "expectationOutcome", "reconciliationBid", "userBoundary",
/// "userBoundaryLifted", "hostility", "correction" (label = what was corrected).
/// Signals read: "misread" (Attention), "laughter".
public struct Interpreter: SubReducer {
    public static let name = "Interpreter"

    // MARK: Constants

    /// DeeMemory's default face-match threshold.
    public static let identityThreshold: Float = FaceMatching().threshold
    /// Consecutive identifications that are not the current person before it is cleared.
    public static let missesToForgetIdentity = 3
    /// Consecutive matches of one id before it becomes the person (§10.3).
    public static let matchesToIdentify = 3
    /// `.identified(id, distance: ≤ this)` means "confirmed by name" (interim convention).
    public static let nameConfirmedDistance: Float = 0

    public static let moodExpiry: TimeInterval = 20 * 60
    public static let statedMoodExpiry: TimeInterval = 30 * 60
    public static let busyExpiry: TimeInterval = 10 * 60
    public static let goalExpiry: TimeInterval = 5 * 60
    public static let goalConfidence = 0.6
    /// A corrected value is not inferred again for this long.
    public static let correctedHold: TimeInterval = 20 * 60

    public static let shortReplyWords = 3
    public static let shortRepliesForBusy = 3
    public static let engagedWords = 8
    public static let lookAwayYaw = 30.0
    public static let lookAwayTurnsForQuiet = 2
    public static let palmEvidence = 3

    /// A distressed turn keeps `turnDistress` live this long (or until the next turn).
    public static let turnDistressHold: TimeInterval = 10 * 60
    /// A pronoun boundary ("don't ask me about it") resolves to a topic this recent.
    public static let pronounTopicTurns = 2

    public static let correctionUncertainty = 0.8
    public static let uncertaintyHold: TimeInterval = 20
    public static let repeatWindow: TimeInterval = 60
    public static let playCueWindow: TimeInterval = 30

    /// Inferred-mood cues.
    public static let distressCue = 0.3
    public static let quietLoudness = -0.4
    public static let slowRate = 1.5
    public static let happyHumor = 0.4
    public static let happyValence = 0.5

    // MARK: State (RAM only)

    /// Consecutive `.identified` results that were not the current person.
    public private(set) var identityMisses = 0
    /// The id the consecutive-match streak is counting.
    public private(set) var candidate: PersonID?
    public private(set) var candidateStreak = 0
    /// Ids confirmed by name this conversation.
    public private(set) var nameConfirmed: [PersonID] = []
    /// Hypothesis note slots issued this conversation (once per value).
    public private(set) var issuedHypotheses: [String] = []
    /// Offset of the user's local time from UTC (for plan dates). UTC by default; set
    /// through `Cortex(utcOffset:)` / `Cortex.setUTCOffset(_:)`.
    public internal(set) var utcOffset: TimeInterval
    /// User turns heard (monotonic) and the turn the newest topic was last mentioned.
    var userTurns = 0
    var topicTurn = 0
    /// The hypothesis slot voiced (note issued) since the last user turn.
    var voicedSinceTurn: String?
    /// Dee's last reply ended on a yes/no question: a short answer is not "busy".
    var deeAskedYesNo = false

    var shortStreak = 0
    var lookedAwayThisDeeTurn = false
    var lookAwayTurns = 0
    var lastQuestion: AskedQuestion?
    var deeRepliedSinceQuestion = false
    /// Mood values the user corrected, not inferred again until `until`.
    var corrected: [Timed<String>] = []
    var uncertainUntil: Date?
    var lastPlayCue: Date?
    /// The kind of the most recently inferred hypothesis (what a bare "no, I meant" corrects).
    var lastInferred: Hypothesis.Kind?
    var outcomeSignalled: [UUID] = []

    struct AskedQuestion: Sendable, Equatable {
        var key: UInt64
        var at: Date
    }

    public init(utcOffset: TimeInterval = 0) {
        self.utcOffset = utcOffset
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: Int(utcOffset)) ?? TimeZone(secondsFromGMT: 0)!
        return c
    }

    // MARK: - Reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var fx: [Effect] = []
        m.ongoing.hypotheses.removeAll { now >= $0.expires }
        corrected.removeAll { $0.live(at: now) == nil }

        let inbox = m.inbox(for: Self.name)
        for s in inbox where s.name == "laughter" { lastPlayCue = now }
        // Attention's correction ("no, the other one"): record it as this turn's misread.
        let attentionMisread = inbox.first { $0.name == "misread" && $0.label == Lesson.Situation.wrongReferent.rawValue }

        switch p {
        case .identified(let id, let distance):
            identify(id, distance, &m)
        case .partial:
            if m.momentary.floorEvents.contains(.userStarted) { m.ongoing.misreadThisTurn = nil }
        case .heard(let text, let duration, let loudness, let a):
            fx += heard(text, duration: duration, loudness: loudness, a, attentionMisread: attentionMisread != nil, &m, &rng)
        case .gesture(let g):
            if g.lowercased() == "palm" { infer(.wantsQuiet, "quiet", add: Self.palmEvidence, gain: 1, expiry: Self.busyExpiry, &m) }
        case .head(let yaw, _):
            if case .deeSpeaking = m.momentary.floor, abs(yaw) > Self.lookAwayYaw { lookedAwayThisDeeTurn = true }
        case .sound(let label, _):
            if Laughter.isLaughter(label) { lastPlayCue = now }
        case .deeSaid(let tag, _):
            if let tag, Self.playfulTags.contains(tag) { lastPlayCue = now }
        case .deeTurnFinished(let text):
            uncertainUntil = nil
            if lastQuestion != nil { deeRepliedSinceQuestion = true }
            deeAskedYesNo = Self.endsWithYesNoQuestion(text)
        default:
            break
        }

        if let s = attentionMisread, let id = s.id, m.ongoing.misreadThisTurn?.id != id {
            m.ongoing.misreadThisTurn = Misread(id: id, person: m.ongoing.person, at: now, situation: .wrongReferent,
                                                topic: s.subject, wrongGuess: nil)
        }

        if m.momentary.floorEvents.contains(.deeFinished) {
            if lookedAwayThisDeeTurn {
                lookAwayTurns += 1
                if lookAwayTurns >= Self.lookAwayTurnsForQuiet {
                    infer(.wantsQuiet, "quiet", evidence: lookAwayTurns, gain: 1, expiry: Self.busyExpiry, &m)
                }
            } else {
                lookAwayTurns = 0
            }
            lookedAwayThisDeeTurn = false
        }

        if let u = uncertainUntil {
            if now < u { m.momentary.requestUncertainty(Self.correctionUncertainty, by: Self.name) } else { uncertainUntil = nil }
        }
        if m.ongoing.hypotheses.count > Ongoing.maxHypotheses {
            m.ongoing.hypotheses = Array(m.ongoing.hypotheses.sorted { $0.confidence > $1.confidence }.prefix(Ongoing.maxHypotheses))
        }
        return fx
    }

    // MARK: Identity (§10.3)

    mutating func identify(_ id: PersonID?, _ distance: Float, _ m: inout Moment) {
        guard let id, distance.isFinite, distance <= Self.identityThreshold else {
            candidate = nil
            candidateStreak = 0
            identityMisses += 1
            if identityMisses >= Self.missesToForgetIdentity { m.ongoing.person = nil }
            return
        }
        if distance <= Self.nameConfirmedDistance, !nameConfirmed.contains(id) { nameConfirmed.append(id) }
        if candidate == id { candidateStreak += 1 } else { candidate = id; candidateStreak = 1 }
        if id == m.ongoing.person {
            identityMisses = 0
            return
        }
        if m.ongoing.person != nil { identityMisses += 1 }
        if candidateStreak >= Self.matchesToIdentify || nameConfirmed.contains(id) {
            if let old = m.ongoing.person, old != id { switchedPerson(&m) }
            m.ongoing.person = id
            identityMisses = 0
        } else if identityMisses >= Self.missesToForgetIdentity {
            m.ongoing.person = nil
        }
    }

    /// Another known person took over: what was read about the previous one is void.
    mutating func switchedPerson(_ m: inout Moment) {
        m.ongoing.hypotheses = []
        m.ongoing.misreadThisTurn = nil
        m.ongoing.turnDistress = nil
        issuedHypotheses = []
        voicedSinceTurn = nil
        shortStreak = 0
        lookAwayTurns = 0
        lastQuestion = nil
        corrected = []
        lastInferred = nil
    }

    // MARK: User turn

    mutating func heard(_ text: String, duration: Double, loudness: Double, _ a: Appraisal, attentionMisread: Bool,
                        _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        m.ongoing.misreadThisTurn = nil
        m.ongoing.turnDistress = a.distress >= Self.distressCue ? Timed(a.distress, until: now.addingTimeInterval(Self.turnDistressHold)) : nil
        // Each user turn re-evaluates the hypothesis note (a corrected guess must not
        // linger next to the misread note); it is re-raised below if still valid.
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .hypothesis }
        let u = Utterance(text)
        userTurns += 1
        let voiced = voicedSinceTurn
        voicedSinceTurn = nil
        let answeredYesNo = deeAskedYesNo
        deeAskedYesNo = false

        // Repair signals (hostility softened with the play cues *before* this turn). "It"
        // is this turn's newest topic, else the newest one of the last two turns
        // (review finding 7: never the oldest, never a stale one).
        let turnTopics = Topics.extract(u, referents: m.momentary.referents)
        let recent = userTurns - topicTurn <= Self.pronounTopicTurns ? m.ongoing.topic.last : nil
        for f in RepairDetector.read(text, appraisal: a, topic: turnTopics.last ?? recent) {
            switch f {
            case .bid(let label): m.signal("reconciliationBid", value: 1, label: label, by: Self.name)
            case .userBoundary(let s): m.signal("userBoundary", subject: s, by: Self.name)
            case .boundaryLifted(let s): m.signal("userBoundaryLifted", subject: s, by: Self.name)
            }
        }
        if a.hostility > 0 {
            let soft = Self.softenedHostility(a, softening: Learner.hostilitySoftening(m), playCue: playCueLive(at: now))
            m.signal("hostility", value: soft, label: soft < a.hostility ? "teasing" : "hostile", by: Self.name)
        }
        if a.humor >= 0.3 { lastPlayCue = now }

        let gain = m.profile.moodInferenceGain
        let reading = Reading(u)
        var moodHandled = false

        // Corrections and stated feelings.
        if !attentionMisread {
            moodHandled = correctAndState(reading, voiced: voiced, &m, &rng)
            if !moodHandled, reading.genericCorrection || isRepeatedQuestion(u, now: now) {
                genericCorrection(voiced: voiced, &m, &rng)
                moodHandled = true
            }
        }
        rememberQuestion(u, now: now)

        // Busy / quiet, stated.
        if reading.statedBusy { state(.busy, "busy", expiry: Self.busyExpiry, &m) }
        if reading.statedQuiet { state(.wantsQuiet, "quiet", expiry: Self.busyExpiry, &m) }

        // Inferred mood from the appraisal (stated feelings override).
        if !moodHandled, let value = Self.inferMood(a, words: u.words.count, duration: duration, loudness: loudness),
           !corrected.contains(where: { $0.value == value }) {
            infer(.mood, value, add: 1, gain: gain, expiry: Self.moodExpiry, &m)
        }

        // Busy from short replies; engagement clears the inferred busy / quiet.
        let wc = u.words.count
        // A short answer to her own yes/no question ("yeah", "nope") is not busy (finding 20).
        if !(answeredYesNo && wc < Self.shortReplyWords) {
            shortStreak = wc < Self.shortReplyWords ? shortStreak + 1 : 0
        }
        if shortStreak >= Self.shortRepliesForBusy {
            infer(.busy, "busy", evidence: shortStreak, gain: 1, expiry: Self.busyExpiry, &m)
        }
        if wc >= Self.engagedWords {
            m.ongoing.hypotheses.removeAll { !$0.stated && ($0.kind == .busy || $0.kind == .wantsQuiet) }
            lookAwayTurns = 0
        }

        // Goal.
        if let goal = reading.goal {
            m.ongoing.hypotheses.removeAll { $0.kind == .goal }
            m.ongoing.hypotheses.append(Hypothesis(kind: .goal, value: goal, confidence: Self.goalConfidence,
                                                   expires: now.addingTimeInterval(Self.goalExpiry)))
            lastInferred = .goal
        }

        // Plans, then topics, then expectation outcomes (not for a subject planned just now).
        let plan = PlanDetector.detect(u, appraisal: a, now: now, calendar: calendar)
        var topics = turnTopics
        if let plan { topics.insert(plan.subject, at: 0) }
        addTopics(topics, &m)
        if !topics.isEmpty { topicTurn = userTurns }
        if let plan, let person = m.ongoing.person,
           !m.ongoing.expectations.contains(where: { $0.person == person && Self.isOpen($0.status) && $0.subject.overlaps(plan.subject) }) {
            m.signal("plan", subject: plan.subject, value: plan.due.timeIntervalSinceReferenceDate, id: rng.uuid(),
                     label: plan.label, by: Self.name)
        }
        checkExpectations(u, a, planned: plan?.subject, &m)

        raiseHypothesisNote(gain: gain, &m)
        return []
    }

    /// Stated feelings and mood corrections. Returns true when the mood was handled
    /// (stated, or a mood guess corrected) so nothing is inferred this turn.
    /// A wrong guess is owned (misread note, misread record) only when Dee voiced it
    /// (its hypothesis note was issued): she cannot apologise for a guess she never
    /// said (review finding 8). An unvoiced one is zeroed silently, with the uncertainty.
    mutating func correctAndState(_ r: Reading, voiced: String?, _ m: inout Moment, _ rng: inout Rand) -> Bool {
        let inferred = m.ongoing.hypotheses.first { $0.kind == .mood && !$0.stated && $0.confidence > 0 }
        var handled = false

        if r.joking {
            misread(.tookLiterally, wrongGuess: "serious", &m, &rng)
            correctionSide(label: "joking", &m)
            return true
        }

        for n in r.negated {
            if n == "busy" {
                if m.ongoing.hypotheses.contains(where: { $0.kind == .busy }) {
                    m.ongoing.hypotheses.removeAll { $0.kind == .busy }
                    correctionSide(label: "busy", &m)
                }
                continue
            }
            if let h = inferred, h.value == n || (Self.isDistress(n) && h.isDistress) {
                corrected.append(Timed(h.value, until: m.now.addingTimeInterval(Self.correctedHold)))
                if let i = m.ongoing.hypotheses.firstIndex(of: h) { zero(i, &m) }
                if issuedHypotheses.contains(Self.noteSlot(h)) { misread(.moodGuess, wrongGuess: h.value, &m, &rng) }
                correctionSide(label: "mood", &m)
                handled = true
            }
        }

        guard let stated = r.stated.last else { return handled }
        if let h = inferred, m.ongoing.misreadThisTurn == nil, h.value != stated {
            let explicitFine = r.stated.contains("fine") && (h.isDistress || h.value == "tired")
            if issuedHypotheses.contains(Self.noteSlot(h)) {
                // "I'm fine" (or any other stated feeling) against a voiced guess.
                corrected.append(Timed(h.value, until: m.now.addingTimeInterval(Self.correctedHold)))
                misread(.moodGuess, wrongGuess: h.value, &m, &rng)
                correctionSide(label: "mood", &m)
            } else if explicitFine {
                // Against a guess she never said: not inferred again for a while, no apology.
                corrected.append(Timed(h.value, until: m.now.addingTimeInterval(Self.correctedHold)))
                correctionSide(label: "mood", &m)
            }
        }
        state(.mood, stated, expiry: Self.statedMoodExpiry, &m)
        return true
    }

    /// "No, I meant…", "you misunderstood", a repeated question: corrects the most
    /// recently inferred hypothesis (a mood guess is a misread).
    /// A mood guess is a misread only when it was voiced in Dee's last reply ("No, I
    /// meant the other movie" after an unvoiced guess just zeroes it).
    mutating func genericCorrection(voiced: String?, _ m: inout Moment, _ rng: inout Rand) {
        let kind = lastInferred
        if let kind, let i = m.ongoing.hypotheses.firstIndex(where: { $0.kind == kind && !$0.stated && $0.confidence > 0 }) {
            let h = m.ongoing.hypotheses[i]
            zero(i, &m)
            if kind == .mood {
                corrected.append(Timed(h.value, until: m.now.addingTimeInterval(Self.correctedHold)))
                if voiced == Self.noteSlot(h) { misread(.moodGuess, wrongGuess: h.value, &m, &rng) }
            }
            correctionSide(label: kind.rawValue, &m)
        } else {
            correctionSide(label: "generic", &m)
        }
    }

    mutating func zero(_ i: Int, _ m: inout Moment) {
        m.ongoing.hypotheses[i].confidence = 0
        m.ongoing.hypotheses[i].evidence = 0
    }

    /// Uncertainty until Dee has owned it, and the "correction" signal.
    mutating func correctionSide(label: String, _ m: inout Moment) {
        uncertainUntil = m.now.addingTimeInterval(Self.uncertaintyHold)
        m.momentary.requestUncertainty(Self.correctionUncertainty, by: Self.name)
        m.signal("correction", label: label, by: Self.name)
    }

    /// One misread per turn: `misreadThisTurn` (Learner records and persists it) and the note.
    mutating func misread(_ situation: Lesson.Situation, wrongGuess: String, _ m: inout Moment, _ rng: inout Rand) {
        guard m.ongoing.misreadThisTurn == nil else { return }
        m.ongoing.misreadThisTurn = Misread(id: rng.uuid(), person: m.ongoing.person, at: m.now, situation: situation,
                                            topic: m.ongoing.topic.last, wrongGuess: wrongGuess)
        m.ongoing.raise(.misread(notX: wrongGuess), by: Self.name)
    }

    func isRepeatedQuestion(_ u: Utterance, now: Date) -> Bool {
        guard u.isQuestion, u.words.count >= 2, let q = lastQuestion, deeRepliedSinceQuestion else { return false }
        return q.key == u.key && now.timeIntervalSince(q.at) <= Self.repeatWindow
    }

    mutating func rememberQuestion(_ u: Utterance, now: Date) {
        guard u.isQuestion, u.words.count >= 2 else { return }
        if lastQuestion?.key != u.key || !deeRepliedSinceQuestion {
            lastQuestion = AskedQuestion(key: u.key, at: now)
        } else {
            lastQuestion?.at = now
        }
        deeRepliedSinceQuestion = false
    }

    // MARK: Hypotheses

    /// A stated hypothesis (1.0) replacing any of its kind.
    mutating func state(_ kind: Hypothesis.Kind, _ value: String, expiry: TimeInterval, _ m: inout Moment) {
        m.ongoing.hypotheses.removeAll { $0.kind == kind }
        m.ongoing.hypotheses.append(Hypothesis(kind: kind, value: value, confidence: 1, stated: true,
                                               expires: m.now.addingTimeInterval(expiry)))
    }

    /// Adds inferred evidence (or sets it to `evidence`). A live stated hypothesis of the
    /// kind wins; a different value replaces the old guess.
    mutating func infer(_ kind: Hypothesis.Kind, _ value: String, evidence: Int? = nil, add: Int = 0, gain: Double,
                        expiry: TimeInterval, _ m: inout Moment) {
        let now = m.now
        if m.ongoing.hypotheses.contains(where: { $0.kind == kind && $0.stated && now < $0.expires }) { return }
        var e = evidence ?? add
        if evidence == nil, let old = m.ongoing.hypotheses.first(where: { $0.kind == kind && $0.value == value && $0.confidence > 0 }) {
            e += old.evidence
        }
        m.ongoing.hypotheses.removeAll { $0.kind == kind }
        m.ongoing.hypotheses.append(Hypothesis(kind: kind, value: value, confidence: Self.inferredConfidence(evidence: e, gain: gain),
                                               evidence: e, expires: now.addingTimeInterval(expiry)))
        lastInferred = kind
    }

    /// `(0.35 + 0.1·evidence) × gain`, capped at 0.7 (§7.4).
    public static func inferredConfidence(evidence: Int, gain: Double) -> Double {
        min(Hypothesis.maxInferredConfidence, (0.35 + 0.1 * Double(evidence)) * gain)
    }

    /// The hypothesis note's own gate: 0.5 × gain; after a moodGuess lesson at least 0.6.
    public static func noteThreshold(gain: Double, moodLesson: Bool) -> Double {
        moodLesson ? max(0.6, 0.5 * gain) : 0.5 * gain
    }

    /// The note slot for a hypothesis (lexicon only).
    public static func noteSlot(_ h: Hypothesis) -> String {
        switch h.kind {
        case .mood: h.value
        case .busy: "busy"
        case .wantsQuiet: "wanting some quiet"
        case .goal: h.value
        }
    }

    mutating func raiseHypothesisNote(gain: Double, _ m: inout Moment) {
        let moodLesson = Learner.lesson(.moodGuess, for: m.ongoing.person, in: m.enduring) != nil
        let now = m.now
        let ranked = m.ongoing.hypotheses
            .filter { !$0.stated && $0.kind != .goal && $0.confidence > 0 && now < $0.expires }
            .sorted { ($0.confidence, $0.kind.rawValue) > ($1.confidence, $1.kind.rawValue) }
        for h in ranked {
            let threshold = h.kind == .mood ? Self.noteThreshold(gain: gain, moodLesson: moodLesson) : Self.noteThreshold(gain: 1, moodLesson: false)
            let slot = Self.noteSlot(h)
            // "Maybe they're happy; don't assume." helps nobody (finding 20).
            guard h.confidence >= threshold, !issuedHypotheses.contains(slot), !Self.silentValues.contains(h.value) else { continue }
            m.ongoing.raise(.hypothesis(slot), by: Self.name)
            return
        }
    }

    /// Mood cues in one turn's appraisal and prosody (nil: no cue).
    public static func inferMood(_ a: Appraisal, words: Int, duration: Double, loudness: Double) -> String? {
        if a.distress >= distressCue { return a.intensity >= 0.5 || loudness >= 0.4 ? "stressed" : "sad" }
        let rate = Double(words) / max(0.3, duration)
        if words >= 3, loudness <= quietLoudness, rate < slowRate, abs(a.valence) < 0.4 { return "tired" }
        if a.humor >= happyHumor || a.valence >= happyValence { return "happy" }
        return nil
    }

    static func isDistress(_ value: String) -> Bool { Hypothesis.distressValues.contains(value) }

    /// Inferred values that never get a hypothesis note.
    static let silentValues: Set<String> = ["happy"]

    static let yesNoStarts: Set<String> = ["do", "does", "did", "are", "is", "was", "were", "can", "could", "will", "would",
                                           "should", "have", "has", "had", "shall", "may", "want", "wanna"]

    /// Her reply's last sentence is a yes/no question ("…. Are you busy?").
    static func endsWithYesNoQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("?") else { return false }
        let body = t.dropLast()
        let start = body.lastIndex(where: { ".!?\n".contains($0) }).map { body.index(after: $0) } ?? body.startIndex
        let first = body[start...].lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init)
        return first.map { yesNoStarts.contains($0) || $0.hasSuffix("n't") } ?? false
    }

    // MARK: Topic

    mutating func addTopics(_ topics: [Subject], _ m: inout Moment) {
        for t in topics {
            m.ongoing.topic.removeAll { $0 == t }
            m.ongoing.topic.append(t)
        }
        if m.ongoing.topic.count > Ongoing.maxTopic { m.ongoing.topic = Array(m.ongoing.topic.suffix(Ongoing.maxTopic)) }
    }

    // MARK: Expectations (§7.5)

    static func isOpen(_ s: Expectation.Status) -> Bool { s == .pending || s == .asked }

    mutating func checkExpectations(_ u: Utterance, _ a: Appraisal, planned: Subject?, _ m: inout Moment) {
        guard let person = m.ongoing.person else { return }
        let now = m.now
        let outcome = max(-1, min(1, a.valence - 0.5 * a.distress))
        for e in m.ongoing.expectations where e.person == person && !outcomeSignalled.contains(e.id) {
            if let planned, planned.overlaps(e.subject) { continue }
            let label: String
            if e.status == .asked {
                label = "asked"
            } else if e.status == .pending, now >= e.due, u.mentions(e.subject) {
                label = "unprompted"
            } else {
                continue
            }
            outcomeSignalled = Array((outcomeSignalled + [e.id]).suffix(32))
            m.signal("expectationOutcome", subject: e.subject, value: outcome, id: e.id, label: label, by: Self.name)
            return
        }
        // "It went really well actually!" names no subject: it is the outcome when exactly
        // one expectation of theirs is due (live transcript: the interview was asked about
        // twice after they had already said how it went).
        guard OutcomeReport.detect(u) else { return }
        let due = m.ongoing.expectations.filter { e in
            e.person == person && !outcomeSignalled.contains(e.id) && !(planned.map { $0.overlaps(e.subject) } ?? false)
                && (e.status == .asked || (e.status == .pending && now >= e.due))
        }
        guard due.count == 1, let e = due.first else { return }
        outcomeSignalled = Array((outcomeSignalled + [e.id]).suffix(32))
        m.signal("expectationOutcome", subject: e.subject, value: outcome, id: e.id,
                 label: e.status == .asked ? "asked" : "unprompted", by: Self.name)
    }

    /// An outcome report that does not name its subject: "it went really well", "nailed
    /// it", "I didn't get it", "they want a second round", "I got the job". Conservative:
    /// whole clauses of a reply about how something turned out, never a plan.
    public enum OutcomeReport {
        static let adverbs = "(?:really |so |very |pretty |quite |super |surprisingly |actually |totally |extremely |incredibly |reasonably |fairly |better than |way |all )*"
        static let verdicts = "(?:well|badly|great|fine|ok|okay|alright|all right|terribly|horribly|brilliantly|amazing|amazingly|awful|awfully|perfectly|smoothly|good|bad|poorly|wonderfully|fantastic|fantastically|better than expected|worse than expected|expected)"
        static let patterns: [NSRegularExpression] = [
            "\\b(?:it|that|everything|things|the whole thing|all) (?:all )?went \(adverbs)\(verdicts)\\b",
            "^went \(adverbs)\(verdicts)\\b",
            "\\b(?:it|that) (?:didn't|did not) go (?:very |so |too |that |all that )?(?:well|great|good|smoothly|to plan)\\b",
            "\\b(?:nailed|aced|smashed|crushed|killed|bombed|blew|botched|flunked|messed up|screwed up) it\\b",
            "\\b(?:i|we) (?:didn't|did not) get (?:it|the job|the part|the role|the position|the offer|the place|in)\\b",
            "\\b(?:i|we) got (?:the job|the part|the role|the position|the offer|an offer|the place|in|accepted|hired)\\b",
            "\\bthey (?:want|wanted|invited|asked|called)\\b.*\\b(?:second|third|final|next) (?:round|interview|stage)\\b",
            "\\bthey offered me\\b",
            "\\b(?:i|we) (?:passed|failed|won|lost)(?: it| the \\w+)?$",
            "^(?:it|that) was (?:really |so |pretty |a total |an absolute |a complete |such a |a |an |actually |kind of |honestly )*(?:great|amazing|awful|terrible|horrible|fine|okay|ok|good|bad|brilliant|fantastic|disaster|success|nightmare|breeze|wonderful)(?: actually| honestly)?$",
        ].map { try! NSRegularExpression(pattern: $0) }

        public static func detect(_ text: String) -> Bool { detect(Utterance(text)) }

        public static func detect(_ u: Utterance) -> Bool {
            for clause in u.clauses {
                // Leading filler ("oh", "yeah", "honestly") does not change the report.
                var ws = clause
                while let f = ws.first, fillers.contains(f) { ws.removeFirst() }
                let c = ws.joined(separator: " ")
                let r = NSRange(c.startIndex..., in: c)
                if patterns.contains(where: { $0.firstMatch(in: c, range: r) != nil }) { return true }
            }
            return false
        }

        static let fillers: Set<String> = ["oh", "well", "yeah", "yes", "so", "honestly", "actually", "hey", "and", "um", "uh", "dee",
                                           "wow", "ugh", "okay", "ok", "anyway", "but", "guess", "what"]
    }

    // MARK: Play cues and the adjust hook

    static let playfulTags: Set<Emotion> = [.playful, .mischievous, .giddy]

    static func isLaughter(_ label: String) -> Bool { Laughter.isLaughter(label) }

    func playCueLive(at now: Date) -> Bool {
        lastPlayCue.map { now.timeIntervalSince($0) <= Self.playCueWindow } ?? false
    }

    /// Hostility after the tookLiterally softening: × (1 − softening) when the turn is
    /// humorous or a play cue is live.
    public static func softenedHostility(_ a: Appraisal, softening: Double, playCue: Bool) -> Double {
        guard softening > 0, a.hostility > 0, playCue || a.humor >= 0.2 else { return a.hostility }
        return a.hostility * (1 - clamp01(softening))
    }

    public func adjust(_ a: inout Appraisal, _ m: Moment) {
        a.hostility = Self.softenedHostility(a, softening: Learner.hostilitySoftening(m), playCue: playCueLive(at: m.now))
    }

    // MARK: - Hooks

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.misreadThisTurn = nil
        m.ongoing.turnDistress = nil
        m.ongoing.topic = []
        m.ongoing.hypotheses.removeAll { $0.kind == .goal }
        issuedHypotheses = []
        voicedSinceTurn = nil
        deeAskedYesNo = false
        nameConfirmed = []
        shortStreak = 0
        lookedAwayThisDeeTurn = false
        lookAwayTurns = 0
        lastQuestion = nil
        deeRepliedSinceQuestion = false
        uncertainUntil = nil
        return []
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        if n.owner == Self.name, n.kind == .hypothesis, let slot = n.slots.first {
            if !issuedHypotheses.contains(slot) { issuedHypotheses.append(slot) }
            voicedSinceTurn = slot
        }
        return []
    }

    public mutating func forget(subject: Subject, _ m: inout Moment) {
        lastQuestion = nil
        outcomeSignalled.removeAll { id in !m.ongoing.expectations.contains { $0.id == id } }
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        if candidate == id {
            candidate = nil
            candidateStreak = 0
        }
        nameConfirmed.removeAll { $0 == id }
        if m.ongoing.person == nil { switchedPerson(&m) }
        outcomeSignalled.removeAll { o in !m.ongoing.expectations.contains { $0.id == o } }
    }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        if candidate == from { candidate = into }
        if nameConfirmed.contains(from) {
            nameConfirmed.removeAll { $0 == from }
            if !nameConfirmed.contains(into) { nameConfirmed.append(into) }
        }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        var fresh = Interpreter(utcOffset: utcOffset)
        fresh.identityMisses = identityMisses
        fresh.candidate = candidate
        fresh.candidateStreak = candidateStreak
        fresh.nameConfirmed = nameConfirmed
        self = fresh
    }

    // MARK: - Traces

    public static func slice(of m: Moment) -> [String: String] {
        let mine = m.momentary.signals.filter { $0.owner == name && $0.seq == m.seq }.map { s -> String in
            let parts = [s.subject?.text, s.label].compactMap { $0 }
            return parts.isEmpty ? s.name : "\(s.name)(\(parts.joined(separator: "|")))"
        }
        let uncertainty = m.momentary.uncertaintyRequests.filter { $0.owner == name }.map(\.value).max()
        return [
            "person": m.ongoing.person.map { String($0.uuidString.prefix(8)) } ?? "-",
            "hypotheses": m.ongoing.hypotheses.map {
                "\($0.kind.rawValue):\($0.value):\(String(format: "%.2f", $0.confidence))\($0.stated ? ":s" : "")"
            }.joined(separator: ","),
            "topic": m.ongoing.topic.map(\.text).joined(separator: ","),
            "misread": m.ongoing.misreadThisTurn.map { "\($0.situation.rawValue):\($0.wrongGuess ?? "-")" } ?? "-",
            "notes": m.ongoing.noteCandidates.filter { $0.owner == name }.map(\.text).joined(separator: " "),
            "signals": mine.joined(separator: ","),
            "uncertainty": uncertainty.map { String(format: "%.1f", $0) } ?? "-",
        ]
    }
}

// MARK: - Utterance (RAM only)

extension Interpreter {
    /// A tokenised utterance: lower-cased words with contractions normalised, split into
    /// clauses at punctuation. Lives only for the step that reads it.
    public struct Utterance: Sendable, Equatable {
        public let clauses: [[String]]
        public let words: [String]
        public let isQuestion: Bool
        /// Stable key of the normalised words (repeated-question check; never stored).
        public let key: UInt64
        let padded: String

        static let questionStarts: Set<String> = ["what", "where", "when", "why", "how", "who", "which", "can", "could", "do",
                                                  "does", "did", "is", "are", "will", "would", "should", "have", "has",
                                                  "what's", "where's", "who's", "how's"]
        static let contractions: [String: [String]] = [
            "im": ["i'm"], "ive": ["i've"], "dont": ["don't"], "didnt": ["didn't"], "cant": ["can't"], "thats": ["that's"],
            "wasnt": ["wasn't"], "youre": ["you're"], "ill": ["i'll"], "gonna": ["going", "to"], "wanna": ["want", "to"],
            "gotta": ["got", "to"], "ok": ["okay"], "k": ["okay"], "isnt": ["isn't"], "whats": ["what's"],
        ]

        public init(_ text: String) {
            let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            var clauses: [[String]] = []
            var current: [String] = []
            var token = ""
            func endToken() {
                let w = token.trimmingCharacters(in: CharacterSet(charactersIn: "'-:"))
                token = ""
                guard !w.isEmpty else { return }
                current += Self.contractions[w] ?? [w]
            }
            func endClause() {
                endToken()
                if !current.isEmpty { clauses.append(Self.merge(current)) }
                current = []
            }
            for ch in trimmed {
                if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" || ch == ":" {
                    token.append(ch)
                } else if ".,!?;\u{2014}()".contains(ch) {
                    endClause()
                } else {
                    endToken()
                }
            }
            endClause()
            self.clauses = clauses
            words = clauses.flatMap { $0 }
            isQuestion = trimmed.hasSuffix("?") || words.first.map { Self.questionStarts.contains($0) } ?? false
            key = StableHash.of(words.joined(separator: " "))
            padded = " " + clauses.map { $0.joined(separator: " ") }.joined(separator: " | ") + " "
        }

        static func merge(_ ws: [String]) -> [String] {
            var out: [String] = []
            var i = 0
            while i < ws.count {
                if i + 1 < ws.count, ws[i] == "i", ws[i + 1] == "am" { out.append("i'm"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "do", ws[i + 1] == "not" { out.append("don't"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "did", ws[i + 1] == "not" { out.append("didn't"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "that", ws[i + 1] == "is" { out.append("that's"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "i", ws[i + 1] == "will" { out.append("i'll"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "was", ws[i + 1] == "not" { out.append("wasn't"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "you", ws[i + 1] == "are" { out.append("you're"); i += 2; continue }
                if i + 1 < ws.count, ws[i] == "i", ws[i + 1] == "have", i + 2 < ws.count, ws[i + 2] == "got" {
                    out.append("i've"); i += 2; continue
                }
                out.append(ws[i])
                i += 1
            }
            return out
        }

        /// The phrase occurs as whole words within one clause.
        public func has(_ phrase: String) -> Bool { padded.contains(" " + phrase + " ") }

        /// The utterance names `s` (all its words contiguously, or its head word of ≥ 3
        /// letters), plural-tolerant.
        public func mentions(_ s: Subject) -> Bool {
            if Subject.contains(words, s.words) { return true }
            if let head = s.words.last, head.count >= 3 { return words.contains { Subject.same($0, head) } }
            return false
        }
    }

    // MARK: Reading: stated feelings, corrections, goals

    /// What the words of one turn state or correct (lexicon values only).
    public struct Reading: Sendable, Equatable {
        /// Stated feelings in order ("fine", "tired"…); the last one wins.
        public var stated: [String] = []
        /// "I'm not X" values.
        public var negated: [String] = []
        public var statedBusy = false
        public var statedQuiet = false
        public var joking = false
        public var genericCorrection = false
        public var goal: String?

        public static let moodWords: [String: String] = [
            "fine": "fine", "okay": "fine", "alright": "fine", "allright": "fine", "good": "fine", "well": "fine",
            "happy": "happy", "great": "happy", "glad": "happy", "cheerful": "happy", "wonderful": "happy",
            "fantastic": "happy", "awesome": "happy", "amazing": "happy",
            "tired": "tired", "exhausted": "tired", "sleepy": "tired", "knackered": "tired", "drained": "tired",
            "wiped": "tired", "shattered": "tired",
            "sad": "sad", "down": "sad", "depressed": "sad", "blue": "sad", "miserable": "sad", "unhappy": "sad", "gutted": "sad",
            "stressed": "stressed", "overwhelmed": "stressed", "frazzled": "stressed",
            "anxious": "anxious", "nervous": "anxious", "worried": "anxious", "uneasy": "anxious",
            "angry": "angry", "mad": "angry", "annoyed": "angry", "furious": "angry", "irritated": "angry", "pissed": "angry",
            "sick": "sick", "ill": "sick", "unwell": "sick", "poorly": "sick",
            "bored": "bored", "excited": "excited", "thrilled": "excited", "lonely": "lonely",
            "scared": "scared", "afraid": "scared", "frightened": "scared", "terrified": "scared",
            "hurt": "hurt", "upset": "upset",
            "busy": "busy", "swamped": "busy", "slammed": "busy",
        ]
        static let modifiers: Set<String> = ["so", "really", "very", "a", "bit", "little", "kind", "kinda", "sort", "sorta", "of",
                                             "pretty", "just", "quite", "super", "too", "totally", "fairly", "rather", "feeling",
                                             "actually", "honestly", "somewhat", "bloody", "that", "all", "only", "mostly", "being"]
        /// A mood word followed by one of these is not a feeling ("good at", "sick of").
        static let notAfter: Set<String> = ["at", "with", "to", "of", "for", "about", "enough", "on"]

        static let jokingPhrases = ["i was joking", "i'm joking", "i'm only joking", "i was only joking", "just joking",
                                    "only joking", "i'm kidding", "i was kidding", "just kidding", "jk", "i'm just kidding",
                                    "i was just kidding", "i'm teasing", "i was teasing", "i'm just teasing", "i was just teasing"]
        static let correctionPhrases = ["no i meant", "not what i meant", "that's not what i said", "not what i said",
                                        "you misunderstood", "you misunderstand", "you misunderstood me", "you got it wrong",
                                        "you got that wrong", "you misheard", "not what i asked", "i didn't say that",
                                        "that's not what i asked", "you've got it wrong", "you have it wrong"]
        static let busyPhrases = ["not now", "i'm busy", "busy right now", "can't talk", "talk later", "later dee",
                                  "not right now", "in a minute dee", "i'm in the middle of something"]
        static let quietPhrases = ["shh", "shhh", "shush", "be quiet", "quiet please", "stop talking", "hush",
                                   "please be quiet", "leave me alone", "give me some quiet", "i need quiet"]
        static let newsPhrases = ["guess what", "you won't believe", "you'll never guess", "i have news", "i've got news",
                                  "big news", "good news", "i got news"]
        static let sharePhrases = ["look at this", "check this out", "check it out", "look what i made", "look what i",
                                   "i made this", "i made a", "i made something", "i drew", "i painted", "i built", "i baked",
                                   "i wrote", "i knitted", "i sewed", "i finished my", "see what i made", "look at what i"]
        static let taskStarts: [[String]] = [["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
                                             ["please"], ["help", "me"], ["i", "need", "you", "to"], ["remind", "me"],
                                             ["set", "a"], ["tell", "me"]]

        public init(_ u: Utterance) {
            for clause in u.clauses { scan(clause) }
            joking = Self.jokingPhrases.contains { u.has($0) }
            genericCorrection = !joking && (Self.correctionPhrases.contains { u.has($0) } || u.padded.contains(" no | i meant "))
            statedBusy = Self.busyPhrases.contains { u.has($0) } || stated.contains("busy")
            statedQuiet = Self.quietPhrases.contains { u.has($0) }
            stated.removeAll { $0 == "busy" }
            if Self.newsPhrases.contains(where: { u.has($0) }) {
                goal = "news"
            } else if Self.sharePhrases.contains(where: { u.has($0) }) || u.words.first == "look" {
                goal = "shareCreation"
            } else if let first = u.clauses.first, Self.taskStarts.contains(where: { first.starts(with: $0) }) {
                goal = "task"
            }
        }

        /// "I'm (not) X", "I feel X", "feeling X", and a trailing "just X" after a stated feeling.
        mutating func scan(_ c: [String]) {
            var i = 0
            while i < c.count {
                var j: Int?
                if c[i] == "i'm" { j = i + 1 }
                if c[i] == "i", i + 1 < c.count, ["feel", "felt"].contains(c[i + 1]) { j = i + 2 }
                if c[i] == "feeling", i == 0 { j = i + 1 }
                if ["just", "mostly", "only"].contains(c[i]), !stated.isEmpty { j = i }
                guard var k = j else { i += 1; continue }
                var negated = false
                if k < c.count, c[k] == "not" { negated = true; k += 1 }
                if k < c.count, c[k] == "like" { i += 1; continue }
                while k < c.count, Self.modifiers.contains(c[k]) { k += 1 }
                let followedOK = k + 1 >= c.count || !Self.notAfter.contains(c[k + 1])
                if k < c.count, followedOK, let v = Self.moodWords[c[k]] {
                    if negated {
                        if !self.negated.contains(v) { self.negated.append(v) }
                    } else if !(c[i] == "i'm" && v == "fine" && k + 1 < c.count && c[k + 1] == "with") {
                        stated.append(v)
                    }
                    i = k + 1
                    continue
                }
                i += 1
            }
        }
    }
}

// MARK: - Topics (lexical)

extension Interpreter {
    public enum Topics {
        static let triggers: Set<String> = ["my", "your", "our", "his", "her", "their", "the", "a", "an", "about", "some", "new"]
        /// Function words, common verbs, adjectives and adverbs that never start a topic.
        static let stop: Set<String> = [
            "a", "an", "the", "my", "your", "our", "his", "her", "their", "its", "it's", "this", "that", "these", "those",
            "and", "or", "but", "so", "if", "then", "than", "because", "of", "to", "in", "on", "at", "for", "with", "from",
            "by", "about", "into", "over", "after", "before", "under", "up", "down", "out", "off", "again", "just", "really",
            "very", "too", "also", "still", "even", "only", "some", "any", "all", "most", "more", "much", "many", "few",
            "lot", "lots", "bit", "little", "way", "thing", "things", "stuff", "time", "times", "day", "days", "one", "ones",
            "other", "another", "same", "own", "kind", "sort", "type", "whole", "next", "last", "first", "second", "new",
            "old", "big", "small", "good", "bad", "great", "best", "worst", "better", "worse", "nice", "fine", "okay",
            "right", "wrong", "real", "sure", "whatever", "something", "anything", "nothing", "everything", "someone",
            "anyone", "everyone", "nobody", "somebody", "there", "here", "where", "when", "what", "why", "how", "who",
            "which", "is", "are", "was", "were", "be", "been", "being", "am", "have", "has", "had", "do", "does", "did",
            "go", "goes", "going", "went", "gone", "get", "gets", "got", "getting", "make", "made", "making", "take", "took",
            "see", "saw", "seen", "look", "looking", "say", "said", "tell", "told", "think", "thought", "know", "knew",
            "want", "wanted", "need", "needed", "like", "liked", "love", "loved", "can", "could", "will", "would", "should",
            "may", "might", "must", "shall", "i", "me", "you", "he", "she", "we", "they", "him", "us", "them", "i'm",
            "you're", "don't", "didn't", "can't", "won't", "isn't", "wasn't", "not", "no", "yes", "yeah", "okay", "um", "uh",
            "er", "hmm", "oh", "hey", "hi", "hello", "dee", "today", "tomorrow", "tonight", "yesterday", "week", "weekend",
            "morning", "afternoon", "evening", "night", "now", "later", "soon", "pretty", "quite", "sorry", "please", "thanks",
            "own", "doing", "done", "try", "trying", "tried", "feel", "feeling", "felt", "put", "keep", "come", "came",
            "coming", "let", "start", "started", "finish", "finished", "use", "used", "work", "working", "worked",
        ]

        /// Topic subjects for one utterance: mentioned referents first, then up to two
        /// content phrases after a determiner / "about", singularised.
        public static func extract(_ u: Interpreter.Utterance, referents: [Referent]) -> [Subject] {
            var out: [Subject] = []
            func add(_ s: Subject?) { if let s, !out.contains(s) { out.append(s) } }
            for r in referents where u.mentions(r.subject) { add(r.subject) }
            var phrases = 0
            for c in u.clauses {
                var i = 0
                while i < c.count, phrases < 2 {
                    guard triggers.contains(c[i]) else { i += 1; continue }
                    var words: [String] = []
                    var j = i + 1
                    while j < c.count, words.count < 2, isContent(c[j]) {
                        // "my cat knocked over…": a past-tense verb ends the phrase.
                        if !words.isEmpty, looksPastTense(c[j]) { break }
                        words.append(lemma(c[j]))
                        j += 1
                    }
                    if !words.isEmpty, let s = Subject(words.joined(separator: " ")) {
                        if !out.contains(s) { out.append(s); phrases += 1 }
                    }
                    i = max(j, i + 1)
                }
            }
            return out
        }

        /// "knocked", "painted" (≥ 6 letters, "-ed", not "-eed"), or a common irregular
        /// past ("my dog died" → "dog"): only ever a phrase's second word.
        static func looksPastTense(_ w: String) -> Bool {
            (w.count >= 6 && w.hasSuffix("ed") && !w.hasSuffix("eed")) || irregularPast.contains(w)
        }
        static let irregularPast: Set<String> = ["died", "lost", "broke", "fell", "ran", "ate", "won", "sold", "bought", "quit",
                                                 "left", "hurt", "bit", "threw", "drove", "flew", "wrote", "spoke", "stole"]

        static func isContent(_ w: String) -> Bool {
            guard w.count >= 3, !stop.contains(w), Interpreter.Reading.moodWords[w] == nil,
                  !w.hasSuffix("ly"), w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return false }
            return true
        }

        /// Simple singular: "paintings" → "painting", "classes" → "class", "stories" → "story".
        public static func lemma(_ w: String) -> String {
            guard w.count > 3, !w.hasSuffix("'s") else { return w }
            if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if w.hasSuffix("sses") || w.hasSuffix("xes") || w.hasSuffix("ches") || w.hasSuffix("shes") { return String(w.dropLast(2)) }
            if w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") { return w }
            if w.hasSuffix("s") { return String(w.dropLast()) }
            return w
        }
    }
}

// MARK: - PlanDetector (§7.5)

extension Interpreter {
    /// A volunteered plan: the subject (≤ 4 words), when it is due and how they felt.
    public struct Plan: Sendable, Equatable {
        public var subject: Subject
        public var due: Date
        public var framing: Expectation.Framing
        /// Health (and other heavy) subjects get the gentle follow-up wording.
        public var health: Bool
        /// "I'm going to finish …" (a project rather than an event).
        public var finishing: Bool
        /// A date or time was said. An undated plan ("I have an exam") gets no timed
        /// follow-up: it resolves only when they bring it up (review finding 10).
        public var dated: Bool = true

        /// The signal label: framing, plus "+health" / "+finish" / "+undated".
        public var label: String {
            framing.rawValue + (health ? "+health" : "") + (finishing ? "+finish" : "") + (dated ? "" : "+undated")
        }

        /// The pending expectation (expires 7 d after it is due).
        public func expectation(id: UUID, person: PersonID) -> Expectation {
            Expectation(id: id, person: person, subject: subject, due: due, expires: due.addingTimeInterval(7 * 86_400), framing: framing)
        }

        /// The follow-up intention: not before due + 2 h, expires due + 7 d, priority 0.8.
        public func followUp(id: UUID, person: PersonID, now: Date) -> Intention {
            Intention(id: id, kind: .followUp, subject: subject, person: person, reason: "they were \(framing.rawValue) about it",
                      notBefore: due.addingTimeInterval(2 * 3600), expires: due.addingTimeInterval(7 * 86_400), priority: 0.8,
                      source: "plan", created: now)
        }
    }

    /// Decodes Interpreter's `"plan"` signal (for IntentionBoard / EpisodeBuilder).
    public static func plan(from s: Signal) -> Plan? {
        guard s.name == "plan", s.owner == name, let subject = s.subject, let label = s.label else { return nil }
        let parts = label.split(separator: "+").map(String.init)
        guard let framing = parts.first.flatMap(Expectation.Framing.init(rawValue:)) else { return nil }
        return Plan(subject: subject, due: Date(timeIntervalSinceReferenceDate: s.value), framing: framing,
                    health: parts.contains("health"), finishing: parts.contains("finish"), dated: !parts.contains("undated"))
    }

    public enum PlanDetector {
        public static let eventNouns: Set<String> = [
            "exam", "test", "interview", "appointment", "trip", "game", "date", "surgery", "operation", "party",
            "presentation", "match", "recital", "concert", "meeting", "flight", "wedding", "funeral", "audition", "race",
            "tournament", "competition", "gig", "show", "performance", "holiday", "vacation", "checkup", "check-up", "scan",
            "therapy", "deadline", "dentist", "doctor", "hearing", "graduation", "marathon", "quiz", "final", "finals",
            "rehearsal", "class", "lesson", "shift", "procedure", "biopsy", "physio", "x-ray", "mri", "jab", "vaccine",
            "vet", "court", "trial", "memorial",
        ]
        static let healthWords: Set<String> = ["surgery", "operation", "doctor", "doctor's", "dentist", "dentist's", "hospital",
                                               "scan", "checkup", "check-up", "therapy", "biopsy", "physio", "x-ray", "mri",
                                               "procedure", "jab", "vaccine", "blood", "gp", "clinic", "chemo",
                                               // Not cheerful either: "how did it go?" is wrong for these.
                                               "funeral", "hearing", "court", "vet", "trial", "memorial", "results", "treatment"]
        /// A clause with one of these before the event is not a plan ("I have no meeting").
        static let negations: Set<String> = ["no", "not", "don't", "didn't", "won't", "never", "haven't", "hasn't", "isn't",
                                             "aren't", "wasn't", "without"]
        static let cancelWords: Set<String> = ["cancel", "cancelled", "canceled", "cancelling", "postponed", "called"]
        static let starters: [[String]] = [
            ["i", "have"], ["i've"], ["i", "got"], ["i'm", "going", "to"], ["i'm", "having"], ["i'm", "doing"],
            ["i'll", "have"], ["i'll", "be", "at"], ["we", "have"], ["we've"], ["we're", "going", "to"], ["i", "need", "to", "go", "to"],
            ["i'm", "off", "to"], ["i'm", "going", "on"], ["i'm", "off", "on"], ["i'm", "taking"], ["i", "must", "go", "to"], ["my"],
        ]
        static let finishers: [[String]] = [["i'm", "going", "to", "finish"], ["i'll", "finish"], ["i", "want", "to", "finish"],
                                            ["i", "plan", "to", "finish"], ["i'm", "finishing"], ["i", "need", "to", "finish"]]
        /// Words that make a "my …" clause an outcome, not a plan.
        static let pastWords: Set<String> = ["went", "was", "were", "had", "did", "got", "passed", "failed", "finished", "over"]
        /// Past tense between the starter and the event ("I've had an interview").
        static let pastBefore: Set<String> = ["had", "went", "was", "were", "did", "passed", "failed", "finished"]
        static let noise: Set<String> = ["big", "huge", "first", "second", "last", "final", "important", "scary", "little",
                                         "new", "real", "proper", "massive", "stupid", "annoying"]
        static let nervousWords = ["nervous", "worried", "scared", "anxious", "dreading", "terrified", "stressed", "freaking",
                                   "panicking", "dread", "not looking forward", "afraid"]
        static let excitedWords = ["excited", "can't wait", "cannot wait", "looking forward", "thrilled", "pumped", "stoked",
                                   "psyched"]

        /// Detects a volunteered future event or "finish" plan in the utterance.
        public static func detect(_ text: String, appraisal: Appraisal, now: Date, calendar: Calendar) -> Plan? {
            detect(Utterance(text), appraisal: appraisal, now: now, calendar: calendar)
        }

        public static func detect(_ u: Utterance, appraisal a: Appraisal, now: Date, calendar: Calendar) -> Plan? {
            let when = Interpreter.DateParser.parse(u.words, now: now, calendar: calendar)
            guard let (subject, finishing) = findSubject(u, dated: when.found) else { return nil }
            let framing = Self.framing(u, a)
            let health = subject.words.contains { healthWords.contains($0) }
            return Plan(subject: subject, due: when.due, framing: framing, health: health, finishing: finishing, dated: when.found)
        }

        static func framing(_ u: Utterance, _ a: Appraisal) -> Expectation.Framing {
            if nervousWords.contains(where: { u.has($0) }) { return .nervous }
            if excitedWords.contains(where: { u.has($0) }) { return .excited }
            if a.distress >= 0.3 { return .nervous }
            if a.valence >= 0.4 { return .excited }
            return .neutral
        }

        static func findSubject(_ u: Utterance, dated: Bool) -> (Subject, Bool)? {
            for c in u.clauses {
                for f in finishers {
                    guard let at = index(of: f, in: c) else { continue }
                    var words: [String] = []
                    var j = at + f.count
                    while j < c.count, ["the", "my", "a", "an", "that", "this", "off", "up"].contains(c[j]) { j += 1 }
                    while j < c.count, words.count < 3, Interpreter.Topics.isContent(c[j]) || eventNouns.contains(c[j]) {
                        words.append(Interpreter.Topics.lemma(c[j]))
                        j += 1
                    }
                    if let s = Subject(words.joined(separator: " ")) { return (s, true) }
                }
                for st in starters {
                    guard let at = index(of: st, in: c) else { continue }
                    if st == ["my"] || st == ["i", "got"], !dated { continue }
                    let from = at + st.count
                    let to = min(c.count, from + 6)
                    guard from < to, var k = (from..<to).first(where: { eventNouns.contains(Interpreter.Topics.lemma(c[$0])) }) else { continue }
                    while k + 1 < c.count, eventNouns.contains(Interpreter.Topics.lemma(c[k + 1])) { k += 1 }
                    // "I have no meeting tomorrow", "my exam got cancelled".
                    if c[..<k].contains(where: { negations.contains($0) }) || c.contains(where: { cancelWords.contains($0) }) { continue }
                    if c[from..<k].contains(where: { pastBefore.contains($0) }) { continue }
                    if c[(k + 1)...].contains(where: { pastWords.contains($0) }) { continue }
                    var words = [Interpreter.Topics.lemma(c[k])]
                    var b = k - 1
                    while b >= from, words.count < 3, !noise.contains(c[b]),
                          Interpreter.Topics.isContent(c[b]) || c[b].hasSuffix("'s") {
                        words.insert(c[b], at: 0)
                        b -= 1
                    }
                    if let s = Subject(words.joined(separator: " ")) { return (s, false) }
                }
            }
            return nil
        }

        static func index(of phrase: [String], in c: [String]) -> Int? {
            guard phrase.count <= c.count else { return nil }
            return (0...(c.count - phrase.count)).first { i in phrase.indices.allSatisfy { c[i + $0] == phrase[$0] } }
        }
    }

    /// Deterministic lexical date parsing (no wall clock, no NSDataDetector).
    public enum DateParser {
        static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        static let numbers: [String: Int] = ["a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                             "eight": 8, "nine": 9, "ten": 10, "couple": 2, "few": 3]
        static let partOfDay: [String: Int] = ["morning": 9, "afternoon": 15, "evening": 19, "night": 20, "lunchtime": 12,
                                               "noon": 12, "midday": 12]

        /// `found` is false when no date or time phrase was present (due = now + 1 d).
        public static func parse(_ w: [String], now: Date, calendar cal: Calendar) -> (due: Date, found: Bool) {
            var offset: Int?
            var hour: Int?
            var minute = 0
            // A day without a time: assume the evening, so the follow-up (due + 2 h) is
            // never asked before a 4 pm interview (review finding 10).
            var defaultHour = 17
            func at(_ i: Int) -> String? { i >= 0 && i < w.count ? w[i] : nil }
            for (i, x) in w.enumerated() {
                switch x {
                case "today": offset = offset ?? 0
                case "tonight": offset = offset ?? 0; defaultHour = 20
                case "tomorrow":
                    if at(i - 1) == "after", at(i - 2) == "day" { offset = 2 } else { offset = offset ?? 1 }
                    if let h = at(i + 1).flatMap({ partOfDay[$0] }) { defaultHour = h }
                case "this":
                    if let next = at(i + 1), let h = partOfDay[next] { offset = offset ?? 0; defaultHour = h }
                    if at(i + 1) == "weekend" { offset = offset ?? daysUntil(6, from: now, cal, allowToday: true) }
                case "weekend":
                    if at(i - 1) != "this", at(i - 1) != "last" { offset = offset ?? daysUntil(6, from: now, cal, allowToday: true) }
                case "week":
                    if at(i - 1) == "next" { offset = offset ?? 7 }
                case "month":
                    if at(i - 1) == "next" { offset = offset ?? 30 }
                case "days", "weeks":
                    if let n = count(before: i, w) { offset = x == "weeks" ? n * 7 : n }
                case "noon", "midday": hour = 12
                case "midnight": hour = 23; minute = 59
                case "morning", "afternoon", "evening", "night", "lunchtime":
                    // "Friday morning", "Friday night" (tune 2: the live exam was due at
                    // the 17:00 day default, so the follow-up waited until 19:00 on the
                    // exam day); "in the morning" with no day is the next one coming.
                    let h = partOfDay[x] ?? defaultHour
                    if let prev = at(i - 1), weekdays.contains(prev) {
                        defaultHour = h
                    } else if at(i - 1) == "the", at(i - 2) == "in" || at(i - 2) == "on" {
                        if offset == nil { hour = h } else { defaultHour = h }
                    }
                default:
                    if let d = weekdays.firstIndex(of: x) {
                        if at(i - 1) != "last" { offset = offset ?? daysUntil(d, from: now, cal, allowToday: false) }
                    } else if x == "a", at(i + 1) == "week", at(i - 1) == "in" {
                        offset = 7
                    } else if let t = time(x, next: at(i + 1), prev: at(i - 1)) ?? spokenTime(w, i) {
                        hour = t.0
                        minute = t.1
                    }
                }
            }
            guard offset != nil || hour != nil else { return (now.addingTimeInterval(86_400), false) }
            let day = cal.date(byAdding: .day, value: offset ?? 0, to: cal.startOfDay(for: now)) ?? now
            var due = cal.date(bySettingHour: hour ?? defaultHour, minute: minute, second: 0, of: day) ?? day
            if offset == nil, due < now { due = cal.date(byAdding: .day, value: 1, to: due) ?? due }
            return (max(due, now), true)
        }

        /// "in two days", "in a couple of days", "in 3 weeks": the number before `i`.
        static func count(before i: Int, _ w: [String]) -> Int? {
            var j = i - 1
            if j >= 0, w[j] == "of" { j -= 1 }
            guard j >= 1, let n = numbers[w[j]] ?? Int(w[j]) else { return nil }
            if w[j - 1] == "in" { return n }
            if j >= 2, w[j - 1] == "a", w[j - 2] == "in" { return n }
            return nil
        }

        /// Days from `now` to the next weekday `target` (0 = Sunday … 6 = Saturday).
        static func daysUntil(_ target: Int, from now: Date, _ cal: Calendar, allowToday: Bool) -> Int {
            let today = cal.component(.weekday, from: now) - 1
            let d = (target - today + 7) % 7
            return d == 0 && !allowToday ? 7 : d
        }

        /// Spoken clock hours (transcripts write "at three", not "at 3").
        static let hourWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                               "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
        static let minuteWords: [String: Int] = ["fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50]
        /// "at three" never names a time in these ("at one point", "at three of them").
        static let notAfterSpokenHour: Set<String> = ["point", "time", "times", "stage", "of", "or", "another", "each", "once",
                                                      "least", "most", "all", "first", "last", "day", "days", "years", "year"]

        /// Tune 3: the live "I have a dentist appointment next Tuesday at three." was due
        /// at the 17:00 day default, so the follow-up waited until 19:00 and never came
        /// that evening. "at three", "three o'clock", "three pm", "at three thirty",
        /// "half past three" (an hour word only with one of these anchors).
        static func spokenTime(_ w: [String], _ i: Int) -> (Int, Int)? {
            func at(_ k: Int) -> String? { k >= 0 && k < w.count ? w[k] : nil }
            guard let h = hourWords[w[i]] else { return nil }
            var minute = 0
            var j = i + 1
            if let m = at(j).flatMap({ minuteWords[$0] }) { minute = m; j += 1 }
            let next = at(j)
            var pm: Bool?
            if ["pm", "p.m", "p.m."].contains(next ?? "") { pm = true }
            if ["am", "a.m", "a.m."].contains(next ?? "") { pm = false }
            let past = at(i - 1) == "past" && (at(i - 2) == "half" || at(i - 2) == "quarter")
            if past { minute = at(i - 2) == "half" ? 30 : 15 }
            let anchored = pm != nil || next == "o'clock" || next == "oclock" || past
                || (at(i - 1) == "at" && !notAfterSpokenHour.contains(next ?? ""))
            guard anchored else { return nil }
            var hour = h
            if pm == true, h < 12 { hour += 12 }
            if pm == false, h == 12 { hour = 0 }
            if pm == nil, (1...7).contains(h) { hour += 12 }
            return (hour, minute)
        }

        /// "3pm", "3:30pm", "15:30", "at 3", "3 o'clock", "3 pm".
        static func time(_ x: String, next: String?, prev: String?) -> (Int, Int)? {
            var s = x
            var pm: Bool?
            if s.hasSuffix("pm") { pm = true; s = String(s.dropLast(2)) } else if s.hasSuffix("am") { pm = false; s = String(s.dropLast(2)) }
            if pm == nil, next == "pm" || next == "p.m" { pm = true }
            if pm == nil, next == "am" || next == "a.m" { pm = false }
            let parts = s.split(separator: ":").map(String.init)
            guard let h = parts.first.flatMap({ Int($0) }), (0...23).contains(h) else { return nil }
            let mm = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let explicit = pm != nil || parts.count > 1 || next == "o'clock" || prev == "at"
            guard explicit, (0...59).contains(mm) else { return nil }
            var hour = h
            if pm == true, h < 12 { hour += 12 }
            if pm == false, h == 12 { hour = 0 }
            if pm == nil, parts.count == 1, (1...7).contains(h) { hour += 12 }
            return (hour, mm)
        }
    }
}

// MARK: - RepairDetector (§7.8)

extension Interpreter {
    /// Repair-relevant phrases, using RepairKeeper's public helpers so both reducers
    /// detect identically (RepairKeeper deduplicates the signals against its own reading).
    public enum RepairDetector {
        public enum Finding: Sendable, Equatable {
            /// A verbal reconciliation bid: "apology", "areWeOk", "friends", "didntMeanIt", "phrase".
            case bid(String)
            case userBoundary(Subject)
            case boundaryLifted(Subject)
        }

        static let bidLabels: [(String, String)] = [
            ("sorry", "apology"), ("apologi", "apology"), ("forgive me", "apology"), ("my bad", "apology"), ("make up", "friends"),
            ("are we ok", "areWeOk"), ("are we okay", "areWeOk"), ("are we good", "areWeOk"), ("are we cool", "areWeOk"),
            ("are we alright", "areWeOk"), ("friends?", "friends"), ("still friends", "friends"), ("be friends", "friends"),
            ("didn't mean it", "didntMeanIt"), ("didnt mean it", "didntMeanIt"), ("did not mean it", "didntMeanIt"),
            ("didn't mean that", "didntMeanIt"), ("didnt mean that", "didntMeanIt"),
        ]

        public static func read(_ text: String, appraisal a: Appraisal, topic: Subject?) -> [Finding] {
            var out: [Finding] = []
            let hostile = a.hostility >= RepairKeeper.hostileAt || a.threat >= RepairKeeper.hostileAt
            if !hostile, a.apology >= 0.3 || RepairKeeper.isBidText(text) {
                let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                let label = a.apology >= 0.3 ? "apology" : bidLabels.first { t.contains($0.0) }?.1 ?? "phrase"
                out.append(.bid(label))
            }
            if let r = RepairKeeper.boundaryRequest(in: text, topic: topic) {
                out.append(r.lift ? .boundaryLifted(r.topic) : .userBoundary(r.topic))
            }
            return out
        }
    }
}
