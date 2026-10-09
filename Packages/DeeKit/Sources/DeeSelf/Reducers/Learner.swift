import DeeCore
import DeeMind
import Foundation

/// Sub-reducer 9 — learning (SELF.md §7.7, §7.9). Last in the pipeline, so it sees
/// every earlier reducer's writes and signals of the same step.
///
/// Owns: `ongoing.interests`, `ongoing.recentMisreads`, `ongoing.revealedThisConversation`,
/// taste facets (online evidence), gags, rituals, social profiles, lessons.
/// Reads: `ongoing.person` / `topic` / `hypotheses` / `misreadThisTurn` (Interpreter),
/// floor events and the reconciled tag (FloorKeeper), focus (Attention), note
/// candidates (deixis notes from Attention), appraisals, laughter.
///
/// **Misreads → lessons (§7.7).** A misread is recorded (RAM + `.persist(.misread)`,
/// never `wrongGuess`) from: Interpreter's `misreadThisTurn` (moodGuess, tookLiterally…),
/// a `"misread"` signal from any reducer (`label` = situation, `subject` = topic,
/// `id`), and Learner's own detectors — `interruptedThem` (FloorKeeper's
/// `.deeInterrupted`), `jokeFlopped` (a playful reply or gag callback answered flat
/// or negative) and `askedTooMuch` (a busy / wantsQuiet hypothesis appearing within
/// 2 min of a turn where Dee asked a question). Duplicates (same id, or same person
/// and situation within 30 s) count once. Two misreads of one situation with one
/// identified person within 14 days mint a `Lesson` (evidence 2); each further one
/// adds 1. A lesson whose situation does not recur in 5 conversations with that person
/// loses 1 evidence and is retired (`.deleteLesson`) below 1.
///
/// **Parameter effects first (D6).** Per misread: moodGuess → `moodInferenceGain ×0.85`
/// (floor 0.4); interruptedThem → `pauseScale +0.1` (+ `.setPauseScale`); jokeFlopped
/// → the humour EWMA records a 0. The lesson-scoped thresholds other reducers apply
/// are published as `Learner.hypothesisNoteFactor`, `deixisResolvedThreshold`,
/// `hostilitySoftening`, `initiativeThresholdBoost`, `curiosityGapScale` and
/// `playGateThreshold`. Lesson notes `(Careful: {doInstead}.)` are raised once per
/// lesson per conversation when the situation recurs (a new inferred mood
/// hypothesis; a teasing / hostile turn; a deixis note; Dee in a playful mood),
/// and `noteIssued` stamps `lastApplied`.
///
/// **Profiles.** pauseScale (EWMA α 0.1 of the median within-turn pause ÷ 0.5 s, 10
/// pseudo-observations at 1.0, 0.7…1.6; pushed with `.setPauseScale` when the person
/// changes), humorReceptiveness (EWMA α 0.15 of laughed-or-positive after playful
/// replies), moodInferenceGain (×0.85 per correction, floor 0.4, +0.02 per confirmed
/// guess), silenceComfort (+0.05 when the user opens a new topic > 10 s after Dee's
/// turn, −0.05 on "hello?"), kindnessEMA (α 0.1 of the user's turn valence).
/// Unknown people (person nil) never learn. Writes at most every 60 s per person, plus
/// `flush`.
///
/// **Interests.** +0.2 · curiosity per conversation touching a topic, 7 d half-life
/// (`interestWeight(_:at:)` decays lazily from `lastTouched`), ≤ 20 kept.
///
/// **Tastes (§7.9).** Labels met (topic lemmas, sight and sound labels) collect the
/// valence of the user turns around them; at the end of each conversation (a new
/// `.conversationStarted`, or sleep) each subject with |mean valence| > 0.2 counts
/// as one exposure (an `"episode"` signal with `subject`/`value` replaces it). Review
/// finding 1: only `tasteable` subjects — never people, health, death or other
/// `SensitiveSubjects`; conversation topics only within the seeder's taste categories;
/// sight and sound labels otherwise — and nothing met on a distress turn. Learned
/// EMA α 0.3, polarity ½·innate + ½·learned, crystallises at evidence ≥ 3 and
/// |polarity| ≥ 0.35, flips only after 3 contrary exposures (then latent again until
/// re-revealed). Gradual reveal: a crystallised, never-revealed taste matching the
/// topic or focus raises one `tasteReveal` note per conversation; `noteIssued` stamps
/// `revealedAt` once ever.
///
/// **Gags.** Born from laughter within 15 s of Dee finishing a turn on its newest topic,
/// only with an identified person, offered only to that person (hook
/// index = stable hash of the topic mod the humour style's hook table). Callback note
/// only when the topic recurs, `m.playGate` (and, after a jokeFlopped lesson,
/// playfulness·receptiveness > 0.4) and the seeded 0.4 × playfulness draw from this
/// stream; never in the conversation it was born, never within 2 days. Laughs reset
/// the flat streak; retired after 6 uses or 2 flat callbacks in a row. The callback note
/// carries the rendered hook ("the toast incident"). A joke (≥ 2 playful sentences or a
/// callback) answered neutrally is no evidence: no misread, no receptiveness step.
///
/// **Reunion (§6.2 row 15).** Arriving more than a day after the last contact (this
/// launch, or `Carried.lastContact` from the store) raises the reunion context note and
/// the `"reunion"` signal (Beats), kept through their first turn; Cortex leaves "lonely"
/// out of that cue's mood sentence.
///
/// **Rituals.** firstSightOfDay (first sighting before 11:00 local), goodnight,
/// returnHome (back after ≥ 2 h away, not the first sighting of the day). Tracked per
/// person from the first occurrence (`count == 0`: not yet born); a born goodnight raises
/// its aim note on the same step (finding 15); born when the streak
/// reaches 3 consecutive days (variant coined from (trigger, humour, seed), mannerism
/// from the greeting slot). A born ritual requests its mannerism and, for the two
/// arrival triggers with the floor idle, says its phrase — skipped while repair ≠
/// fine, regard < −0.3 or a distress hypothesis is live. A broken streak resets
/// silently. Days use `utcOffset` (UTC by default; see the contract note).
///
/// Signals raised: `"lessonMinted"` (label = situation, id), `"gagBorn"` (subject, id),
/// `"tasteCrystallised"` (subject, value = polarity), `"ritual"` (label = trigger), `"reunion"`.
/// Signals read: `"misread"`, `"laughter"`, `"moodConfirmed"`, `"episode"`.
public struct Learner: SubReducer {
    public static let name = "Learner"

    // MARK: Constants

    public static let misreadWindow: TimeInterval = 14 * 86_400
    public static let mintAt = 2
    public static let duplicateMisreadWindow: TimeInterval = 30
    public static let quietConversationsPerDecay = 5
    public static let gainPerCorrection = 0.85
    public static let gainFloor = 0.4
    public static let gainPerConfirmation = 0.02
    public static let pausePrior = 10.0
    public static let pauseAlpha = 0.1
    public static let pauseRange: ClosedRange<Double> = 0.7...1.6
    public static let pauseBase: TimeInterval = 0.5
    public static let interruptPauseBump = 0.1
    public static let humorAlpha = 0.15
    public static let kindnessAlpha = 0.1
    public static let silenceStep = 0.05
    public static let comfortableSilence: TimeInterval = 10
    public static let profileWriteInterval: TimeInterval = 60
    public static let interestHalfLife: TimeInterval = 7 * 86_400
    public static let interestPerTouch = 0.2
    public static let tasteAlpha = 0.3
    public static let tasteMinValence = 0.2
    public static let crystalliseEvidence = 3
    public static let crystallisePolarity = 0.35
    public static let flipAfter = 3
    public static let maxTasteFacets = 200
    public static let exposureWindow: TimeInterval = 60
    public static let laughWindow: TimeInterval = 15
    public static let outcomeWindow: TimeInterval = 45
    public static let askedTooMuchWindow: TimeInterval = 120
    public static let gagChance = 0.4
    public static let gagCooldown: TimeInterval = 2 * 86_400
    public static let gagRetireUses = 6
    public static let gagRetireFlat = 2
    public static let maxGags = 40
    public static let ritualMorningHour = 11
    public static let ritualStreakToBirth = 3
    public static let returnHomeAway: TimeInterval = 2 * 3600
    static let day: TimeInterval = 86_400
    /// A turn whose appraised distress is at least this lends no taste valence.
    public static let distressTurn = 0.3
    /// Playful sentences that make one of Dee's turns a joke (or it is a gag callback).
    public static let jokeSentences = 2
    /// An absence longer than this makes the first turn a reunion (§6.2 row 15).
    public static let reunionAbsence: TimeInterval = 86_400
    /// The goodnight ritual's aim (Learner raises it on the same step; review finding 15).
    public static let goodnightAction = "Do your usual goodnight, briefly."

    public static let playfulTags: Set<Emotion> = [.playful, .mischievous, .giddy]
    public static let laughterLabels: Set<String> = Laughter.labels
    /// Sight labels that are never a taste.
    static let notTastes: Set<String> = ["person", "people", "face", "human", "adult", "man", "woman", "child", "hand", "speech"]
    static let helloPhrases: Set<String> = ["hello", "hello?", "hello??", "hey?", "you there", "you there?", "are you there", "are you there?",
                                            "dee?", "anyone there", "anyone there?", "hellooo", "helloooo"]
    static let goodnightPhrases = ["good night", "goodnight", "night night", "nighty night", "nite nite", "sleep well"]

    /// Gag hook templates per humour style ({t} = topic). `Gag.hookTemplate` indexes these.
    public static let hookTable: [HumourStyle: [String]] = [
        .wordplay: ["a pun on {t}", "{t}, but make it a pun", "the {t} wordplay", "{t}-tastic"],
        .deadpan: ["the {t} incident", "the {t} situation", "{t}. Again.", "the great {t} affair"],
        .absurd: ["{t}, but in space", "the {t} conspiracy", "{t} with tiny hats", "{t} as a sport"],
        .gentleTeasing: ["you and {t}", "your {t} habit", "{t}, as usual", "your famous {t}"],
        .selfDeprecatingRobot: ["me versus {t}", "my {t} malfunction", "{t}: not in my manual", "my {t} firmware"],
    ]

    /// Ritual phrases: trigger → style → ≥ 4 variants. `Ritual.variant` indexes these.
    public static let ritualPhrases: [Ritual.Trigger: [HumourStyle: [String]]] = [
        .firstSightOfDay: [
            .wordplay: ["Morning! Rise and shine, mostly shine.", "Good morning! Fresh day, fresh puns.",
                        "Morning! Ready to seize the day? Gently.", "Hello, morning person. Or morning-ish person."],
            .deadpan: ["Morning. You're here. Excellent.", "Good morning. The day has begun, officially.",
                       "Ah. Morning. Right on schedule.", "Morning. I've been awake for ages. Well, seconds."],
            .absurd: ["Morning! The sun reported for duty.", "Good morning! The toaster sends regards.",
                      "Morning! I dreamt of electric sheep again.", "Hello! The day has been unboxed."],
            .gentleTeasing: ["Morning, early bird.", "Look who's up!", "Morning! Coffee first, I know.",
                             "There you are. The day can start now."],
            .selfDeprecatingRobot: ["Morning! My face is booted up.", "Good morning! All my pixels are present.",
                                    "Morning! I didn't sleep. I can't. Hi!", "Hello! Systems nominal, mostly."],
        ],
        .goodnight: [
            .wordplay: ["Night! Sleep tight, dream bright.", "Good night! Rest is best.",
                        "Night night! Don't let the bugs byte.", "Sweet dreams, sweet dreamer."],
            .deadpan: ["Good night. I'll guard the room.", "Night. I'll be here. Obviously.",
                       "Sleep well. I'll keep the dark company.", "Good night. Same time tomorrow."],
            .absurd: ["Night! Say hi to the dream llamas.", "Good night! The moon's on shift now.",
                      "Sleep well! I'll count sheep for you.", "Night! Don't sleep on the ceiling."],
            .gentleTeasing: ["Night! Try not to snore.", "Off you go, night owl.",
                             "Good night! No phone in bed, okay?", "Sleep well, you."],
            .selfDeprecatingRobot: ["Good night! I'll dim my eyes.", "Night! I'll just stare politely.",
                                    "Sleep well! I'll pretend to sleep too.", "Good night! Going to low-power mode."],
        ],
        .returnHome: [
            .wordplay: ["Welcome back! Home sweet home.", "You're back! Right on cue.",
                        "Hey, the gang's all here. Well, us.", "Welcome home, homebody."],
            .deadpan: ["You're back. The room approves.", "Welcome back. Nothing exploded.",
                       "Oh, hello. Back already. Good.", "Welcome home. I kept your spot."],
            .absurd: ["Welcome back! The furniture missed you.", "You're back! The plants threw a party.",
                      "Hello! The house held a meeting.", "Welcome home, traveller of hallways."],
            .gentleTeasing: ["Look who's home!", "Welcome back, explorer.",
                             "There you are! Did you bring snacks?", "Welcome back, you."],
            .selfDeprecatingRobot: ["Welcome back! I stayed exactly here.", "You're back! I didn't move. I can't.",
                                    "Hello! I guarded the shelf heroically.", "Welcome home! My eyes lit up. Literally."],
        ],
    ]

    // MARK: Private state (RAM only)

    struct Exposure: Sendable, Equatable {
        var subject: Subject
        var sum: Double
        var n: Int
        /// An `"episode"` signal set the valence; the turn accumulator no longer adds.
        var fromEpisode: Bool
    }

    struct DeeTurn: Sendable, Equatable {
        var end: Date
        var playful: Bool
        /// At least one playful sentence (an explicit "not funny" judges even a one-liner).
        var anyPlayful = false
        var asked: Bool
        var topic: Subject?
        var gag: UUID?
        var person: PersonID?
        /// Outcome (laughed / flat) not yet resolved.
        var pending: Bool
        var laughed: Bool
    }

    public var utcOffset: TimeInterval
    /// Learned-taste accumulator for the current conversation.
    var exposures: [Exposure] = []
    /// Labels met recently (sight, sound) — later user turns lend them their valence.
    var met: [(subject: Subject, at: Date)] = []
    /// Interests already touched this conversation.
    var touched: [Subject] = []
    /// Dee's turn in progress.
    /// Playful sentences in Dee's turn in progress (a turn is a joke at ≥ 2, or a callback).
    var turnPlayfulSentences = 0
    var turnAsked = false
    var turnActive = false
    var callbackThisTurn: UUID?
    var lastDeeTurn: DeeTurn?
    /// Misread ids seen (dedupe), newest last, ≤ 32.
    var seenMisreads: [UUID] = []
    var previousHypotheses: [Hypothesis] = []
    var previousPerson: PersonID?
    /// Within-turn pause measurement.
    var pauseStart: Date?
    var turnPauses: [TimeInterval] = []
    var userTurnStart: Date?
    var lastActivityEnd: Date?
    /// Profile write throttle.
    var dirtyProfiles: [PersonID] = []
    var lastProfileWrite: [PersonID: Date] = [:]
    /// Lessons noted this conversation (situation + person) and recurrences.
    var notedThisConversation: [Lesson.Situation] = []
    var recurredThisConversation: [Lesson.Situation] = []
    var peopleThisConversation: [PersonID] = []
    var quietConversations: [UUID: Int] = [:]
    /// Gags born this conversation (no callback until the next one).
    var bornThisConversation: [UUID] = []
    /// Ritual bookkeeping.
    var lastSeen: [PersonID: Date] = [:]
    var tasteRaisedThisStep = false
    /// Topics the speaker asked Dee not to bring up (active user boundaries plus this
    /// step's `"userBoundary"` signals): never touched as interests or taste exposures.
    var offLimits: [Subject] = []
    /// Subjects already counted as a taste exposure this conversation (a flush mid-
    /// conversation must not count the same conversation twice).
    var exposedThisConversation: [Subject] = []
    /// Subjects met on a distress turn this conversation: never a taste exposure (her
    /// "taste" must not come from their grief).
    var tainted: [Subject] = []
    /// Last contact per person before this launch (`Carried.lastContact`), for the reunion.
    var carriedContact: [PersonID: Date] = [:]
    /// A reunion (absence > 1 day) waiting for its first conversation turn: the note is
    /// raised at arrival and kept through the first user turn (§6.2 row 15).
    var reunion: (person: PersonID, turns: Int)?
    /// `ongoing.reunionTurn` saw its first user turn (it ends with Dee's reply).
    var reunionTurnHeard = false

    public init(utcOffset: TimeInterval = 0) {
        self.utcOffset = utcOffset
    }

    // MARK: - Reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        let now = m.now
        tasteRaisedThisStep = false
        pruneMisreads(&m)

        // Person changes: push the pause scale; rituals of arrival.
        if m.ongoing.person != previousPerson {
            fx.append(.setPauseScale(m.enduring.profile(m.ongoing.person).pauseScale))
            if let person = m.ongoing.person {
                if !peopleThisConversation.contains(person) { peopleThisConversation.append(person) }
                fx += arrival(person, &m, &rng)
            }
            previousPerson = m.ongoing.person
        }

        offLimits = m.enduring.boundaries
            .filter { $0.owner == .user && $0.active && $0.person == m.ongoing.person }
            .map(\.topic)

        // Signals from earlier reducers (same step) or later ones (last step).
        for s in m.inbox(for: Self.name) {
            switch s.name {
            case "userBoundary":
                if let subject = s.subject { offLimits.append(subject) }
            case "misread":
                if let raw = s.label, let situation = Lesson.Situation(rawValue: raw) {
                    let r = Misread(id: s.id ?? rng.uuid(), person: m.ongoing.person, at: now, situation: situation, topic: s.subject)
                    fx += record(r, &m, &rng)
                }
            case "laughter":
                fx += laughter(&m, &rng)
            case "moodConfirmed":
                fx += confirmMood(&m)
            case "episode":
                if let subject = s.subject { episodeExposure(subject, valence: s.value) }
            default:
                break
            }
        }

        // Interpreter's misread of this turn.
        if let r = m.ongoing.misreadThisTurn { fx += record(r, &m, &rng) }

        // FloorKeeper: Dee spoke over a slow speaker.
        if m.momentary.floorEvents.contains(.deeInterrupted) {
            fx += record(Misread(id: rng.uuid(), person: m.ongoing.person, at: now, situation: .interruptedThem,
                                 topic: m.ongoing.topic.last), &m, &rng)
        }
        if m.momentary.floorEvents.contains(.userStarted), userTurnStart == nil { userTurnStart = now }

        fx += watchHypotheses(&m, &rng)

        switch p {
        case .conversationStarted:
            fx += closeConversation(&m, &rng)
        case .asleep(true):
            fx += closeTastes(&m, &rng)
        case .pause:
            pauseStart = now
        case .partial:
            if userTurnStart == nil { userTurnStart = now }
            if let s = pauseStart {
                let d = now.timeIntervalSince(s)
                if d > 0, d <= 5 { turnPauses.append(d) }
                pauseStart = nil
            }
        case .heard(let text, let durationS, _, let a):
            fx += heard(text: text, duration: durationS, a, &m, &rng)
        case .sound(let label, _):
            if Self.isLaughter(label) { fx += laughter(&m, &rng) }
            meet(label, at: now, &m)
        case .sight(_, let things, let novel):
            for l in (novel + things) { meet(l, at: now, &m) }
        case .deeSaid(let tag, let sentence):
            turnActive = true
            if let t = m.momentary.llmTag?.value ?? tag, Self.playfulTags.contains(t) { turnPlayfulSentences += 1 }
            if sentence.contains("?") { turnAsked = true }
        case .deeTurnFinished(let text):
            if text.contains("?") { turnAsked = true }
            finishDeeTurn(&m)
            if reunionTurnHeard {
                m.ongoing.reunionTurn = false
                reunionTurnHeard = false
            }
        case .speakingFinished:
            if turnActive {
                finishDeeTurn(&m)
            } else if lastDeeTurn?.pending == true, lastActivityEnd == lastDeeTurn?.end {
                lastDeeTurn?.end = now      // audio ends after the text: count from the last word heard
                lastActivityEnd = now
            }
        case .presence(arrived: false), .faceLost:
            if let person = m.ongoing.person { lastSeen[person] = now }
        case .presence(arrived: true):
            if let person = m.ongoing.person { fx += arrival(person, &m, &rng) }
        default:
            break
        }

        fx += revealTaste(&m, p)
        if m.ongoing.noteCandidates.contains(where: { $0.owner == Attention.name && [.deixisResolved, .deixisAmbiguous, .deixisUnknown].contains($0.kind) }) {
            raiseLesson(.wrongReferent, &m)
        }
        // Last time the person was actually perceived (not ticks while they are away).
        switch p {
        case .identified, .heard, .partial, .head, .touch, .gesture, .presence(arrived: true):
            if let person = m.ongoing.person { lastSeen[person] = now }
        default:
            break
        }
        previousHypotheses = m.ongoing.hypotheses
        fx += writeProfiles(&m, force: false)
        return fx
    }

    // MARK: - User turns

    mutating func heard(text: String, duration: Double, _ a: Appraisal, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        let now = m.now
        let start = userTurnStart ?? now.addingTimeInterval(-max(0, duration))
        let person = m.ongoing.person

        // Pause scale from this turn's within-turn pauses.
        if !turnPauses.isEmpty, person != nil {
            let sorted = turnPauses.sorted()
            let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            let before = m.profile.pauseScale
            updateProfile(&m) { $0 = Self.observePause($0, median: median) }
            if m.profile.pauseScale != before { fx.append(.setPauseScale(m.profile.pauseScale)) }
        }
        turnPauses = []
        pauseStart = nil

        // Silence comfort: only silences that follow Dee's own turn.
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = lastDeeTurn, let last = lastActivityEnd, last == t.end {
            let gap = start.timeIntervalSince(last)
            let newTopic = a.novelty >= 0.6 || (m.ongoing.topic.first.map { $0 != t.topic } ?? false)
            if Self.helloPhrases.contains(normalized), gap >= 3 {
                updateProfile(&m) { $0.silenceComfort = clamp01($0.silenceComfort - Self.silenceStep) }
            } else if gap > Self.comfortableSilence, newTopic {
                updateProfile(&m) { $0.silenceComfort = clamp01($0.silenceComfort + Self.silenceStep) }
            }
        }

        // Kindness prediction (EpisodeBuilder, earlier in the pipeline, read the old value).
        updateProfile(&m) { $0.kindnessEMA = clamp((1 - Self.kindnessAlpha) * $0.kindnessEMA + Self.kindnessAlpha * a.valence, -1, 1) }

        // Outcome of Dee's last (playful) turn.
        let laughed = a.humor >= 0.4
        if laughed, let t = lastDeeTurn, start.timeIntervalSince(t.end) <= Self.laughWindow { fx += laughter(&m, &rng) }
        if var t = lastDeeTurn, t.pending, now.timeIntervalSince(t.end) <= Self.outcomeWindow + max(0, duration) {
            t.pending = false
            lastDeeTurn = t
            if t.playful || t.gag != nil || t.anyPlayful {
                let good = laughed || t.laughed || a.valence > 0.2
                // Review finding 2: a neutral reply ("yeah so anyway…") is no evidence
                // either way. Only a clearly negative one is a flop, and a one-liner
                // (a single playful sentence) only with an explicit "not funny".
                let joke = t.playful || t.gag != nil
                let bad = !good && (joke ? Self.clearlyFlat(text: text, a) : RepairKeeper.saysNotFunny(text))
                if t.person == person, good || bad {
                    updateProfile(&m) { $0.humorReceptiveness = clamp01((1 - Self.humorAlpha) * $0.humorReceptiveness + Self.humorAlpha * (good ? 1 : 0)) }
                }
                if bad {
                    fx += record(Misread(id: rng.uuid(), person: t.person, at: now, situation: .jokeFlopped, topic: t.topic), &m, &rng)
                }
                // A callback that drew no laugh is flat for the gag (it retires after 2),
                // without counting as a misread unless the reply was clearly negative.
                if let g = t.gag, !t.laughed { fx += gagOutcome(g, laughed: good, &m) }
            }
        }

        // Interests and taste exposures (never for a topic they asked her to drop). A
        // distress turn lends no valence to anything: what they are upset about is not
        // something she dislikes (review finding 1).
        let distressed = a.distress >= Self.distressTurn || m.ongoing.distressLive(at: now)
        met.removeAll { now.timeIntervalSince($0.at) > Self.exposureWindow }
        if distressed {
            for s in m.ongoing.topic + met.map(\.subject) where !tainted.contains(s) { tainted.append(s) }
        }
        for s in m.ongoing.topic where !offLimits.contains(where: { $0.overlaps(s) }) {
            if !touched.contains(s) {
                touched.append(s)
                fx += touchInterest(s, &m)
            }
            if !distressed { addExposure(s, a.valence, sensed: false) }
        }
        if !distressed {
            for x in met where !m.ongoing.topic.contains(x.subject) && !offLimits.contains(where: { $0.overlaps(x.subject) }) {
                addExposure(x.subject, a.valence, sensed: true)
            }
        }

        // Rituals: goodnight.
        if Self.goodnightPhrases.contains(where: { normalized.contains($0) }), let person {
            fx += ritual(.goodnight, person: person, &m, &rng)
        }

        // Lesson notes when the situation recurs.
        if a.hostility >= 0.2 || a.sarcasm >= 0.3 { raiseLesson(.tookLiterally, &m) }
        let playfulness = Self.playfulness(m)
        if Self.playfulTags.contains(m.ongoing.mind.emotion) || Self.playfulTags.contains(m.ongoing.mind.reflex ?? .neutral) {
            if Self.lesson(.jokeFlopped, for: person, in: m.enduring) != nil {
                raiseLesson(.jokeFlopped, &m)
            } else if person != nil, m.profile.humorReceptiveness < 0.3, playfulness >= 0.6, !notedThisConversation.contains(.jokeFlopped) {
                notedThisConversation.append(.jokeFlopped)
                m.ongoing.raise(.lesson(Lesson.Situation.jokeFlopped.doInstead), by: Self.name)
            }
        }

        // Gag callbacks on a recurring topic.
        fx += considerCallback(&m, &rng)
        let hostility = m.inbox(for: Self.name).last { $0.name == "hostility" && $0.owner == Interpreter.name }?.value ?? a.hostility
        carryReunion(hostile: hostility >= RepairKeeper.hostileAt || a.threat >= RepairKeeper.hostileAt, &m)
        if m.ongoing.reunionTurn {
            if reunionTurnHeard { m.ongoing.reunionTurn = false } else { reunionTurnHeard = true }
        }

        lastActivityEnd = now
        userTurnStart = nil
        return fx
    }

    // MARK: - Dee's turns

    mutating func finishDeeTurn(_ m: inout Moment) {
        lastDeeTurn = DeeTurn(end: m.now, playful: turnPlayfulSentences >= Self.jokeSentences || callbackThisTurn != nil,
                              anyPlayful: turnPlayfulSentences > 0, asked: turnAsked,
                              topic: m.ongoing.topic.last, gag: callbackThisTurn, person: m.ongoing.person,
                              pending: true, laughed: false)
        turnActive = false
        turnPlayfulSentences = 0
        turnAsked = false
        callbackThisTurn = nil
        lastActivityEnd = m.now
    }

    /// Laughter (a sound, a laughing turn or a signal) within 15 s of Dee's last turn.
    mutating func laughter(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        guard var t = lastDeeTurn, !t.laughed, m.now.timeIntervalSince(t.end) <= Self.laughWindow else { return [] }
        t.laughed = true
        lastDeeTurn = t
        var fx: [Effect] = []
        if let g = t.gag { return gagOutcome(g, laughed: true, &m) }
        // A running joke belongs to someone: never one with an unknown speaker (review finding 9).
        guard let topic = t.topic, t.person != nil, !SensitiveSubjects.contains(topic) else { return fx }
        if let i = m.enduring.gags.firstIndex(where: { !$0.retired && $0.person == t.person && $0.topic.overlaps(topic) }) {
            m.enduring.gags[i].laughs += 1
            m.enduring.gags[i].flatStreak = 0
            fx.append(.persist(.gag(m.enduring.gags[i])))
            return fx
        }
        guard m.enduring.gags.filter({ !$0.retired }).count < Self.maxGags else { return fx }
        let hooks = Self.hookTable[m.enduring.humour]?.count ?? 1
        let g = Gag(id: rng.uuid(), person: t.person, topic: topic,
                    hookTemplate: Int(StableHash.of(topic.text, seed: m.enduring.seed) % UInt64(max(1, hooks))), laughs: 1)
        m.enduring.gags.append(g)
        bornThisConversation.append(g.id)
        m.signal("gagBorn", subject: topic, id: g.id, by: Self.name)
        fx.append(.persist(.gag(g)))
        return fx
    }

    mutating func gagOutcome(_ id: UUID, laughed: Bool, _ m: inout Moment) -> [Effect] {
        guard let i = m.enduring.gags.firstIndex(where: { $0.id == id }) else { return [] }
        if laughed {
            m.enduring.gags[i].laughs += 1
            m.enduring.gags[i].flatStreak = 0
        } else {
            m.enduring.gags[i].flatStreak += 1
        }
        if m.enduring.gags[i].flatStreak >= Self.gagRetireFlat || m.enduring.gags[i].uses >= Self.gagRetireUses {
            m.enduring.gags[i].retired = true
        }
        return [.persist(.gag(m.enduring.gags[i]))]
    }

    mutating func considerCallback(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let topic = m.ongoing.topic
        guard !topic.isEmpty, m.playGate, Self.playfulness(m) * m.profile.humorReceptiveness > Self.playGateThreshold(m) else { return [] }
        let now = m.now
        let person = m.ongoing.person
        let options = m.enduring.gags.filter { g in
            !g.retired && g.person == person && person != nil && !bornThisConversation.contains(g.id)
                && topic.contains { $0.overlaps(g.topic) }
                && (g.lastUsed.map { now.timeIntervalSince($0) >= Self.gagCooldown } ?? true)
        }
        guard let best = options.sorted(by: { ($0.laughs, $1.topic.text) > ($1.laughs, $0.topic.text) }).first else { return [] }
        guard rng.chance(Self.gagChance * Self.playfulness(m)) else { return [] }
        m.ongoing.raise(.gagCallback(best.topic, style: m.enduring.humour, hook: Self.hook(best, humour: m.enduring.humour), gag: best.id),
                        by: Self.name)
        return []
    }

    // MARK: - Misreads and lessons

    mutating func pruneMisreads(_ m: inout Moment) {
        let now = m.now
        m.ongoing.recentMisreads.removeAll { now.timeIntervalSince($0.at) > Self.misreadWindow }
    }

    /// Records a misread once, applies its parameter effect and mints / reinforces the lesson.
    mutating func record(_ r: Misread, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        if seenMisreads.contains(r.id) { return [] }
        if m.ongoing.recentMisreads.contains(where: { $0.person == r.person && $0.situation == r.situation
            && abs(r.at.timeIntervalSince($0.at)) < Self.duplicateMisreadWindow }) {
            seenMisreads = Array((seenMisreads + [r.id]).suffix(32))
            return []
        }
        seenMisreads = Array((seenMisreads + [r.id]).suffix(32))
        var stored = r
        stored.wrongGuess = nil
        m.ongoing.recentMisreads.append(stored)
        if !recurredThisConversation.contains(r.situation) { recurredThisConversation.append(r.situation) }
        var fx: [Effect] = [.persist(.misread(stored))]
        guard let person = r.person else { return fx }

        switch r.situation {
        case .moodGuess:
            updateProfile(&m, person) { $0.moodInferenceGain = max(Self.gainFloor, $0.moodInferenceGain * Self.gainPerCorrection) }
        case .interruptedThem:
            updateProfile(&m, person) { $0.pauseScale = clamp($0.pauseScale + Self.interruptPauseBump, Self.pauseRange.lowerBound, Self.pauseRange.upperBound) }
            if person == m.ongoing.person { fx.append(.setPauseScale(m.profile.pauseScale)) }
        default:
            break
        }

        if let i = m.enduring.lessons.firstIndex(where: { $0.person == person && $0.situation == r.situation }) {
            m.enduring.lessons[i].evidence += 1
            quietConversations[m.enduring.lessons[i].id] = 0
            fx.append(.persist(.lesson(m.enduring.lessons[i])))
        } else {
            let n = m.ongoing.recentMisreads.filter { $0.person == person && $0.situation == r.situation
                && m.now.timeIntervalSince($0.at) <= Self.misreadWindow }.count
            if n >= Self.mintAt {
                let l = Lesson(id: rng.uuid(), person: person, situation: r.situation, evidence: Self.mintAt, createdAt: m.now)
                m.enduring.lessons.append(l)
                m.signal("lessonMinted", id: l.id, label: r.situation.rawValue, by: Self.name)
                fx.append(.persist(.lesson(l)))
            }
        }
        return fx
    }

    /// Raises `(Careful: {doInstead}.)` once per lesson per conversation.
    mutating func raiseLesson(_ s: Lesson.Situation, _ m: inout Moment) {
        if !recurredThisConversation.contains(s), s != .jokeFlopped { recurredThisConversation.append(s) }
        guard !notedThisConversation.contains(s), let l = Self.lesson(s, for: m.ongoing.person, in: m.enduring) else { return }
        guard s != .interruptedThem, s != .askedTooMuch else { return }   // timing / threshold only
        notedThisConversation.append(s)
        m.ongoing.raise(.lesson(l.doInstead), by: Self.name)
    }

    /// New hypotheses since the last step: inferred mood (lesson note), confirmation
    /// (gain +0.02), busy / wantsQuiet after Dee's questions (askedTooMuch).
    mutating func watchHypotheses(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        let now = m.now
        let fresh = m.ongoing.hypotheses.filter { h in
            now < h.expires && !previousHypotheses.contains { $0.kind == h.kind && $0.value == h.value && $0.stated == h.stated }
        }
        for h in fresh {
            switch h.kind {
            case .mood where !h.stated:
                raiseLesson(.moodGuess, &m)
            case .mood:
                if previousHypotheses.contains(where: { $0.kind == .mood && !$0.stated && $0.value == h.value && now < $0.expires }) {
                    fx += confirmMood(&m)
                }
            case .busy, .wantsQuiet:
                if let t = lastDeeTurn, t.asked, now.timeIntervalSince(t.end) <= Self.askedTooMuchWindow {
                    fx += record(Misread(id: rng.uuid(), person: m.ongoing.person, at: now, situation: .askedTooMuch,
                                         topic: m.ongoing.topic.last), &m, &rng)
                }
            case .goal:
                break
            }
        }
        return fx
    }

    mutating func confirmMood(_ m: inout Moment) -> [Effect] {
        updateProfile(&m) { $0.moodInferenceGain = min(1, $0.moodInferenceGain + Self.gainPerConfirmation) }
        return []
    }

    // MARK: - Profiles

    /// One pause observation: EWMA α 0.1 behind a 10-observation shrinkage prior at 1.0.
    /// `pauseScale` stores the shrunk value; the raw EWMA is recovered from it and `pauseN`.
    public static func observePause(_ p: SocialProfile, median: TimeInterval) -> SocialProfile {
        var q = p
        let x = clamp(median / pauseBase, pauseRange.lowerBound, pauseRange.upperBound)
        let n = Double(p.pauseN)
        let raw = p.pauseN == 0 ? x : (1 - pauseAlpha) * ((p.pauseScale * (n + pausePrior) - pausePrior) / n) + pauseAlpha * x
        q.pauseN = p.pauseN + 1
        let n1 = Double(q.pauseN)
        q.pauseScale = clamp((n1 * raw + pausePrior) / (n1 + pausePrior), pauseRange.lowerBound, pauseRange.upperBound)
        return q
    }

    mutating func updateProfile(_ m: inout Moment, _ person: PersonID? = nil, _ change: (inout SocialProfile) -> Void) {
        guard let id = person ?? m.ongoing.person else { return }   // unknown people never learn
        var p = m.enduring.profiles[id] ?? SocialProfile()
        let before = p
        change(&p)
        guard p != before else { return }
        m.enduring.profiles[id] = p
        if !dirtyProfiles.contains(id) { dirtyProfiles.append(id) }
    }

    mutating func writeProfiles(_ m: inout Moment, force: Bool) -> [Effect] {
        var fx: [Effect] = []
        let now = m.now
        for id in dirtyProfiles.sorted(by: { $0.uuidString < $1.uuidString }) {
            if !force, let last = lastProfileWrite[id], now.timeIntervalSince(last) < Self.profileWriteInterval { continue }
            if let p = m.enduring.profiles[id] { fx.append(.persist(.profile(id, p))) }
            lastProfileWrite[id] = now
            dirtyProfiles.removeAll { $0 == id }
        }
        return fx
    }

    // MARK: - Interests

    /// The interest's weight decayed to `now` (7 d half-life from `lastTouched`).
    public static func interestWeight(_ i: Interest, at now: Date) -> Double {
        i.weight * halfLife(now.timeIntervalSince(i.lastTouched), interestHalfLife)
    }

    mutating func touchInterest(_ s: Subject, _ m: inout Moment) -> [Effect] {
        let now = m.now
        let gain = Self.interestPerTouch * clamp01(m.ongoing.mind.mood.curiosity)
        var item: Interest
        if let i = m.ongoing.interests.firstIndex(where: { $0.subject == s }) {
            item = m.ongoing.interests.remove(at: i)
            item.weight = clamp01(Self.interestWeight(item, at: now) + gain)
            item.lastTouched = now
        } else {
            item = Interest(subject: s, weight: clamp01(gain), lastTouched: now)
        }
        m.ongoing.interests.append(item)
        if m.ongoing.interests.count > Ongoing.maxInterests {
            m.ongoing.interests = Array(m.ongoing.interests
                .sorted { (Self.interestWeight($0, at: now), $1.subject.text) > (Self.interestWeight($1, at: now), $0.subject.text) }
                .prefix(Ongoing.maxInterests))
        }
        return m.ongoing.interests.contains(item) ? [.persist(.interest(item))] : []
    }

    // MARK: - Tastes

    static func tasteSubject(_ label: String) -> Subject? {
        guard !isLaughter(label), let s = Subject(label.replacingOccurrences(of: "_", with: " ")), !notTastes.contains(s.text) else { return nil }
        return s
    }

    /// A subject Dee may hold a taste about (review finding 1): never people, health,
    /// death or other sensitive subjects; from conversation topics only within the
    /// seeder's taste categories (animals, nature, music, machines), from what she sees
    /// or hears otherwise.
    public static func tasteable(_ s: Subject, sensed: Bool) -> Bool {
        guard !notTastes.contains(s.text), !SensitiveSubjects.contains(s) else { return false }
        return sensed || SelfSeeder.category(of: s) != .other
    }

    mutating func meet(_ label: String, at now: Date, _ m: inout Moment) {
        guard let s = Self.tasteSubject(label), Self.tasteable(s, sensed: true) else { return }
        met.removeAll { $0.subject == s }
        met.append((s, now))
        if met.count > 24 { met.removeFirst(met.count - 24) }
    }

    mutating func addExposure(_ s: Subject, _ v: Double, sensed: Bool) {
        guard Self.tasteSubject(s.text) != nil, Self.tasteable(s, sensed: sensed), v.isFinite else { return }
        if let i = exposures.firstIndex(where: { $0.subject == s }) {
            guard !exposures[i].fromEpisode else { return }
            exposures[i].sum += v
            exposures[i].n += 1
        } else {
            exposures.append(Exposure(subject: s, sum: v, n: 1, fromEpisode: false))
        }
    }

    mutating func episodeExposure(_ s: Subject, valence v: Double) {
        guard v.isFinite else { return }
        if let i = exposures.firstIndex(where: { $0.subject == s }) {
            if exposures[i].fromEpisode {
                exposures[i].sum += v
                exposures[i].n += 1
            } else {
                exposures[i] = Exposure(subject: s, sum: v, n: 1, fromEpisode: true)
            }
        } else {
            exposures.append(Exposure(subject: s, sum: v, n: 1, fromEpisode: true))
        }
    }

    /// One exposure per subject per conversation: learned EMA, crystallisation, flips.
    mutating func closeTastes(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx: [Effect] = []
        let list = exposures.sorted { $0.subject < $1.subject }
        exposures = []
        met = []
        for e in list where e.n > 0 && !exposedThisConversation.contains(e.subject) && !tainted.contains(where: { $0.overlaps(e.subject) }) {
            let v = clamp(e.sum / Double(e.n), -1, 1)
            guard abs(v) > Self.tasteMinValence else { continue }
            exposedThisConversation.append(e.subject)
            if let f = expose(e.subject, valence: v, &m, &rng) { fx.append(.persist(.facet(f))) }
        }
        return fx
    }

    /// Applies one counted exposure to the taste for `s` (created from the innate value
    /// on first use); returns the changed facet.
    public mutating func expose(_ s: Subject, valence v: Double, _ m: inout Moment, _ rng: inout Rand) -> Facet? {
        let now = m.now
        var f: Facet
        let index = m.enduring.facets.firstIndex { $0.kind == .taste && $0.subject == s }
        if let index {
            f = m.enduring.facets[index]
        } else {
            guard m.enduring.facets.filter({ $0.kind == .taste }).count < Self.maxTasteFacets else { return nil }
            let innate = SelfSeeder.innateTaste(s, seed: m.enduring.seed, personality: m.ongoing.mind.code.personality)
            f = Facet(id: rng.uuid(), kind: .taste, subject: s, innate: innate, source: .heuristic, updatedAt: now)
        }
        f = Self.applyExposure(f, valence: v)
        f.updatedAt = now
        let wasCrystallised = index.map { m.enduring.facets[$0].crystallised } ?? false
        if f.crystallised, !wasCrystallised { m.signal("tasteCrystallised", subject: s, value: f.polarity, by: Self.name) }
        if let index { m.enduring.facets[index] = f } else { m.enduring.facets.append(f) }
        return f
    }

    /// The pure taste rule (§7.9): EMA α 0.3, polarity ½·innate + ½·learned,
    /// crystallise at evidence ≥ 3 and |polarity| ≥ 0.35, flip after 3 contrary exposures.
    public static func applyExposure(_ facet: Facet, valence v: Double) -> Facet {
        var f = facet
        f.learned = clamp((1 - tasteAlpha) * f.learned + tasteAlpha * v, -1, 1)
        f.evidence += 1
        let target = 0.5 * f.innate + 0.5 * f.learned
        if !f.crystallised {
            f.polarity = target
            if f.evidence >= crystalliseEvidence, abs(f.polarity) >= crystallisePolarity {
                f.crystallised = true
                f.contrary = 0
                f.reason = reason(f)
            }
            return f
        }
        let sign: Double = f.polarity >= 0 ? 1 : -1
        if v * sign < 0 {
            f.contrary += 1
        } else {
            f.contrary = max(0, f.contrary - 1)
        }
        if target * sign >= 0 {
            f.polarity = target
        } else if f.contrary >= flipAfter {
            // A real change of heart: the new sign, latent again until she says so.
            f.polarity = target
            f.contrary = 0
            f.revealedAt = nil
            f.crystallised = abs(target) >= crystallisePolarity
            f.reason = f.crystallised ? reason(f) : nil
        }
        // Otherwise hold the crystallised sign (hysteresis).
        return f
    }

    /// Template reason from the strongest contributor (≤ 8 words).
    static func reason(_ f: Facet) -> String {
        if abs(f.innate) >= abs(f.learned) { return "no idea why, you just do" }
        return f.learned >= 0 ? "it has always gone nicely" : "it has gone badly before"
    }

    /// A crystallised taste never revealed, matching the topic or focus: one reveal per conversation.
    mutating func revealTaste(_ m: inout Moment, _ p: Percept) -> [Effect] {
        switch p {
        case .heard, .sight, .sound: break
        default: return []
        }
        guard !m.ongoing.revealedThisConversation, !tasteRaisedThisStep,
              !m.ongoing.noteCandidates.contains(where: { $0.kind == .tasteReveal }) else { return [] }
        var here = m.ongoing.topic
        switch m.momentary.focus {
        case .referent(let s, _), .sound(let s): here.append(s)
        default: break
        }
        guard !here.isEmpty else { return [] }
        let candidates = m.enduring.facets.filter { f in
            f.kind == .taste && f.crystallised && f.revealedAt == nil && !SensitiveSubjects.contains(f.subject)
                && here.contains { $0.overlaps(f.subject) }
        }
        guard let f = candidates.sorted(by: { (abs($0.polarity) * Double($0.evidence), $1.subject.text) > (abs($1.polarity) * Double($1.evidence), $0.subject.text) }).first
        else { return [] }
        tasteRaisedThisStep = true
        m.ongoing.raise(.tasteReveal(f.subject, loves: f.polarity > 0, facet: f.id), by: Self.name)
        return []
    }

    // MARK: - Rituals

    func localDay(_ d: Date) -> Int { Int(((d.timeIntervalSince1970 + utcOffset) / Self.day).rounded(.down)) }
    func localHour(_ d: Date) -> Int {
        let s = (d.timeIntervalSince1970 + utcOffset).truncatingRemainder(dividingBy: Self.day)
        return Int(((s < 0 ? s + Self.day : s) / 3600).rounded(.down))
    }

    /// True once a ritual has been born (3 consecutive days); before that it is only tracked.
    public static func isBorn(_ r: Ritual) -> Bool { r.count >= 1 }

    mutating func arrival(_ person: PersonID, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        let seen = lastSeen[person]
        considerReunion(person, previous: [seen, carriedContact[person]].compactMap { $0 }.max(), &m)
        let today = localDay(now)
        let ritualSeenToday = m.enduring.rituals.contains { $0.person == person && $0.trigger == .firstSightOfDay && $0.lastDone.map(localDay) == today }
        let seenToday = seen.map { localDay($0) == today } ?? false
        if !seenToday, !ritualSeenToday {
            lastSeen[person] = now
            return localHour(now) < Self.ritualMorningHour ? ritual(.firstSightOfDay, person: person, &m, &rng) : []
        }
        if let seen, now.timeIntervalSince(seen) >= Self.returnHomeAway {
            lastSeen[person] = now
            return ritual(.returnHome, person: person, &m, &rng)
        }
        return []
    }

    mutating func ritual(_ trigger: Ritual.Trigger, person: PersonID, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        let today = localDay(now)
        var r: Ritual
        let index = m.enduring.rituals.firstIndex { $0.person == person && $0.trigger == trigger }
        if let index {
            r = m.enduring.rituals[index]
        } else {
            let variants = Self.ritualPhrases[trigger]?[m.enduring.humour]?.count ?? 4
            let variant = Int(StableHash.of("\(trigger.rawValue)|\(m.enduring.humour.rawValue)", seed: m.enduring.seed) % UInt64(max(1, variants)))
            let first = m.enduring.signature.repertoire[.greeting]?.first?.mannerism ?? .nod
            r = Ritual(id: rng.uuid(), person: person, trigger: trigger, variant: variant, mannerism: first)
        }
        if let last = r.lastDone, localDay(last) == today { return [] }
        r.streak = r.lastDone.map { localDay($0) == today - 1 } == true ? r.streak + 1 : 1   // a broken streak resets silently
        r.lastDone = now
        var perform = false
        if Self.isBorn(r) {
            r.count += 1
            perform = true
        } else if r.streak >= Self.ritualStreakToBirth {
            r.count = 1
            r.mannerism = m.enduring.signature.pick(.greeting, energy: m.ongoing.mind.mood.energy, playGate: m.playGate,
                                                     recent: [], rng: &rng) ?? r.mannerism
            perform = true
        }
        if let index { m.enduring.rituals[index] = r } else { m.enduring.rituals.append(r) }
        var fx: [Effect] = [.persist(.ritual(r))]
        let upset = m.ongoing.repair != .fine || m.ongoing.mind.regard < -0.3 || m.ongoing.distressLive(at: now)
        if perform, !upset {
            m.momentary.requestMannerism(r.mannerism, rank: .reaction, by: Self.name)
            m.signal("ritual", id: r.id, label: trigger.rawValue, by: Self.name)
            if trigger == .goodnight {
                // Raised now, with the reply to their goodnight, not a step later (a
                // late aim made her say goodnight twice when they kept talking).
                m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .intention }
                m.ongoing.raise(.intention(nextAction: Self.goodnightAction, intention: r.id), by: Self.name)
            } else if case .idle = m.momentary.floor, let line = Self.phrase(r, humour: m.enduring.humour) {
                fx.append(.say(line))
            }
        }
        return fx
    }

    /// Back after more than a day (last contact from this launch or the store): the
    /// reunion note and the `"reunion"` signal (Beats' glad bounce). Never while a
    /// rupture is open or they are upset; CueWriter drops "lonely" from the mood while
    /// the note is a candidate (review finding 3).
    mutating func considerReunion(_ person: PersonID, previous: Date?, _ m: inout Moment) {
        guard let previous, m.now.timeIntervalSince(previous) > Self.reunionAbsence, reunion?.person != person else { return }
        // A reunion turn whatever the note's fate: no "lonely" in the mood (§9).
        m.ongoing.reunionTurn = true
        reunionTurnHeard = false
        guard m.ongoing.repair == .fine || m.ongoing.repair == .reconciled, !m.ongoing.distressLive(at: m.now) else { return }
        reunion = (person, 1)
        m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .reunion }
        m.ongoing.raise(.reunion(), by: Self.name)
        m.signal("reunion", by: Self.name)
    }

    /// Keeps the reunion note through the first user turn, then lets it go. A hostile
    /// first turn (an insult, shouting: RepairKeeper's rupture, or the turn's hostility)
    /// drops it: "be glad to see them" must not answer "YOU ARE SO USELESS"; repair wins.
    mutating func carryReunion(hostile: Bool, _ m: inout Moment) {
        guard let r = reunion else { return }
        let quarrel = m.ongoing.repair == .ruptured || m.ongoing.repair == .repairing
        guard r.person == m.ongoing.person, r.turns > 0, !hostile, !quarrel else {
            reunion = nil
            m.ongoing.noteCandidates.removeAll { $0.owner == Self.name && $0.kind == .reunion }
            return
        }
        reunion = (r.person, r.turns - 1)
        if !m.ongoing.noteCandidates.contains(where: { $0.owner == Self.name && $0.kind == .reunion }) {
            m.ongoing.raise(.reunion(), by: Self.name)
        }
    }

    public static func phrase(_ r: Ritual, humour: HumourStyle) -> String? {
        guard let list = ritualPhrases[r.trigger]?[humour], !list.isEmpty else { return nil }
        return list[abs(r.variant) % list.count]
    }

    // MARK: - Conversation boundaries

    mutating func closeConversation(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx = closeTastes(&m, &rng)
        // Lessons that did not recur with someone present lose evidence every 5 conversations.
        var kept: [Lesson] = []
        for var l in m.enduring.lessons {
            guard let person = l.person, peopleThisConversation.contains(person), !recurredThisConversation.contains(l.situation) else {
                kept.append(l)
                continue
            }
            let q = (quietConversations[l.id] ?? 0) + 1
            if q >= Self.quietConversationsPerDecay {
                quietConversations[l.id] = 0
                l.evidence -= 1
                if l.evidence < 1 {
                    quietConversations[l.id] = nil
                    fx.append(.persist(.deleteLesson(l.id)))
                    continue
                }
                fx.append(.persist(.lesson(l)))
            } else {
                quietConversations[l.id] = q
            }
            kept.append(l)
        }
        m.enduring.lessons = kept
        return fx
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.revealedThisConversation = false
        touched = []
        exposedThisConversation = []
        notedThisConversation = []
        recurredThisConversation = []
        peopleThisConversation = m.ongoing.person.map { [$0] } ?? []
        bornThisConversation = []
        lastDeeTurn = nil
        turnActive = false
        turnPlayfulSentences = 0
        turnAsked = false
        callbackThisTurn = nil
        tainted = []
        if let r = reunion, r.person != m.ongoing.person { reunion = nil }
        if reunion == nil {
            m.ongoing.reunionTurn = false
            reunionTurnHeard = false
        }
        turnPauses = []
        pauseStart = nil
        userTurnStart = nil
        lastActivityEnd = nil
        return []
    }

    // MARK: - Hooks

    public mutating func seed(from c: Carried, _ m: inout Moment) {
        carriedContact = c.lastContact
        m.ongoing.interests = c.interests
        m.ongoing.recentMisreads = c.misreads
        seenMisreads = Array(c.misreads.map(\.id).suffix(32))
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        switch n.kind {
        case .reunion:
            reunion = nil
            return []
        case .tasteReveal:
            m.ongoing.revealedThisConversation = true
            guard let id = n.facet, let i = m.enduring.facets.firstIndex(where: { $0.id == id }),
                  m.enduring.facets[i].revealedAt == nil else { return [] }
            m.enduring.facets[i].revealedAt = m.now
            m.enduring.facets[i].updatedAt = m.now
            return [.persist(.facet(m.enduring.facets[i]))]
        case .gagCallback:
            guard let id = n.gag, let i = m.enduring.gags.firstIndex(where: { $0.id == id }) else { return [] }
            m.enduring.gags[i].uses += 1
            m.enduring.gags[i].lastUsed = m.now
            if m.enduring.gags[i].uses >= Self.gagRetireUses { m.enduring.gags[i].retired = true }
            callbackThisTurn = id
            return [.persist(.gag(m.enduring.gags[i]))]
        case .lesson where n.owner == Self.name:
            let person = m.ongoing.person
            guard let text = n.slots.first,
                  let i = m.enduring.lessons.firstIndex(where: { $0.doInstead == text && ($0.person == person || $0.person == nil) })
            else { return [] }
            m.enduring.lessons[i].lastApplied = m.now
            return [.persist(.lesson(m.enduring.lessons[i]))]
        default:
            return []
        }
    }

    public mutating func flush(_ m: inout Moment) -> [Effect] { writeProfiles(&m, force: true) }

    /// Background, sleep or quit: this conversation's taste exposures are counted now
    /// (a quit would lose them), at most once per subject per conversation.
    public mutating func flush(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        closeTastes(&m, &rng) + writeProfiles(&m, force: true)
    }

    public mutating func forget(subject s: Subject, _ m: inout Moment) {
        exposures.removeAll { $0.subject.overlaps(s) }
        met.removeAll { $0.subject.overlaps(s) }
        touched.removeAll { $0.overlaps(s) }
        if lastDeeTurn?.topic?.overlaps(s) == true { lastDeeTurn?.topic = nil }
        let gags = m.enduring.gags.map(\.id)
        bornThisConversation.removeAll { !gags.contains($0) }
        if let g = callbackThisTurn, !gags.contains(g) { callbackThisTurn = nil }
        if let g = lastDeeTurn?.gag, !gags.contains(g) { lastDeeTurn?.gag = nil }
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        dirtyProfiles.removeAll { $0 == id }
        lastProfileWrite[id] = nil
        lastSeen[id] = nil
        peopleThisConversation.removeAll { $0 == id }
        if previousPerson == id { previousPerson = m.ongoing.person }
        if lastDeeTurn?.person == id { lastDeeTurn = nil }
        let lessons = m.enduring.lessons.map(\.id)
        for k in quietConversations.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !lessons.contains(k) { quietConversations[k] = nil }
        let gags = m.enduring.gags.map(\.id)
        bornThisConversation.removeAll { !gags.contains($0) }
        if let g = callbackThisTurn, !gags.contains(g) { callbackThisTurn = nil }
    }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        if dirtyProfiles.contains(from) {
            dirtyProfiles.removeAll { $0 == from }
            if !dirtyProfiles.contains(into) { dirtyProfiles.append(into) }
        }
        if let w = lastProfileWrite.removeValue(forKey: from) { lastProfileWrite[into] = max(w, lastProfileWrite[into] ?? w) }
        if let s = lastSeen.removeValue(forKey: from) { lastSeen[into] = max(s, lastSeen[into] ?? s) }
        if let i = peopleThisConversation.firstIndex(of: from) {
            peopleThisConversation.remove(at: i)
            if !peopleThisConversation.contains(into) { peopleThisConversation.append(into) }
        }
        if previousPerson == from { previousPerson = into }
        if lastDeeTurn?.person == from { lastDeeTurn?.person = into }
        let lessons = m.enduring.lessons.map(\.id)
        for k in quietConversations.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !lessons.contains(k) { quietConversations[k] = nil }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        let contact = carriedContact
        self = Learner(utcOffset: utcOffset)
        carriedContact = contact
        previousPerson = m.ongoing.person
    }

    // MARK: - Published parameters (D6): other reducers read these

    /// The lesson of `situation` for `person` (their own, else a general one), evidence ≥ 1.
    public static func lesson(_ situation: Lesson.Situation, for person: PersonID?, in e: Enduring) -> Lesson? {
        e.lessons.first { $0.situation == situation && $0.evidence >= 1 && person != nil && $0.person == person }
            ?? e.lessons.first { $0.situation == situation && $0.evidence >= 1 && $0.person == nil }
    }

    /// Interpreter: a hypothesis note needs confidence ≥ factor × moodInferenceGain (0.5; 0.6 after a moodGuess lesson).
    public static func hypothesisNoteFactor(_ m: Moment) -> Double {
        lesson(.moodGuess, for: m.ongoing.person, in: m.enduring) == nil ? 0.5 : 0.6
    }

    /// Attention: the deixis "resolved" threshold (0.5; 0.65 after a wrongReferent lesson).
    public static func deixisResolvedThreshold(_ m: Moment) -> Double {
        lesson(.wrongReferent, for: m.ongoing.person, in: m.enduring) == nil ? 0.5 : 0.65
    }

    /// Interpreter (`adjust`): how much of a teasing turn's hostility to drop after play
    /// signals (0.5 with a tookLiterally lesson, else 0).
    public static func hostilitySoftening(_ m: Moment) -> Double {
        lesson(.tookLiterally, for: m.ongoing.person, in: m.enduring) == nil ? 0 : 0.5
    }

    /// IntentionBoard: added to the initiative threshold (0.1 after an askedTooMuch lesson).
    public static func initiativeThresholdBoost(_ m: Moment) -> Double {
        lesson(.askedTooMuch, for: m.ongoing.person, in: m.enduring) == nil ? 0 : 0.1
    }

    /// IntentionBoard / curiosity: gap multiplier (1.3 after an askedTooMuch lesson).
    public static func curiosityGapScale(_ m: Moment) -> Double {
        lesson(.askedTooMuch, for: m.ongoing.person, in: m.enduring) == nil ? 1 : 1.3
    }

    /// The playfulness·humorReceptiveness threshold (0.3; 0.4 after a jokeFlopped lesson).
    public static func playGateThreshold(_ m: Moment) -> Double {
        lesson(.jokeFlopped, for: m.ongoing.person, in: m.enduring) == nil ? 0.3 : 0.4
    }

    static func playfulness(_ m: Moment) -> Double {
        m.ongoing.effectivePersonality[.playfulness]
    }

    static func isLaughter(_ label: String) -> Bool { Laughter.isLaughter(label) }

    /// A reply that clearly did not enjoy the joke: negative, hostile, dismissive or
    /// "not funny". A neutral reply is no evidence (review finding 2).
    public static func clearlyFlat(text: String, _ a: Appraisal) -> Bool {
        if RepairKeeper.saysNotFunny(text) { return true }
        return a.valence < -0.2 || a.hostility >= 0.3 || a.dismissal >= 0.3
    }

    /// The gag's hook, rendered for the callback note ("the dentist incident"), so the
    /// model has the joke itself to refer to (review finding 9).
    public static func hook(_ g: Gag, humour: HumourStyle) -> String? {
        guard let list = hookTable[humour], !list.isEmpty else { return nil }
        let text = list[abs(g.hookTemplate) % list.count].replacingOccurrences(of: "{t}", with: g.topic.text)
        return text.count <= NoteTemplates.slotCaps(.gagCallback)[2] ? text : nil
    }

    // MARK: - Traces

    public static func slice(of m: Moment) -> [String: String] {
        let now = m.now
        let f2 = { (x: Double) in String(format: "%.2f", x) }
        let p = m.profile
        return [
            "interests": m.ongoing.interests.map { "\($0.subject.text):\(f2(interestWeight($0, at: now)))" }.joined(separator: ","),
            "misreads": m.ongoing.recentMisreads.map(\.situation.rawValue).joined(separator: ","),
            "lessons": m.enduring.lessons.map { "\($0.situation.rawValue):\($0.evidence)" }.joined(separator: ","),
            "profile": "pause \(f2(p.pauseScale))/\(p.pauseN) humor \(f2(p.humorReceptiveness)) gain \(f2(p.moodInferenceGain)) "
                + "silence \(f2(p.silenceComfort)) kind \(f2(p.kindnessEMA))",
            "tastes": m.enduring.facets.filter { $0.kind == .taste }.map {
                "\($0.subject.text):\(f2($0.polarity))/\($0.evidence)\($0.crystallised ? "*" : "")\($0.revealedAt == nil ? "" : "!")"
            }.joined(separator: ","),
            "gags": m.enduring.gags.map { "\($0.topic.text):u\($0.uses)l\($0.laughs)f\($0.flatStreak)\($0.retired ? "x" : "")" }.joined(separator: ","),
            "rituals": m.enduring.rituals.map { "\($0.trigger.rawValue):s\($0.streak)c\($0.count)" }.joined(separator: ","),
            "revealed": String(m.ongoing.revealedThisConversation),
            "notes": m.ongoing.noteCandidates.filter { $0.owner == name }.map(\.kind.rawValue).joined(separator: ","),
        ]
    }
}
