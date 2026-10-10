import DeeCore
import DeeMemory
import DeeMind
import Foundation

// docs/DNA.md §1 — what RealtimeBrain gathers right before a response. Plain values only.
//
// Dee DNA lives in DeeSelf (under DNA/) rather than in a separate `DeeDNA` library: it
// reads Cortex/Moment/Stance internals directly and is covered by DeeSelf's purity
// lint (no clock, no global randomness, no fresh UUIDs, no per-process ordering).

/// How the turn's DNA was built (§4.3): `fast` = current state + local prosody only;
/// `exact` = after the transcript was appraised and committed.
public enum CueMode: String, Sendable, Equatable, Codable, CaseIterable { case fast, exact }

/// §1.9 — which response this DNA is for.
public struct TurnContext: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        case reply, initiative
        /// Re-request after a preempted reply or an echo-withdrawn user turn.
        case retry
    }
    public var kind: Kind
    /// Responses requested this conversation (1-based in the header).
    public var index: Int
    /// Directive for `kind == .initiative`: `IntentionBoard.action(for:)` or a curiosity
    /// candidate's template. Lexicon-safe; never user text.
    public var initiative: String?
    public var mode: CueMode
    /// Her replies actually heard this conversation (audio played), from the brain;
    /// nil when unknown. The greeting after time apart (G5) stays until one was
    /// heard, so a reply cancelled or never heard does not use it up (tune 4: live,
    /// "Good morning." / "Did you sleep well?" split, reply 1 cancelled, and reply 2
    /// had lost the greeting because the turn count had moved on).
    public var heardReplies: Int?

    public init(kind: Kind = .reply, index: Int = 1, initiative: String? = nil, mode: CueMode = .fast,
                heardReplies: Int? = nil) {
        self.kind = kind
        self.index = index
        self.initiative = initiative
        self.mode = mode
        self.heardReplies = heardReplies
    }
}

/// §1.9 — the voice part of an appraisal, from prosody alone (`Appraiser.prosodyOnly`).
public struct ProsodyRead: Sendable, Equatable {
    /// −1…1 vs this user's baseline (`z/2`, as `Appraiser.evaluate`).
    public var loudness: Double
    /// (rate − baseline.rate) / baseline.rate, clamped −1…1.
    public var pace: Double
    /// Semitone SD (`Prosody.pitchVariability`).
    public var pitchVariability: Double
    /// `Appraiser.evaluate`'s "voiced" term, 0…1.
    public var intensity: Double
    /// The ±0.5·loudness term only (no words).
    public var dominance: Double

    public init(loudness: Double = 0, pace: Double = 0, pitchVariability: Double = 2.5, intensity: Double = 0, dominance: Double = 0) {
        self.loudness = loudness
        self.pace = pace
        self.pitchVariability = pitchVariability
        self.intensity = intensity
        self.dominance = dominance
    }
}

extension Appraiser {
    /// docs/DNA.md §1.9 — the prosody-only read, using exactly `Appraiser.evaluate`'s
    /// voice formulas, so prosody-only and full appraisal agree on the voice part.
    public static func prosodyOnly(_ p: Prosody, baseline: VoiceBaseline) -> ProsodyRead {
        let z = (p.loudnessDB - baseline.loudnessDB) / max(2, baseline.loudnessSpread)
        let loudness = max(-1, min(1, z / 2))
        let fast = max(0, (p.speechRate - baseline.speechRate) / max(0.5, baseline.speechRate))
        let peak = max(0, (p.peakDB - baseline.loudnessDB - 12) / 12)
        let voiced = max(0, loudness) * 0.6 + min(1, fast) * 0.25 + min(1, peak) * 0.3
        var dominance = 0.0
        if loudness > 0.3 { dominance = min(1, loudness * 0.5) }
        if loudness < -0.3 { dominance = max(-1, loudness * 0.4) }
        let pace = max(-1, min(1, (p.speechRate - baseline.speechRate) / max(0.5, baseline.speechRate)))
        return ProsodyRead(loudness: loudness, pace: pace, pitchVariability: max(0, p.pitchVariability),
                           intensity: min(1, voiced), dominance: dominance)
    }
}

/// §1.9 — this turn's appraisal.
public struct TurnAppraisal: Sendable, Equatable {
    /// Present in fast and exact mode whenever audio was heard.
    public var prosody: ProsodyRead?
    /// Exact mode only (after `Mind.preview` / `Cortex.adjust` / commit).
    public var text: Appraisal?
    public var durationS: Double?

    public init(prosody: ProsodyRead? = nil, text: Appraisal? = nil, durationS: Double? = nil) {
        self.prosody = prosody
        self.text = text
        self.durationS = durationS
    }
}

/// §1.3 — relationship counters from `Mind.state` (aggregate only; no content).
public struct InnerStateCounters: Sendable, Equatable {
    public var interactions: Int
    public var kindInteractions: Int
    public var hostileInteractions: Int
    public var apologyFatigue: Double
    public var reoffense: Double
    public var hostileRecent: Double
    public var kindRecent: Double
    public var lastApologyAt: Date?

    public init(interactions: Int = 0, kindInteractions: Int = 0, hostileInteractions: Int = 0, apologyFatigue: Double = 0,
                reoffense: Double = 0, hostileRecent: Double = 0, kindRecent: Double = 0, lastApologyAt: Date? = nil) {
        self.interactions = interactions
        self.kindInteractions = kindInteractions
        self.hostileInteractions = hostileInteractions
        self.apologyFatigue = apologyFatigue
        self.reoffense = reoffense
        self.hostileRecent = hostileRecent
        self.kindRecent = kindRecent
        self.lastApologyAt = lastApologyAt
    }

    public init(_ s: InnerState) {
        self.init(interactions: s.interactions, kindInteractions: s.kindInteractions, hostileInteractions: s.hostileInteractions,
                  apologyFatigue: s.apologyFatigue, reoffense: s.reoffense, hostileRecent: s.hostileRecent,
                  kindRecent: s.kindRecent, lastApologyAt: s.lastApologyAt)
    }
}

/// §1.2 — `Mind.state.age` ageing flags.
public struct AgingInputs: Sendable, Equatable {
    public var enabled: Bool
    public var yearsPerDay: Double
    public init(enabled: Bool = false, yearsPerDay: Double = 0) {
        self.enabled = enabled
        self.yearsPerDay = yearsPerDay
    }
    public init(_ a: AgeSettings) { self.init(enabled: a.enabled && a.agingEnabled, yearsPerDay: a.yearsPerDay) }
}

/// §1.4 — one sample of the RAM-only mood history ring (never persisted).
public struct DNAHistorySample: Sendable, Equatable {
    public var at: Date
    public var code: MindCode
    public init(at: Date, code: MindCode) {
        self.at = at
        self.code = code
    }
}

/// §1.4 — the fixed cause lexicon. Derived from the absorbed `Appraisal` (never from text).
public enum CauseLabel: String, Sendable, Equatable, Codable, CaseIterable {
    case rudeness = "rudeness"
    case threat = "a threat"
    case kindWords = "kind words"
    case praise = "praise"
    case affection = "affection"
    case thanks = "thanks"
    case apology = "an apology"
    case brushedOff = "being brushed off"
    case joke = "a joke"
    case theirWorry = "their worry"
    case shoutedAt = "being shouted at"
    case askedAboutYou = "being asked about yourself"
    case repetition = "repetition"
    case tap = "a tap"
    case petted = "being petted"
    case hug = "a hug"
    case pokes = "pokes"
    case slap = "a slap"
    case tickles = "tickles"
    case alarmingSound = "an alarming sound"
    case music = "music"
    case laughter = "laughter"
    case applause = "applause"
    case crying = "crying"
    case aSound = "a sound"
    case sawSomethingNew = "something new you saw"
    case relief = "relief"
    case finishing = "finishing something"
    case timeAlone = "time alone"
    case rest = "rest"
    case chatting = "chatting a while"
    case longDay = "a long day"
    case justWoke = "just woke up"
    case quarrel = "the quarrel"

    public var words: String { rawValue }

    /// Sound causes (for "You hear:").
    public var isSound: Bool { [.alarmingSound, .music, .laughter, .applause, .crying, .aSound].contains(self) }

    /// The label for an absorbed appraisal. The stimulus kind decides first (a touch, a
    /// sound, a sight, an internal event: a slap is "a slap", not "rudeness"); speech
    /// then takes the first matching rule in the §1.4 order. nil = nothing notable.
    public static func classify(_ a: Appraisal) -> CauseLabel? {
        if let t = a.touch {
            switch t {
            case .tap, .doubleTap: return .tap
            case .pet: return .petted
            case .hold: return .hug
            case .pokes: return .pokes
            case .slap: return .slap
            case .tickle: return .tickles
            }
        }
        if let label = a.soundLabel {
            if a.alarm > 0 { return .alarmingSound }
            if a.distress > 0 { return .crying }
            if Laughter.isLaughter(label) || (a.humor >= 0.5 && a.delight > 0) { return .laughter }
            if a.delight >= 0.5, a.humor > 0 { return .applause }
            if a.delight >= 0.5 { return .music }
            return .aSound
        }
        if a.isSight { return .sawSomethingNew }
        if a.isInternal { return a.pride > a.relief ? .finishing : .relief }
        if a.hostility >= 0.3 { return .rudeness }
        if a.threat >= 0.3 { return .threat }
        if a.kindness > 0.3 { return .kindWords }
        if a.praise >= 0.4 { return .praise }
        if a.affection >= 0.4 { return .affection }
        if a.gratitude >= 0.4 { return .thanks }
        if a.apology >= 0.4 { return .apology }
        if a.dismissal >= 0.4 { return .brushedOff }
        if a.humor >= 0.4 { return .joke }
        if a.distress >= 0.4 { return .theirWorry }
        if a.loudness > 0.5, a.intensity > 0.5 { return .shoutedAt }
        if a.interestInDee >= 0.4 { return .askedAboutYou }
        if a.repetition > 0 { return .repetition }
        return nil
    }
}

/// §1.4 — one entry of the RAM-only cause ring.
public struct CauseEntry: Sendable, Equatable {
    public var at: Date
    public var label: CauseLabel
    /// after − before, in bytes, per feeling.
    public var deltas: [Feeling: Int]

    public init(at: Date, label: CauseLabel, deltas: [Feeling: Int]) {
        self.at = at
        self.label = label
        self.deltas = deltas
    }

    /// The entry for one `Mind.hear/commit/react/catchUp`: per-feeling byte deltas.
    public init(at: Date, label: CauseLabel, before: MindCode, after: MindCode) {
        var d: [Feeling: Int] = [:]
        for f in Feeling.allCases { d[f] = Int(after[f]) - Int(before[f]) }
        self.init(at: at, label: label, deltas: d)
    }

    public func delta(_ f: Feeling) -> Int { deltas[f] ?? 0 }
}

/// The two RAM rings of §1.4, as one value RealtimeBrain owns (never persisted).
public struct DNARings: Sendable, Equatable {
    public private(set) var history: [DNAHistorySample] = []
    public private(set) var causes: [CauseEntry] = []

    public static let historyCapacity = 40
    public static let historyMinSpacing: TimeInterval = 30
    public static let causeCapacity = 30
    public static let causeWindow: TimeInterval = 30 * 60

    public init() {}

    /// At every DNA render (`force`) and at `Mind.tick` results at most every 30 s.
    public mutating func sample(_ code: MindCode, at now: Date, force: Bool = false) {
        if !force, let last = history.last, now.timeIntervalSince(last.at) < Self.historyMinSpacing { return }
        history.append(DNAHistorySample(at: now, code: code))
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }

    public mutating func record(_ e: CauseEntry) {
        causes.append(e)
        causes.removeAll { e.at.timeIntervalSince($0.at) > Self.causeWindow }
        if causes.count > Self.causeCapacity { causes.removeFirst(causes.count - Self.causeCapacity) }
    }

    /// Records an absorbed appraisal (no-op when nothing notable).
    public mutating func record(_ a: Appraisal, before: MindCode, after: MindCode, at now: Date) {
        guard let label = CauseLabel.classify(a) else { return }
        record(CauseEntry(at: now, label: label, before: before, after: after))
    }

    public mutating func clear() {
        history = []
        causes = []
    }
}

/// One fact for section 5 (already non-sensitive, ranked, past-tensed by DeeMemory).
public struct DNAFact: Sendable, Equatable {
    /// The `promptMemories` line ("Maya has a job interview on Sat 3 Oct") or the bare
    /// fact text ("has a job interview on Sat 3 Oct").
    public var text: String
    public var category: Fact.Category?
    public init(text: String, category: Fact.Category? = nil) {
        self.text = text
        self.category = category
    }
}

/// §1.6 — the identified person (nil in `DNAInputs` = nobody identified).
public struct PersonInputs: Sendable, Equatable {
    public var id: PersonID
    /// nil for a placeholder.
    public var name: String?
    public var isPlaceholder: Bool
    public var aliases: [String]
    /// ≤ 8, `MemoryStore.promptMemories(for:limit: 9, now:)` minus the header line.
    public var facts: [DNAFact]
    public var firstMet: Date?
    public var encounters: Int
    public var lastSeen: Date?

    public init(id: PersonID, name: String?, isPlaceholder: Bool = false, aliases: [String] = [], facts: [DNAFact] = [],
                firstMet: Date? = nil, encounters: Int = 1, lastSeen: Date? = nil) {
        self.id = id
        self.name = isPlaceholder ? nil : name
        self.isPlaceholder = isPlaceholder
        self.aliases = Array(aliases.prefix(2))
        self.facts = Array(facts.prefix(DNALimits.facts))
        self.firstMet = firstMet
        self.encounters = encounters
        self.lastSeen = lastSeen
    }

    /// From DeeMemory: `person` plus its `promptMemories(for:limit: 9, now:)` lines. The
    /// header ("Name: …") and the ask-name line are dropped; each line's category is
    /// looked up from the person's facts.
    public init(person p: Person, promptMemories lines: [String]) {
        let body = lines.filter { !$0.hasPrefix("Name: ") && $0 != MemoryStore.askNameLine }
        let facts = body.map { line -> DNAFact in
            let lower = line.lowercased()
            let match = p.facts.first { f in
                let t = f.text.lowercased()
                let tail = t.split(separator: " ").dropFirst().joined(separator: " ")
                return lower.hasSuffix(t) || (!tail.isEmpty && lower.hasSuffix(tail))
            }
            return DNAFact(text: line, category: match?.category)
        }
        self.init(id: p.id, name: p.name, isPlaceholder: p.isPlaceholder, aliases: p.aliases, facts: facts,
                  firstMet: p.firstMet, encounters: p.encounters, lastSeen: p.lastSeen)
    }
}

/// §1.6 — one shared memory for section 5.
public struct EpisodeLine: Sendable, Equatable {
    public var id: UUID
    /// Template text, ≤ 100 chars.
    public var gist: String
    public var daysAgo: Int
    /// −1, 0 or +1. Not rendered: `EpisodeKey` carries no valence, and only non-sad
    /// episodes are recallable (`EpisodeBuilder.recallable`), so `Cortex.episodeLines` sets 0.
    public var valence: Int

    public init(id: UUID, gist: String, daysAgo: Int, valence: Int) {
        self.id = id
        self.gist = String(gist.prefix(Episode.maxGist))
        self.daysAgo = max(0, daysAgo)
        self.valence = valence
    }
}

/// §1.8 — a touch DeeModel perceived (`DeeModel.lastTouch`).
public struct TouchInput: Sendable, Equatable {
    /// `Percept.touch(kind:)` ("tap", "pet", "hold", "pokes", "slap", "tickle", …).
    public var kind: String
    public var gentle: Bool
    public var at: Date
    public init(kind: String, gentle: Bool, at: Date) {
        self.kind = kind
        self.gentle = gentle
        self.at = at
    }
}

/// §1.8 — body inputs gathered by RealtimeBrain from DeeModel.
public struct BodyInputs: Sendable, Equatable {
    public var someoneHere: Bool
    public var asleep: Bool
    /// `DeeModel.lastWokeAt`.
    public var wokeAt: Date?
    public var touch: TouchInput?
    /// RealtimeBrain's `lastUserTurnAt` for this conversation (RAM).
    public var lastUserTurnAt: Date?
    /// For the first turn: `Carried.lastContact[id]` ?? `Person.lastSeen`.
    public var lastContact: Date?

    public init(someoneHere: Bool = true, asleep: Bool = false, wokeAt: Date? = nil, touch: TouchInput? = nil,
                lastUserTurnAt: Date? = nil, lastContact: Date? = nil) {
        self.someoneHere = someoneHere
        self.asleep = asleep
        self.wokeAt = wokeAt
        self.touch = touch
        self.lastUserTurnAt = lastUserTurnAt
        self.lastContact = lastContact
    }
}

/// One day of `Mind.history(days: 30)`.
public struct DNADay: Sendable, Equatable {
    /// "yyyy-MM-dd" (local).
    public var day: String
    public var interactions: Int
    /// Average regard that day.
    public var regard: Double
    public init(day: String, interactions: Int, regard: Double) {
        self.day = day
        self.interactions = interactions
        self.regard = regard
    }
}

/// §1.1 — everything `DNAAssembler.assemble` reads.
public struct DNAInputs: Sendable, Equatable {
    public var now: Date
    /// `Cortex.utcOffset`: local time comes only from this (never the device locale or zone).
    public var utcOffset: TimeInterval
    public var turn: TurnContext
    /// Newest snapshot (by `.sequence`).
    public var mind: MindSnapshot
    public var aging: AgingInputs
    public var inner: InnerStateCounters
    public var moodHistory: [DNAHistorySample]
    public var causes: [CauseEntry]
    public var moment: Moment
    /// `Cortex.stance`, notes filled by `Cortex.cue(at:)`.
    public var stance: Stance
    public var episodes: [EpisodeLine]
    public var person: PersonInputs?
    public var body: BodyInputs
    public var appraisal: TurnAppraisal
    public var daily: [DNADay]
    /// Settings "Share memories with cloud voice".
    public var shareMemories: Bool
    /// RAM only: the user transcripts of this session, used **only** by the 5-gram guard
    /// (§2.7). Never copied into `DeeDNA`. Prefer `guardCorpus` (incremental).
    public var userTextCorpus: [String]
    /// RAM only: the session's 5-gram set, kept incrementally by the app (§2.7).
    public var guardCorpus: DNAGuardCorpus

    public init(now: Date, utcOffset: TimeInterval = 0, turn: TurnContext = TurnContext(), mind: MindSnapshot,
                aging: AgingInputs = AgingInputs(), inner: InnerStateCounters = InnerStateCounters(),
                moodHistory: [DNAHistorySample] = [], causes: [CauseEntry] = [], moment: Moment, stance: Stance,
                episodes: [EpisodeLine] = [], person: PersonInputs? = nil, body: BodyInputs = BodyInputs(),
                appraisal: TurnAppraisal = TurnAppraisal(), daily: [DNADay] = [], shareMemories: Bool = true,
                userTextCorpus: [String] = [], guardCorpus: DNAGuardCorpus = DNAGuardCorpus()) {
        self.now = now
        self.utcOffset = utcOffset
        self.turn = turn
        self.mind = mind
        self.aging = aging
        self.inner = inner
        self.moodHistory = moodHistory
        self.causes = causes
        self.moment = moment
        self.stance = stance
        self.episodes = episodes
        self.person = person
        self.body = body
        self.appraisal = appraisal
        self.daily = daily
        self.shareMemories = shareMemories
        self.userTextCorpus = userTextCorpus
        self.guardCorpus = guardCorpus
    }
}

/// List caps of §1 (the renderer's degradation steps shorten further).
public enum DNALimits {
    public static let facts = 8
    public static let episodes = 3
    public static let followUps = 3
    public static let upcoming = 2
    public static let interests = 3
    public static let boundaries = 5
    public static let values = 3
    public static let tastes = 3
    public static let strengths = 1
    public static let limits = 1
    public static let rituals = 2
    public static let gags = 2
    public static let sees = 3
    public static let hypotheses = 2
    public static let notes = 2
    public static let intentions = 2
    public static let blend = 3
}
