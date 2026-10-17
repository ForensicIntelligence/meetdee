import DeeCore
import DeeMind
import Foundation

/// Sub-reducer 8 — episodes built without text, and recall (SELF.md §7.10).
///
/// Owns: the per-conversation accumulator (`Segment`), `SelfWrite.episode` / `.digest`
/// at boundaries, appending new keys to `enduring.episodeIndex` (≤ 300) and
/// `episodeIndex.recalled`; `.reflect` scheduling (§8.1).
/// Raises: the recall note (`Note.recall`, own gates below); requests the `recognize`
/// beat on a recall hit.
/// Reads (never text): the appraisal of each user turn, mind before / after, `topic`,
/// `person`, the profile's `kindnessEMA`, expectations, intentions, `misreadThisTurn`,
/// `repair`, gags, beats, referents / focus, sight / sound / touch percepts.
///
/// **Accumulator.** A segment collects, per user turn, the appraisal's kindness (the
/// quantity `kindnessEMA` predicts), distress and humour, the topics (≤ 3), and the
/// events of the segment: things shown (back camera / held up), novel sights, unexpected
/// sounds, gentle touches, laughter, plans made (new expectation + its follow-up
/// intention = the open loop), follow-ups resolved, a misread, repair transitions and a
/// gag born. Nothing the user said is held, only labels, subjects and numbers.
///
/// **Segmenting.** A segment closes at a topic change (the new turn's topics share no
/// word with the segment's), at a change of speaker, when a show-and-tell beat chain
/// (examine / recognize / brighten) completes, and at conversation end (the next
/// `.conversationStarted`, or asleep ≥ 300 s). A segment with no user turn is dropped.
/// At most 3 episodes are persisted per conversation; a 4th more salient one replaces
/// the least salient (`deleteEpisode` + `episode`), the loser counts as low salience.
///
/// **Salience** = |Δregard|·2 + surprise + novelty + 0.5·[distress] + 0.5·[laughter]
/// + [followUp] + [misread], where surprise = max over turns of |kindnessEMA − kindness|
/// and novelty = 0.3 × the share of topics no indexed episode has (calibrated: a new
/// topic alone must not persist an episode). ≥ 0.4 → `.persist(.episode)`; lower →
/// `.persist(.digest(lowSalience: 1))`. Each conversation with ≥ 1 user turn adds
/// `.digest(conversations: 1)`. Days are local (`utcOffset`) `yyyy-MM-dd`.
///
/// **Gist** (≤ 100 chars, slots only; "they" for an identified person, "someone"
/// otherwise — DeeSelf holds no names): followUp "they told me how their {subject}
/// went"; misread "I misread them: thought they were {x}" / per situation; repair "we
/// made up after {topic}"; shown "they showed me a {thing}"; plan "they told me
/// about their upcoming {subject}" (no time words: it is recalled later); play "we
/// talked about {topic}; they laughed a lot"; discovery
/// "I saw a {thing} for the first time"; else "we talked about {topics}".
/// **why** (≤ 8 words) comes from the largest feeling delta over the segment; **expected**
/// / **changed** are filled for follow-ups (expected = the framing) and misreads.
///
/// **Recall.** On each user turn and each novel sight: query = topic ∪ focus label ∪
/// held-up referents ∪ the novel labels; score = jaccard(tags, query) × salience ×
/// exp(−days/30) × (recalled < 3 ? 1 : 0.5) over index keys of this person (keys of
/// nobody in particular only while nobody is identified), not persisted in this
/// conversation and whose gist is known; the best ≥ 0.35 raises the recall note (own
/// gates: one issued recall per 4 user turns, never the same episode within 2 days).
/// Only when NotePicker issues it does `noteIssued` request the `recognize` beat (once
/// per episode per conversation) and signal "recallHit": the face never remembers what
/// the words do not say. Quarrels, misreads and sad episodes (valence < −0.2) are never
/// citable. Gists are known for episodes built this launch and for bodies handed to
/// `prefetch(_:)`.
///
/// **Reflection** (§8.1): `.reflect` after a conversation of ≥ 4 user turns ends, once
/// per sleep (asleep ≥ 300 s) and once per 6 h of awake time. The app runs `Reflector`.
///
/// Signals raised: "recallHit" (id, subject = matched topic, value = score),
/// "episodeClosed" (one per topic; id when persisted, value = valence, label = kind).
/// Signals read: "laughter", "beatFinished", "expectationResolved" / "followUpResolved"
/// (id, value = outcome valence, subject).
public struct EpisodeBuilder: SubReducer {
    public static let name = "EpisodeBuilder"

    // MARK: Tunables (SELF.md §7.10, §8.1)

    public static let persistThreshold = 0.4
    public static let maxEpisodesPerConversation = 3
    public static let noveltyWeight = 0.3
    public static let distressThreshold = 0.5
    public static let humourLaughThreshold = 0.5
    public static let recallThreshold = 0.35
    public static let recallEveryTurns = 4
    public static let recallSameEpisodeCooldown: TimeInterval = 2 * 86_400
    public static let recallTimescaleDays = 30.0
    public static let recognizeBeatPriority = 0.6
    public static let sleepEndsConversation: TimeInterval = 300
    public static let reflectAfterAwake: TimeInterval = 6 * 3600
    public static let reflectAfterTurns = 4
    /// Gaps between percepts longer than this (backgrounded app) count only this much awake time.
    public static let maxAwakeStep: TimeInterval = 300
    public static let feelingDeltaFloor = 0.05
    public static let maxWords = 8
    public static let maxPhrase = 60
    /// Show-and-tell beats whose completion closes a segment.
    public static let showBeats: Set<Beat.Kind> = [.examine, .recognize, .brighten]
    /// Wrong-guess labels safe to store in a misread gist (lexicon, not user text).
    public static let safeGuessLabels: Set<String> = Hypothesis.distressValues.union(
        ["tired", "happy", "busy", "bored", "excited", "fine", "nervous", "annoyed", "joking", "serious", "proud", "calm"])

    // MARK: State (RAM only)

    /// One open stretch of a conversation, without text.
    public struct Segment: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var person: PersonID?
        public var mindBefore: MindCode
        public var regardBefore: Double
        public var turns = 0
        public var kindnessSum = 0.0
        public var surprise = 0.0
        public var distress = false
        public var laughs = 0
        public var topics: [Subject] = []
        public var shown: [Subject] = []
        public var seen: [Subject] = []
        public var sounds: [Subject] = []
        public var touches = 0
        public var plans: [Expectation] = []
        public var followUps: [Expectation] = []
        public var misread: Misread?
        public var reconciled = false
        public var ruptured = false
        public var gagTopic: Subject?
        public var openLoop: UUID?

        public init(start: Date, person: PersonID?, mind: MindSnapshot) {
            self.start = start
            end = start
            self.person = person
            mindBefore = mind.code
            regardBefore = mind.regard
        }

        /// Every subject the segment is about (topics first), ≤ 3.
        public var tags: [Subject] { Array(EpisodeBuilder.union(topics, shown, plans.map(\.subject), followUps.map(\.subject),
                                                                gagTopic.map { [$0] } ?? [], seen).prefix(3)) }
    }

    public private(set) var segment: Segment?
    public private(set) var conversationMindBefore: MindCode?
    /// User turns this conversation.
    public private(set) var userTurns = 0
    /// User turns since launch (recall spacing).
    public private(set) var totalTurns = 0
    /// Episodes persisted this conversation (≤ 3).
    public private(set) var persistedThisConversation: [EpisodeKey] = []
    /// This conversation's `digest(conversations: 1)` was already written (by `flush`).
    var conversationCounted = false
    /// The last episode built (persisted or not), for tests and traces.
    public private(set) var lastEpisode: Episode?
    /// Gists of episodes this reducer can cite (built this launch or prefetched).
    public private(set) var gists: [UUID: String] = [:]
    /// When each episode's recall note was last issued.
    public private(set) var recalledAt: [UUID: Date] = [:]
    public private(set) var lastRecallTurn: Int?
    public private(set) var recognizedThisConversation: [UUID] = []
    public private(set) var asleepSince: Date?
    public private(set) var sleepClosed = false
    /// Awake time since the last `.reflect`.
    public private(set) var awake: TimeInterval = 0

    var primed = false
    var lastStep: Date?
    var prevMind: MindSnapshot?
    var prevRepair: RepairPhase = .fine
    var lastBeat: Beat?
    var knownExpectations: [UUID: Expectation.Status] = [:]
    var knownIntentions: Set<UUID> = []
    var knownGags: Set<UUID> = []
    var lastMisread: UUID?
    var conversationPerson: PersonID?
    /// Recall notes raised and not yet issued: the matched topic and score, for the
    /// `recallHit` signal and the recognize beat, which wait for the note to be spoken
    /// (review finding 6: the face must not remember what the words never say).
    var raisedRecalls: [(episode: UUID, subject: Subject?, score: Double)] = []
    /// Offset of the user's local time from UTC: digest days are local days.
    public internal(set) var utcOffset: TimeInterval = 0

    public init() {}

    // MARK: - Reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var fx: [Effect] = []
        if let last = lastStep, asleepSince == nil { awake += min(max(0, now.timeIntervalSince(last)), Self.maxAwakeStep) }
        lastStep = now
        if !primed { prime(m) }
        let before = prevMind ?? m.ongoing.mind

        // A new user turn on a new subject (or from someone else) closes the open segment first.
        if case .heard = p, let s = segment, s.turns > 0 {
            let topics = Array(m.ongoing.topic.prefix(Ongoing.maxTopic))
            let disjoint = !s.topics.isEmpty && !topics.isEmpty && !topics.contains { t in s.topics.contains { $0.overlaps(t) } }
            if s.person != m.ongoing.person || disjoint { fx += closeSegment(&m, after: before, &rng) }
        }

        collectEvents(&m, before: before)

        switch p {
        case .conversationStarted:
            let turns = userTurns
            fx += closeConversation(&m, after: m.ongoing.mind, &rng)
            if turns >= Self.reflectAfterTurns { fx += reflect() }
        case .asleep(let on):
            if on {
                if asleepSince == nil { asleepSince = now; sleepClosed = false }
            } else {
                asleepSince = nil
                sleepClosed = false
            }
        case .heard(_, _, _, let a):
            addTurn(a, &m, before: before)
            fx += recall(&m, extra: [])
        case .sight(let camera, let things, let novel):
            let fresh = novel.compactMap(Subject.init)
            var shownNow = camera == .back ? fresh : []
            if shareGoalLive(m) || heldUp(m) {
                shownNow = Self.union(shownNow, fresh.isEmpty ? Array(things.compactMap(Subject.init).prefix(1)) : fresh)
            }
            if !fresh.isEmpty || !shownNow.isEmpty {
                open(&m, before: before)
                let seen = Self.union(segment?.seen ?? [], fresh), shown = Self.union(segment?.shown ?? [], shownNow)
                segment?.seen = seen
                segment?.shown = shown
                segment?.end = now
            }
            if !fresh.isEmpty || !shownNow.isEmpty { fx += recall(&m, extra: Self.union(shownNow, fresh)) }
        case .sound(let label, let unexpected):
            if Self.isLaughter(label) {
                laugh(&m, before: before)
            } else if unexpected, let s = Subject(label) {
                open(&m, before: before)
                let sounds = Self.union(segment?.sounds ?? [], [s])
                segment?.sounds = sounds
            }
        case .touch(_, let gentle, _):
            if gentle {
                open(&m, before: before)
                segment?.touches += 1
            }
        default:
            break
        }

        for s in m.inbox(for: Self.name) {
            switch s.name {
            case "laughter": laugh(&m, before: before)
            case "beatFinished":
                if segment.map({ $0.turns > 0 && !$0.shown.isEmpty }) == true, showSegmentIsSalient(m) {
                    fx += closeSegment(&m, after: m.ongoing.mind, &rng)
                }
            default: break
            }
        }

        // A show-and-tell beat chain that just completed closes the segment.
        let liveBeat = m.momentary.beat.flatMap { $0.step(at: now) == nil ? nil : $0 }
        if let b = lastBeat, liveBeat == nil, Self.showBeats.contains(b.kind), let s = segment, s.turns > 0, showSegmentIsSalient(m) {
            fx += closeSegment(&m, after: m.ongoing.mind, &rng)
        }
        lastBeat = liveBeat

        // Asleep ≥ 300 s ends the conversation and schedules reflection, once per sleep.
        if let since = asleepSince, !sleepClosed, now.timeIntervalSince(since) >= Self.sleepEndsConversation {
            sleepClosed = true
            fx += closeConversation(&m, after: m.ongoing.mind, &rng)
            fx += reflect()
        }
        if awake >= Self.reflectAfterAwake { fx += reflect() }

        prevMind = m.ongoing.mind
        prevRepair = m.ongoing.repair
        return fx
    }

    // MARK: - Hooks

    public mutating func seed(from carried: Carried, _ m: inout Moment) {
        prime(m)
        for e in carried.expectations { knownExpectations[e.id] = e.status }
        for i in carried.intentions { knownIntentions.insert(i.id) }
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        segment = nil
        userTurns = 0
        persistedThisConversation = []
        recognizedThisConversation = []
        raisedRecalls = []
        conversationMindBefore = m.ongoing.mind.code
        conversationPerson = m.ongoing.person
        return []
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        guard n.kind == .recall, let id = n.episode else { return [] }
        if let i = m.enduring.episodeIndex.firstIndex(where: { $0.id == id }) { m.enduring.episodeIndex[i].recalled += 1 }
        recalledAt[id] = m.now
        lastRecallTurn = totalTurns
        if let hit = raisedRecalls.last(where: { $0.episode == id }) {
            // Beats reads the signal and the request on the next step.
            m.signal("recallHit", subject: hit.subject, value: hit.score, id: id, by: Self.name)
            if !recognizedThisConversation.contains(id) {
                recognizedThisConversation.append(id)
                m.momentary.requestBeat(.recognize, priority: Self.recognizeBeatPriority, at: m.now, by: Self.name)
            }
        }
        raisedRecalls = []
        return [.persist(.recalled(episode: id, at: m.now))]
    }

    /// Episode bodies fetched from `SelfStore` (by person at identification, ≤ 20):
    /// their gists become citable by the recall note. Keys missing from the index are
    /// added (≤ 300) so they can be scored.
    public mutating func prefetch(_ episodes: [Episode], _ m: inout Moment) {
        for e in episodes {
            gists[e.id] = Self.recallable(e) ? e.gist : nil
            if let last = e.lastRecalled { recalledAt[e.id] = max(recalledAt[e.id] ?? last, last) }
            if !m.enduring.episodeIndex.contains(where: { $0.id == e.id }) { Self.insert(e.key, into: &m.enduring.episodeIndex, at: m.now) }
        }
        pruneCaches(m)
    }

    public mutating func forget(subject: Subject, _ m: inout Moment) {
        if var s = segment {
            s.topics.removeAll { $0.overlaps(subject) }
            s.shown.removeAll { $0.overlaps(subject) }
            s.seen.removeAll { $0.overlaps(subject) }
            s.sounds.removeAll { $0.overlaps(subject) }
            s.plans.removeAll { $0.subject.overlaps(subject) }
            s.followUps.removeAll { $0.subject.overlaps(subject) }
            if s.misread?.topic?.overlaps(subject) == true { s.misread = nil }
            if s.gagTopic?.overlaps(subject) == true { s.gagTopic = nil }
            segment = s
        }
        for id in gists.keys.sorted(by: { $0.uuidString < $1.uuidString }) where gists[id].map(subject.appears(in:)) == true {
            gists[id] = nil
        }
        if lastEpisode.map({ e in e.topics.contains { $0.overlaps(subject) } || subject.appears(in: e.gist) }) == true { lastEpisode = nil }
        pruneCaches(m)
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        if segment?.person == id { segment = nil }
        if conversationPerson == id { conversationPerson = nil }
        if lastEpisode?.person == id { lastEpisode = nil }
        persistedThisConversation.removeAll { $0.person == id }
        pruneCaches(m)
    }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        if segment?.person == from { segment?.person = into }
        if conversationPerson == from { conversationPerson = into }
        if lastEpisode?.person == from { lastEpisode?.person = into }
        for i in persistedThisConversation.indices where persistedThisConversation[i].person == from {
            persistedThisConversation[i].person = into
        }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        segment = nil
        conversationMindBefore = nil
        userTurns = 0
        persistedThisConversation = []
        lastEpisode = nil
        gists = [:]
        recalledAt = [:]
        lastRecallTurn = nil
        recognizedThisConversation = []
        conversationPerson = nil
        knownExpectations = [:]
        knownIntentions = []
        knownGags = []
        lastMisread = nil
        raisedRecalls = []
        primed = false
    }

    public static func slice(of m: Moment) -> [String: String] {
        let keys = m.enduring.episodeIndex.suffix(3).map { k in
            "\(k.topics.map(\.text).joined(separator: "+"))@\(String(format: "%.2f", k.salience))/r\(k.recalled)"
        }
        let notes = m.ongoing.noteCandidates.filter { $0.owner == name }.map { "\($0.kind.rawValue):\($0.slots.joined(separator: "|"))" }
        let beats = m.momentary.beatRequests.filter { $0.owner == name }.map(\.kind.rawValue)
        let signals = m.momentary.signals.filter { $0.owner == name && $0.seq == m.seq }
            .map { "\($0.name)(\($0.subject?.text ?? "-"),\(String(format: "%.2f", $0.value)))" }
        return ["index": "\(m.enduring.episodeIndex.count)", "lastKeys": keys.joined(separator: " ; "),
                "notes": notes.joined(separator: " ; "), "beats": beats.joined(separator: ","), "signals": signals.joined(separator: ",")]
    }

    // MARK: - Accumulation

    /// Records the shared state as "already known" (no events for what existed before).
    mutating func prime(_ m: Moment) {
        primed = true
        for e in m.ongoing.expectations { knownExpectations[e.id] = e.status }
        for i in m.ongoing.intentions { knownIntentions.insert(i.id) }
        for g in m.enduring.gags { knownGags.insert(g.id) }
        lastMisread = m.ongoing.misreadThisTurn?.id
        prevRepair = m.ongoing.repair
        prevMind = prevMind ?? m.ongoing.mind
        if conversationMindBefore == nil { conversationMindBefore = m.ongoing.mind.code }
    }

    mutating func open(_ m: inout Moment, before: MindSnapshot) {
        if segment == nil { segment = Segment(start: m.now, person: m.ongoing.person, mind: before) }
    }

    /// Events read off the shared state (diffs since the last step).
    mutating func collectEvents(_ m: inout Moment, before: MindSnapshot) {
        for e in m.ongoing.expectations {
            let old = knownExpectations[e.id]
            knownExpectations[e.id] = e.status
            if old == nil, e.status == .pending {
                open(&m, before: before)
                segment?.plans.append(e)
            } else if e.status == .resolved, old != .resolved {
                resolved(e, &m, before: before)
            }
        }
        for s in m.inbox(for: Self.name) where s.name == "expectationResolved" || s.name == "followUpResolved" {
            guard let id = s.id, segment?.followUps.contains(where: { $0.id == id }) != true else { continue }
            if let e = m.ongoing.expectations.first(where: { $0.id == id }) {
                var r = e
                r.outcomeValence = r.outcomeValence ?? s.value
                resolved(r, &m, before: before)
            } else if let subject = s.subject, let person = m.ongoing.person {
                let e = Expectation(id: id, person: person, subject: subject, due: m.now, expires: m.now, framing: .neutral,
                                    status: .resolved, outcomeValence: s.value)
                resolved(e, &m, before: before)
            }
            knownExpectations[id] = .resolved
        }
        for i in m.ongoing.intentions where !knownIntentions.contains(i.id) {
            knownIntentions.insert(i.id)
            guard [.followUp, .ask, .learn].contains(i.kind) else { continue }
            open(&m, before: before)
            if segment?.openLoop == nil || i.kind == .followUp { segment?.openLoop = i.id }
        }
        for g in m.enduring.gags where !knownGags.contains(g.id) {
            knownGags.insert(g.id)
            open(&m, before: before)
            if segment?.gagTopic == nil { segment?.gagTopic = g.topic }
        }
        if let mr = m.ongoing.misreadThisTurn, mr.id != lastMisread {
            lastMisread = mr.id
            open(&m, before: before)
            segment?.misread = mr
        }
        if m.ongoing.repair != prevRepair {
            if m.ongoing.repair == .reconciled { open(&m, before: before); segment?.reconciled = true }
            if m.ongoing.repair == .ruptured { open(&m, before: before); segment?.ruptured = true }
        }
        if segment != nil { segment?.end = m.now }
    }

    mutating func resolved(_ e: Expectation, _ m: inout Moment, before: MindSnapshot) {
        open(&m, before: before)
        segment?.followUps.removeAll { $0.id == e.id }
        segment?.followUps.append(e)
    }

    mutating func addTurn(_ a: Appraisal, _ m: inout Moment, before: MindSnapshot) {
        open(&m, before: before)
        guard var s = segment else { return }
        let k = a.kindness
        s.turns += 1
        s.end = m.now
        s.person = m.ongoing.person ?? s.person
        s.kindnessSum += k
        s.surprise = max(s.surprise, abs(m.profile.kindnessEMA - k))
        if a.distress >= Self.distressThreshold || m.ongoing.distressLive(at: m.now) { s.distress = true }
        if a.humor >= Self.humourLaughThreshold && a.valence >= 0 { s.laughs += 1 }
        s.topics = Array(Self.union(s.topics, Array(m.ongoing.topic.prefix(Ongoing.maxTopic))).prefix(Ongoing.maxTopic))
        segment = s
        userTurns += 1
        totalTurns += 1
        if let p = m.ongoing.person { conversationPerson = p }
    }

    mutating func laugh(_ m: inout Moment, before: MindSnapshot) {
        open(&m, before: before)
        segment?.laughs += 1
        segment?.end = m.now
    }

    func shareGoalLive(_ m: Moment) -> Bool {
        m.ongoing.hypotheses.contains { $0.kind == .goal && $0.value == "shareCreation" && m.now < $0.expires }
    }

    func heldUp(_ m: Moment) -> Bool {
        m.momentary.referents.contains { $0.sources.contains(.heldUp) && $0.lastSeen >= m.now }
    }

    static func isLaughter(_ label: String) -> Bool { label.lowercased().contains("laugh") }

    // MARK: - Closing

    /// Ends the conversation: closes the open segment and counts the conversation.
    mutating func closeConversation(_ m: inout Moment, after: MindSnapshot, _ rng: inout Rand) -> [Effect] {
        var fx = closeSegment(&m, after: after, &rng)
        if userTurns > 0, !conversationCounted {
            fx.append(.persist(.digest(day: Self.day(m.now, utcOffset: utcOffset), person: conversationPerson, conversations: 1, lowSalience: 0)))
        }
        userTurns = 0
        conversationCounted = false
        persistedThisConversation = []
        return fx
    }

    /// Background, sleep or quit: a quit loses the open segment, so it is closed now
    /// (episode or digest) and the conversation is counted once. The conversation
    /// itself goes on (the 3-episode cap and the turn count still apply).
    public mutating func flush(_ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx = closeSegment(&m, after: m.ongoing.mind, &rng)
        if userTurns > 0, !conversationCounted {
            conversationCounted = true
            fx.append(.persist(.digest(day: Self.day(m.now, utcOffset: utcOffset), person: conversationPerson, conversations: 1, lowSalience: 0)))
        }
        return fx
    }

    /// A show-and-tell chain ends the segment only when it already makes an episode:
    /// the beats finish while Dee is still answering, and closing a faint segment there
    /// would drop the showing and start the user's explanation as a new segment without
    /// it (it then joins the explanation and closes on the usual rules).
    func showSegmentIsSalient(_ m: Moment) -> Bool {
        guard let s = segment else { return false }
        let e = Self.episode(from: s, after: m.ongoing.mind, index: m.enduring.episodeIndex, id: Self.probeID)
        return e.salience >= Self.persistThreshold
    }

    static let probeID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Turns the open segment into an episode (persisted at salience ≥ 0.4).
    mutating func closeSegment(_ m: inout Moment, after: MindSnapshot, _ rng: inout Rand) -> [Effect] {
        guard let s = segment else { return [] }
        segment = nil
        guard s.turns > 0 else { return [] }
        var e = Self.episode(from: s, after: after, index: m.enduring.episodeIndex, id: rng.uuid())
        var fx: [Effect] = []
        let day = Self.day(m.now, utcOffset: utcOffset)
        if e.salience >= Self.persistThreshold {
            if persistedThisConversation.count >= Self.maxEpisodesPerConversation {
                let weakest = persistedThisConversation.enumerated().min { a, b in
                    a.element.salience != b.element.salience ? a.element.salience < b.element.salience : a.offset < b.offset
                }!
                if weakest.element.salience < e.salience {
                    persistedThisConversation.remove(at: weakest.offset)
                    m.enduring.episodeIndex.removeAll { $0.id == weakest.element.id }
                    gists[weakest.element.id] = nil
                    fx.append(.persist(.deleteEpisode(weakest.element.id)))
                    fx.append(.persist(.digest(day: day, person: weakest.element.person, conversations: 0, lowSalience: 1)))
                } else {
                    e.salience = min(e.salience, Self.persistThreshold - 0.01)
                }
            }
        }
        if e.salience >= Self.persistThreshold {
            fx.append(.persist(.episode(e)))
            persistedThisConversation.append(e.key)
            Self.insert(e.key, into: &m.enduring.episodeIndex, at: m.now)
            gists[e.id] = Self.recallable(e) ? e.gist : nil
        } else {
            fx.append(.persist(.digest(day: day, person: e.person, conversations: 0, lowSalience: 1)))
        }
        let persisted = e.salience >= Self.persistThreshold
        for t in e.topics {
            m.signal("episodeClosed", subject: t, value: e.valence, id: persisted ? e.id : nil, label: e.kind.rawValue, by: Self.name)
        }
        lastEpisode = e
        pruneCaches(m)
        return fx
    }

    /// Pure: the episode a closed segment becomes.
    public static func episode(from s: Segment, after: MindSnapshot, index: [EpisodeKey], id: UUID) -> Episode {
        let turns = max(1, s.turns)
        let valence = clamp(s.kindnessSum / Double(turns), -1, 1)
        let tags = s.tags
        let novelty: Double = {
            guard !tags.isEmpty else { return 0 }
            let new = tags.filter { t in !index.contains { k in k.topics.contains { $0.overlaps(t) } } }.count
            return noveltyWeight * Double(new) / Double(tags.count)
        }()
        let dRegard = after.regard - s.regardBefore
        var salience = abs(dRegard) * 2 + s.surprise + novelty
        if s.distress { salience += 0.5 }
        if s.laughs > 0 { salience += 0.5 }
        if !s.followUps.isEmpty { salience += 1 }
        if s.misread != nil { salience += 1 }

        let they = s.person == nil ? "someone" : "they"
        var kind = Episode.Kind.conversation
        var gist: String
        var expected: String?
        var changed: String?
        var topics = tags
        if let f = s.followUps.last {
            kind = .followUp
            gist = "\(they) told me how their \(f.subject.text) went"
            expected = f.framing.rawValue
            changed = outcomePhrase(f.outcomeValence ?? valence)
            topics = union([f.subject], tags)
        } else if let mr = s.misread {
            kind = .misread
            let guess = mr.wrongGuess.map { $0.lowercased() }.flatMap { safeGuessLabels.contains($0) ? $0 : nil }
            gist = misreadGist(mr.situation, guess: guess)
            expected = guess.map { "I thought they were \($0)" } ?? "I thought I understood them"
            changed = changedPhrase(mr.situation)
            if let t = mr.topic { topics = union([t], tags) }
        } else if s.reconciled {
            kind = .repair
            gist = "we made up after " + (s.topics.first.map { "talking about \($0.text)" } ?? "a rough patch")
        } else if s.ruptured {
            kind = .repair
            gist = "things got tense between us" + (s.topics.first.map { " about \($0.text)" } ?? "")
        } else if let thing = s.shown.first {
            kind = .shared
            gist = "\(they) showed me \(article(thing.text)) \(thing.text)"
            topics = union([thing], tags)
        } else if let plan = s.plans.first {
            kind = .conversation
            // No time words: "tomorrow" recalled a week later would be wrong (finding 12).
            gist = "\(they) told me about their upcoming \(plan.subject.text)"
            topics = union([plan.subject], tags)
        } else if let g = s.gagTopic {
            kind = .play
            gist = "we started a running joke about \(g.text)"
        } else if s.laughs >= 2 {
            kind = .play
            gist = s.topics.first.map { "we talked about \($0.text); \(they) laughed a lot" } ?? "we joked around; \(they) laughed a lot"
        } else if s.topics.isEmpty, let thing = s.seen.first {
            kind = .discovery
            gist = "I saw \(article(thing.text)) \(thing.text) for the first time"
        } else if !s.topics.isEmpty {
            gist = "we talked about " + listed(s.topics.map(\.text))
        } else {
            gist = "we chatted for a while"
        }
        gist = NoteTemplates.fit(gist, Episode.maxGist)
        let why = whyPhrase(s, after: after, kind: kind, valence: valence)
        return Episode(id: id, person: s.person, start: s.start, end: s.end, kind: kind, topics: Array(topics.prefix(3)), gist: gist,
                       why: why.map(phrase), expected: expected.map(phrase), changed: changed.map(phrase), valence: valence,
                       salience: salience, surprise: s.surprise, mindBefore: s.mindBefore, mindAfter: after.code,
                       openLoop: s.openLoop)
    }

    // MARK: - Templates

    static func misreadGist(_ situation: Lesson.Situation, guess: String?) -> String {
        switch situation {
        case .moodGuess: guess.map { "I misread them: thought they were \($0)" } ?? "I misread how they were feeling"
        case .tookLiterally: "I took their joke literally"
        case .wrongReferent: "I picked the wrong thing they meant"
        case .interruptedThem: "I talked over them"
        case .jokeFlopped: "my joke fell flat with them"
        case .askedTooMuch: "I asked them too many questions"
        }
    }

    static func changedPhrase(_ situation: Lesson.Situation) -> String {
        switch situation {
        case .moodGuess: "now I ask how they feel"
        case .tookLiterally: "now I check if they're joking"
        case .wrongReferent: "now I check which one they mean"
        case .interruptedThem: "now I wait before answering"
        case .jokeFlopped: "now I keep jokes low-key"
        case .askedTooMuch: "now I ask fewer questions"
        }
    }

    static func outcomePhrase(_ v: Double) -> String {
        v > 0.2 ? "it went well for them" : v < -0.2 ? "it didn't go well for them" : "now I know how it went"
    }

    /// The largest feeling delta, as a ≤ 8-word reason.
    static func whyPhrase(_ s: Segment, after: MindSnapshot, kind: Episode.Kind, valence: Double) -> String? {
        let a = s.mindBefore.feelings, b = after.code.feelings
        if kind == .shared, valence > 0.2 { return "they seemed proud" }
        // (feeling, direction, phrase)
        let table: [(Feeling, Double, String)] = [
            (.joy, 1, s.laughs > 0 ? "they made me laugh" : "it made me happy"),
            (.joy, -1, "it took the shine off my day"),
            (.sadness, 1, s.distress ? "I was worried for them" : "it made me a little sad"),
            (.anger, 1, "it made me cross"),
            (.fear, 1, s.distress ? "I was worried for them" : "it made me nervous"),
            (.surprise, 1, "it surprised me"),
            (.interest, 1, "I found it really interesting"),
            (.boredom, 1, "it dragged a little"),
            (.affection, 1, "I felt closer to them"),
            (.trust, 1, "they were open with me"),
            (.trust, -1, "it shook my trust a little"),
            (.gratitude, 1, "they were kind to me"),
            (.resentment, 1, "it stung a bit"),
            (.loneliness, -1, "it was nice to have company"),
        ]
        var best: (Double, String)?
        for (f, dir, text) in table {
            let d = (b[f] - a[f]) * dir
            guard d >= feelingDeltaFloor else { continue }
            // Slow feelings (affection, trust) move little per conversation: weight them up.
            let w = (f == .affection || f == .trust) ? d * 4 : d
            if best == nil || w > best!.0 { best = (w, text) }
        }
        if let best { return best.1 }
        if s.distress { return "I was worried for them" }
        if s.laughs > 0 { return "they made me laugh" }
        return nil
    }

    static func when(_ due: Date, from now: Date) -> String {
        let h = due.timeIntervalSince(now) / 3600
        switch h {
        case ..<12: return "today"
        case ..<36: return "tomorrow"
        case ..<(7 * 24): return "this week"
        default: return "coming up"
        }
    }

    static func article(_ word: String) -> String {
        guard let c = word.first else { return "a" }
        return "aeiou".contains(c) ? "an" : "a"
    }

    static func listed(_ xs: [String]) -> String {
        switch xs.count {
        case 0: ""
        case 1: xs[0]
        default: xs.dropLast().joined(separator: ", ") + " and " + xs.last!
        }
    }

    /// ≤ 8 words and ≤ 60 characters (the store's CHECK).
    static func phrase(_ s: String) -> String {
        let words = s.split(separator: " ").prefix(maxWords).joined(separator: " ")
        return NoteTemplates.fit(words, maxPhrase)
    }

    static func union(_ lists: [Subject]...) -> [Subject] {
        var out: [Subject] = []
        for l in lists { for s in l where !out.contains(where: { $0.overlaps(s) }) { out.append(s) } }
        return out
    }

    // MARK: - Recall

    /// The recall score of one key for a query (SELF.md §7.10).
    public static func recallScore(_ k: EpisodeKey, query: [Subject], at now: Date) -> Double {
        guard !k.topics.isEmpty, !query.isEmpty else { return 0 }
        let inter = k.topics.filter { t in query.contains { $0.overlaps(t) } }.count
        guard inter > 0 else { return 0 }
        let union = k.topics.count + query.count - inter
        let jaccard = Double(inter) / Double(max(1, union))
        let days = max(0, now.timeIntervalSince(k.end)) / 86_400
        return jaccard * k.salience * exp(-days / recallTimescaleDays) * (k.recalled < 3 ? 1 : 0.5)
    }

    /// Episodes the recall note may cite: never a quarrel, a misread or a sad memory
    /// (review finding 12: "things got tense between us about money" is not a nice
    /// thing to bring up).
    public static func recallable(_ e: Episode) -> Bool {
        e.kind != .repair && e.kind != .misread && e.valence >= -0.2
    }

    mutating func recall(_ m: inout Moment, extra: [Subject]) -> [Effect] {
        if let last = lastRecallTurn, totalTurns - last < Self.recallEveryTurns { return [] }
        var query = Array(m.ongoing.topic.prefix(Ongoing.maxTopic))
        switch m.momentary.focus {
        case .referent(let s, _), .sound(let s): query.append(s)
        default: break
        }
        query += m.momentary.referents.filter { $0.sources.contains(.heldUp) && $0.salience >= 0.5 }.map(\.subject)
        query = Self.union(query, extra)
        guard !query.isEmpty else { return [] }
        let now = m.now
        let person = m.ongoing.person
        // Never recall what they asked Dee not to bring up (RepairKeeper's boundaries).
        let offLimits = m.enduring.boundaries.filter { $0.person == person && $0.owner == .user && $0.active }.map(\.topic)
        query.removeAll { q in offLimits.contains { $0.overlaps(q) } }
        guard !query.isEmpty else { return [] }
        var best: (score: Double, key: EpisodeKey)?
        for k in m.enduring.episodeIndex {
            // Person-scoped: a key of nobody in particular only while nobody is identified
            // (review finding 12: Alice's surgery is not Bob's memory).
            guard k.person == person, gists[k.id] != nil,
                  !persistedThisConversation.contains(where: { $0.id == k.id }),
                  !k.topics.contains(where: { t in offLimits.contains { $0.overlaps(t) } }) else { continue }
            if let at = recalledAt[k.id], now.timeIntervalSince(at) < Self.recallSameEpisodeCooldown { continue }
            let sc = Self.recallScore(k, query: query, at: now)
            guard sc >= Self.recallThreshold else { continue }
            if let b = best {
                let better = sc != b.score ? sc > b.score : (k.end != b.key.end ? k.end > b.key.end : k.id.uuidString < b.key.id.uuidString)
                if !better { continue }
            }
            best = (sc, k)
        }
        guard let hit = best, let gist = gists[hit.key.id] else { return [] }
        m.ongoing.raise(.recall(gist: gist, episode: hit.key.id), by: Self.name)
        let matched = hit.key.topics.first { t in query.contains { $0.overlaps(t) } }
        raisedRecalls = Array((raisedRecalls + [(hit.key.id, matched, hit.score)]).suffix(4))
        return []
    }

    // MARK: - Reflection scheduling

    mutating func reflect() -> [Effect] {
        awake = 0
        return [.reflect]
    }

    // MARK: - Helpers

    /// Adds `key` to the index; over 300, the lowest salience × recency key leaves.
    static func insert(_ key: EpisodeKey, into index: inout [EpisodeKey], at now: Date) {
        index.removeAll { $0.id == key.id }
        index.append(key)
        while index.count > Enduring.maxEpisodeIndex {
            let i = index.indices.min { a, b in
                let x = Reflector.keep(index[a], at: now), y = Reflector.keep(index[b], at: now)
                return x != y ? x < y : a < b
            }!
            index.remove(at: i)
        }
    }

    /// Caches only hold episodes still in the index (or this conversation's).
    mutating func pruneCaches(_ m: Moment) {
        let live = Set(m.enduring.episodeIndex.map(\.id)).union(persistedThisConversation.map(\.id))
        for id in gists.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !live.contains(id) { gists[id] = nil }
        for id in recalledAt.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !live.contains(id) { recalledAt[id] = nil }
        persistedThisConversation.removeAll { k in !m.enduring.episodeIndex.contains { $0.id == k.id } }
    }

    /// Calendar day at `utcOffset` (UTC by default), `yyyy-MM-dd` (pure; no Calendar).
    public static func day(_ d: Date, utcOffset: TimeInterval = 0) -> String {
        let days = Int(((d.timeIntervalSince1970 + utcOffset) / 86_400).rounded(.down))
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let dd = doy - (153 * mp + 2) / 5 + 1
        let mm = mp < 10 ? mp + 3 : mp - 9
        let yy = yoe + era * 400 + (mm <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", yy, mm, dd)
    }
}
