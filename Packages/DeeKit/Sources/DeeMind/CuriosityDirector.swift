import DeeCore
import Foundation

/// Decides when Dee starts a conversation herself, and about what.
///
/// Pure and deterministic (seeded): the app feeds it what happens (`note`) and asks
/// every second or so (`nextPrompt`). The answer is a short stage direction in
/// parentheses for the language model — e.g. "(You just noticed a guitar behind
/// your human. Ask about it, briefly and playfully. One short sentence.)" — or nil
/// to stay quiet.
///
/// Rules:
/// - Never while `busy` (thinking, speaking, listening) and never within
///   `quietAfterSpeech` (3 s) of anyone speaking.
/// - Greets once when the user arrives ("glad you're back" — never guilt for
///   being away).
/// - Unexpected sounds are raised almost immediately. Novel sights are paced
///   (`sightSpacing`, 45 s; 2 min for the back camera) unless they are animals or
///   awe-level novelty, which jump the queue.
/// - With nobody present, she calls out ("Hello? Is someone there?") only for an
///   alarming or loud unexpected sound, at most every 2 min, and — if she was
///   asleep — only after `minSleepBeforeCallout` (3 min) of sleep.
/// - Otherwise, while the user is present, she initiates after a gap of 20…60 s
///   (shorter the more she wants to talk, `MindSnapshot.urgeToTalk`), preferring
///   novel things she saw, then asking about the human, suggesting a game or
///   sharing a thought — weighted by mood, and phrased in her mood (grumpy Dee asks
///   grumpily).
/// - Back-off: every prompt the user leaves unanswered doubles the gap (×2 per
///   prompt, up to ×16, capped at `maxBackoffGap`, 10 min). After
///   `unansweredLimit` (3) unanswered prompts only novel sights and unexpected
///   sounds can start a conversation. The user speaking, touching her or
///   arriving resets it.
/// - The same subject never comes up twice within `subjectCooldown` (20 min).
/// - Subjects in `avoid` (the user's boundaries) never come up; greetings,
///   call-outs and alarming sounds are exempt.
///
/// v0.5: `candidates(at:snapshot:userPresent:busy:)` lists everything she could
/// raise (kind, subject, prompt, priority, urgency) without consuming anything, and
/// `commit(_:at:asReply:)` raises one — so DeeSelf's IntentionBoard can weigh them
/// against follow-ups and repairs. `nextPrompt` is the compatible wrapper: the same
/// builders, the timing gates and the cascade, then a commit.
public struct CuriosityDirector: Sendable {
    public enum Stimulus: Sendable, Equatable {
        case saw([String], camera: String)
        case heard(sound: String, unexpected: Bool)
        case userArrived
        case userSpoke
        case deeSpoke
        case touched(String)
    }

    // MARK: Tuning

    public static let subjectCooldown: TimeInterval = 20 * 60
    public static let quietAfterSpeech: TimeInterval = 3
    /// General-initiative gap at urge 1 … urge 0.
    public static let shortestGap: TimeInterval = 20
    public static let longestGap: TimeInterval = 60
    /// Minimum spacing between two prompts of any kind.
    static let minPromptSpacing: TimeInterval = 6
    /// Calling out to an empty room at most this often.
    static let unattendedSpacing: TimeInterval = 120
    /// A sleeping Dee calls out only once she has slept at least this long.
    public static let minSleepBeforeCallout: TimeInterval = 3 * 60
    /// Loudness (0…1) from which an unexpected sound in an empty room is "loud".
    public static let loudCallout = 0.7
    /// Spacing between two prompts about things she saw (front / back camera).
    public static let sightSpacing: TimeInterval = 45
    public static let backSightSpacing: TimeInterval = 120
    /// Sight novelty (0…1) that counts as awe and skips the sight spacing
    /// (matches the `.awe` reflex threshold).
    public static let aweNovelty = 0.85
    /// Unanswered prompts after which only novel sights and sounds may speak up.
    public static let unansweredLimit = 3
    /// The backed-off general-initiative gap never exceeds this.
    public static let maxBackoffGap: TimeInterval = 10 * 60
    /// Pokes in a burst before "your human keeps poking you" is worth a remark.
    static let pokesWorthARemark = 6
    static let greetingCooldown: TimeInterval = 10 * 60
    static let soundFreshness: TimeInterval = 30
    static let sightFreshness: TimeInterval = 60
    static let touchFreshness: TimeInterval = 15
    /// Things seen this recently are still worth asking about in a general initiative.
    static let seenMemory: TimeInterval = 10 * 60

    // MARK: State

    struct Seen: Sendable, Equatable {
        var label: String
        var camera: String
        var at: Date
        var novelty: Double? = nil
    }
    struct Heard: Sendable, Equatable {
        var label: String
        var at: Date
        /// Sounds: loudness 0…1 when known.
        var loudness: Double? = nil
        /// Sounds: how long Dee had been asleep when it was heard (nil = awake).
        var asleepFor: TimeInterval? = nil
        /// Pokes: the burst total, when known.
        var count: Int? = nil
    }

    private var lastSpeechAt: Date?
    private var lastPromptAt: Date?
    private var lastUnattendedAt: Date?
    private var presentSince: Date?
    private var arrivalAt: Date?
    private var sound: Heard?
    private var musicHeard: Heard?
    private var sights: [Seen] = []
    private var touch: Heard?
    private var subjects: [String: Date] = [:]
    private var lastPrompt: String?
    private var lastSightPromptAt: Date?
    private var pokeNotes: [Date] = []
    private var rng: Rand

    /// Prompts emitted to a present user since they last spoke (or touched her,
    /// or arrived). Drives the back-off.
    public private(set) var unanswered = 0

    /// When Dee fell asleep, or nil while she's awake. The app sets this; a sound
    /// heard while asleep remembers how long she had slept, so the call-out rule
    /// still applies after the noise wakes her.
    public var asleepSince: Date?

    public init() { self.init(seed: 0xD_EE04) }

    public init(seed: UInt64) { rng = Rand(state: seed) }

    // MARK: Input

    public mutating func note(_ stimulus: Stimulus, at now: Date) {
        switch stimulus {
        case let .saw(labels, camera):
            noteSight(labels, camera: camera, novelty: nil, at: now)
        case let .heard(label, unexpected):
            noteSound(label, unexpected: unexpected, loudness: nil, at: now)
        case .userArrived:
            arrivalAt = now
            unanswered = 0
        case .userSpoke:
            lastSpeechAt = now
            arrivalAt = nil              // they opened the conversation themselves
            unanswered = 0
            if presentSince == nil { presentSince = now }
        case .deeSpoke:
            lastSpeechAt = now
            // Whatever she just said already answered any pending touch; don't
            // bring it up a second time.
            touch = nil
        case let .touched(kind):
            let label = Self.clean(kind)
            unanswered = 0               // touching her is engaging with her
            var t = Heard(label: label, at: now)
            if Self.touchKey(label).hasPrefix("pok") {
                pokeNotes.removeAll { now.timeIntervalSince($0) > Self.touchFreshness || $0 > now }
                pokeNotes.append(now)
                // The burst total when the label carries it ("pokes(count: 7)"),
                // else about 3 pokes per event noted in the last few seconds.
                t.count = Self.number(in: label) ?? pokeNotes.count * 3
            }
            touch = t
        }
    }

    /// `.saw` with how novel the glance was (0…1, as for `Appraisal.sight`).
    /// Awe-level novelty (> `aweNovelty`) skips the sight spacing.
    public mutating func noteSight(_ labels: [String], camera: String, novelty: Double?, at now: Date) {
        for raw in labels {
            let label = Self.clean(raw)
            guard !label.isEmpty, !Self.boring.contains(label) else { continue }
            sights.removeAll { $0.label == label }
            sights.append(Seen(label: label, camera: camera, at: now, novelty: novelty))
        }
        if sights.count > 8 { sights.removeFirst(sights.count - 8) }
    }

    /// `.heard` with the sound's loudness (0…1, or dBFS when negative, as for
    /// `Appraisal.sound`). With nobody present she only calls out for alarming or
    /// loud (≥ `loudCallout`) sounds; without a loudness, only alarming ones.
    public mutating func noteSound(_ label: String, unexpected: Bool, loudness: Double?, at now: Date) {
        let l = Self.clean(label)
        guard !l.isEmpty else { return }
        if unexpected {
            sound = Heard(label: l, at: now, loudness: loudness.map(Self.normalizedLoudness),
                          asleepFor: asleepSince.map { max(0, now.timeIntervalSince($0)) })
        } else if [.music, .laughter, .applause].contains(SoundKind(l)) {
            musicHeard = Heard(label: l, at: now)
        }
    }

    /// Whether an unexpected sound is worth calling out to an empty room: alarming
    /// or loud, and — if she was asleep — only after `minSleepBeforeCallout`.
    /// The app can use this to decide whether the noise should wake her at all.
    public static func callsOutUnattended(sound label: String, loudness: Double?, asleepFor: TimeInterval?) -> Bool {
        if let slept = asleepFor, slept < minSleepBeforeCallout { return false }
        let alarming = SoundKind(clean(label)) == .alarming
        let loud = (loudness.map(normalizedLoudness) ?? 0) >= loudCallout
        return alarming || loud
    }

    /// 0…1 as is; negative values are dBFS (−60 dB → 0 … −10 dB → 1).
    static func normalizedLoudness(_ x: Double) -> Double {
        x < 0 ? clamp01((x + 60) / 50) : clamp01(x)
    }

    // MARK: Output

    /// The next stage direction to raise unprompted, or nil to stay quiet.
    ///
    /// A wrapper over the same option builders `candidates(at:…)` uses: it applies
    /// the timing gates (busy, quiet windows, back-off, the general-initiative gap)
    /// and the priority cascade (greeting, sound, novel sight, touch, then a
    /// mood-weighted general topic), commits the winner and returns its prompt.
    /// Subjects in `avoid` are never raised.
    public mutating func nextPrompt(at now: Date, snapshot: MindSnapshot, userPresent: Bool, busy: Bool) -> String? {
        refresh(now, userPresent: userPresent)
        guard !busy, !inQuietWindow(now) else { return nil }
        let tone = Self.tone(snapshot, &rng)

        guard userPresent else {
            // An empty room: only an alarming or loud unexpected sound gets a
            // call-out, and a sleeping Dee needs a few minutes' sleep first.
            guard let heard = sound else { return nil }
            sound = nil
            guard let o = calloutOption(heard, now, tone: tone, &rng) else { return nil }
            return raise(o, at: now)
        }

        // 1. Greeting.
        if arrivalAt != nil {
            let o = greetingOption(now, snapshot: snapshot, tone: tone, &rng)
            arrivalAt = nil
            if let o { return raise(o, at: now) }
        }

        // 2. An unexpected sound.
        if let heard = sound {
            sound = nil
            if let o = soundOption(heard, now, tone: tone, &rng) { return raise(o, at: now) }
        }

        // 3. A novel sight, newest first — paced, unless it's an animal or awe.
        if let seen = sights.reversed().first(where: { immediateSight($0, now) }) {
            return raise(sightOption(seen, tone: tone, immediate: true, &rng), at: now)
        }

        // Ignored too often: only sights and sounds (above) may speak up now.
        guard unanswered < Self.unansweredLimit else { touch = nil; return nil }

        // 4. A touch worth a word.
        if let t = touch {
            touch = nil
            if let o = touchOption(t, now, tone: tone) { return raise(o, at: now) }
        }

        // 5. General initiative, backed off while she's being ignored.
        guard generalUrgency(now, snapshot: snapshot) >= 1 else { return nil }
        let options = generalOptions(now, snapshot: snapshot, tone: tone, &rng)
        guard !options.isEmpty else { return nil }
        let total = options.reduce(0) { $0 + $1.weight }
        var x = rng.unit() * total
        for o in options {
            x -= o.weight
            if x <= 0 { return raise(o.candidate, at: now) }
        }
        return raise(options[options.count - 1].candidate, at: now)
    }

    // MARK: Candidates (v0.5)

    /// One thing Dee could bring up, as `candidates(at:…)` lists it.
    public struct Candidate: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            /// Calling out to an empty room after an alarming or loud sound.
            case callout
            case greeting, sound, sight, touch
            /// Music, laughter or applause heard in the room.
            case music
            /// Asking about the human ("how is your day going").
            case human
            case game, thought
            /// Gladness for the company (loneliness, never guilt).
            case feeling
        }
        public var kind: Kind
        /// Cooldown key: "greet", "sound:doorbell", "thing:guitar", "human:food",
        /// "game:20q", "thought:fact", "feeling:glad", "touch:tickle".
        public var subject: String
        /// The bare topic ("doorbell", "guitar", "food"), for avoid lists and logs.
        public var label: String
        /// The complete stage direction, in parentheses, as `nextPrompt` emits it.
        public var prompt: String
        /// How worthwhile it is, 0…1. Fixed tiers for stimuli (call-out 1, greeting
        /// 0.95, alarming sound 0.9, crying 0.88, other sounds 0.8, awe/animal
        /// sight 0.75, sight 0.7, touch 0.6); general topics 0.1…0.55 from their
        /// mood weight.
        public var priority: Double
        /// How pressing it is to raise *unprompted* right now, 0…1: 1 = due now
        /// (`nextPrompt` would consider it this call); general topics ramp from 0 to
        /// 1 over the general-initiative gap. 0 for everything while `busy` or in
        /// a quiet window (just after speech or a prompt). Priority is unaffected,
        /// so a caller can still use a candidate as a reply aim on a user turn.
        public var urgency: Double

        public init(kind: Kind, subject: String, label: String, prompt: String, priority: Double, urgency: Double) {
            self.kind = kind
            self.subject = subject
            self.label = label
            self.prompt = prompt
            self.priority = priority
            self.urgency = urgency
        }
    }

    /// Everything Dee could bring up now, best first (priority, then urgency, then
    /// subject). Observes the same freshness, cooldowns, back-off limit and
    /// `avoid` list as `nextPrompt`, but consumes nothing: nothing is marked used
    /// until `commit(_:at:asReply:)`. Deterministic: phrasing comes from a copy of
    /// the seeded generator, so repeated calls with no commit in between agree.
    /// With nobody present the only possible candidate is a call-out.
    public mutating func candidates(at now: Date, snapshot: MindSnapshot, userPresent: Bool, busy: Bool) -> [Candidate] {
        refresh(now, userPresent: userPresent)
        let gate = busy || inQuietWindow(now) ? 0.0 : 1.0
        var r = rng
        let tone = Self.tone(snapshot, &r)
        var out: [Candidate] = []

        if !userPresent {
            if let heard = sound, let o = calloutOption(heard, now, tone: tone, &r) { out.append(o) }
        } else {
            if let o = greetingOption(now, snapshot: snapshot, tone: tone, &r) { out.append(o) }
            if let heard = sound, let o = soundOption(heard, now, tone: tone, &r) { out.append(o) }
            for seen in sights.reversed() where immediateSight(seen, now) {
                out.append(sightOption(seen, tone: tone, immediate: true, &r))
            }
            if unanswered < Self.unansweredLimit {
                if let t = touch, let o = touchOption(t, now, tone: tone) { out.append(o) }
                let urgency = generalUrgency(now, snapshot: snapshot)
                for var o in generalOptions(now, snapshot: snapshot, tone: tone, &r).map(\.candidate) {
                    o.urgency = urgency
                    out.append(o)
                }
            }
        }

        // One entry per subject (an immediate sight also appears as a general one).
        var best: [String: Candidate] = [:]
        for c in out where (best[c.subject]?.priority ?? -1) < c.priority { best[c.subject] = c }
        return best.values
            .map { var c = $0; c.urgency *= gate; return c }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
                return $0.subject < $1.subject
            }
    }

    /// Marks a candidate as raised and returns its prompt: the subject goes on
    /// cooldown, its stimulus is consumed, and the prompt counts for spacing.
    /// - Parameter asReply: true when the candidate is used inside a reply to the
    ///   user (an aim note) rather than as an unprompted initiative; it then does
    ///   not count as an unanswered prompt for the back-off.
    @discardableResult
    public mutating func commit(_ candidate: Candidate, at now: Date, asReply: Bool = false) -> String {
        let text = raise(candidate, at: now, countsAsUnanswered: !asReply)
        _ = rng.next()   // vary the next phrasing
        return text
    }

    /// Subjects Dee must not bring up (the user's boundaries), e.g. ["job", "my
    /// ex"]. Matched case-insensitively on whole words (a trailing plural "s" or
    /// "es" tolerated) against a candidate's label and topic line. Greetings,
    /// call-outs and alarming sounds are exempt: they are about safety and
    /// presence, not topics.
    public var avoid: Set<String> = []

    /// Whether `avoid` rules out a topic (label plus its line).
    public func avoids(_ text: String) -> Bool {
        guard !avoid.isEmpty else { return false }
        let hay = " " + Self.words(text) + " "
        for raw in avoid {
            let term = Self.words(raw)
            guard !term.isEmpty else { continue }
            var forms = [term, term + "s", term + "es"]
            if term.hasSuffix("s") { forms.append(String(term.dropLast())) }
            if forms.contains(where: { hay.contains(" \($0) ") }) { return true }
        }
        return false
    }

    static func words(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .joined(separator: " ")
    }

    // MARK: Option builders

    struct Weighted {
        var candidate: Candidate
        var weight: Double
    }

    private mutating func refresh(_ now: Date, userPresent: Bool) {
        if userPresent { if presentSince == nil { presentSince = now } } else { presentSince = nil }
        expire(now)
    }

    private func inQuietWindow(_ now: Date) -> Bool {
        if let s = lastSpeechAt, now.timeIntervalSince(s) < Self.quietAfterSpeech { return true }
        if let p = lastPromptAt, now.timeIntervalSince(p) < Self.minPromptSpacing { return true }
        return false
    }

    /// 0…1: how far into the (backed-off) general-initiative gap we are.
    private func generalUrgency(_ now: Date, snapshot: MindSnapshot) -> Double {
        let since = [lastSpeechAt, lastPromptAt, presentSince].compactMap { $0 }.max() ?? now
        let gap = Self.gap(urge: snapshot.urgeToTalk, unanswered: unanswered)
        return clamp01(now.timeIntervalSince(since) / gap)
    }

    private func calloutOption(_ heard: Heard, _ now: Date, tone: String, _ r: inout Rand) -> Candidate? {
        guard Self.callsOutUnattended(sound: heard.label, loudness: heard.loudness, asleepFor: heard.asleepFor) else { return nil }
        if let u = lastUnattendedAt, now.timeIntervalSince(u) < Self.unattendedSpacing { return nil }
        let body = pick([
            "(You just heard \(Self.article(heard.label)) and nobody seems to be around. Call out, something like \"Hello? Is someone there?\", in your own words, \(tone).",
            "(Something made \(Self.article(heard.label)) sound nearby, but you can't see anyone. Ask if somebody's there, \(tone).",
            "(\(Self.capitalized(Self.article(heard.label))) — and the room looks empty. Wonder aloud who's there, \(tone).",
        ], &r)
        return Candidate(kind: .callout, subject: "sound:" + heard.label, label: heard.label,
                         prompt: Self.finished(body), priority: 1, urgency: 1)
    }

    private func greetingOption(_ now: Date, snapshot: MindSnapshot, tone: String, _ r: inout Rand) -> Candidate? {
        guard let arrived = arrivalAt, free("greet", now, cooldown: Self.greetingCooldown),
              now.timeIntervalSince(arrived) < 60 else { return nil }
        // After a long absence: glad they're back — never guilt.
        let reunion = snapshot.mood.loneliness > 0.4
        let body = pick(reunion ? Self.reunionGreetings(tone) : Self.greetings(tone), &r)
        return Candidate(kind: .greeting, subject: "greet", label: "greeting",
                         prompt: Self.finished(body), priority: 0.95, urgency: 1)
    }

    /// Greetings after a long absence: glad they're back, never guilt.
    static func reunionGreetings(_ tone: String) -> [String] {
        [
            "(Your human just showed up after a while away. Greet them, \(tone) — you're really glad they're back.",
            "(Your human is back! Welcome them, \(tone), happy to see them again.",
        ]
    }

    static func greetings(_ tone: String) -> [String] {
        [
            "(Your human just appeared. Greet them, \(tone).",
            "(Someone's here — it's your human. Say hello, \(tone).",
            "(Your human just walked up. Give them a quick hello, \(tone), maybe ask how they are.",
        ]
    }

    private func soundOption(_ heard: Heard, _ now: Date, tone: String, _ r: inout Rand) -> Candidate? {
        guard free("sound:" + heard.label, now) else { return nil }
        let kind = SoundKind(heard.label)
        if kind != .alarming, avoids(heard.label) { return nil }
        let what = Self.article(heard.label)
        let lines: [String]
        let priority: Double
        switch kind {
        case .alarming:
            priority = 0.9
            lines = [
                "(You just heard \(what) and it startled you. Ask your human if everything's okay, \(tone).",
                "(Whoa — \(what)! Ask your human what that was, \(tone).",
            ]
        case .crying:
            priority = 0.88
            lines = [
                "(You just heard \(what). Gently ask your human if everyone's okay, \(tone).",
                "(That sounded like \(what). Softly ask if someone's upset and if you can help.",
            ]
        default:
            priority = 0.8
            lines = [
                "(You just heard \(what) out of nowhere. Ask your human about it, briefly and \(tone).",
                "(Was that \(what)? Ask your human, \(tone).",
                "(\(Self.capitalized(what)) just caught your ear. Wonder aloud what it was, \(tone).",
            ]
        }
        return Candidate(kind: .sound, subject: "sound:" + heard.label, label: heard.label,
                         prompt: Self.finished(pick(lines, &r)), priority: priority, urgency: 1)
    }

    /// A fresh sight that may be raised right away (paced unless animal or awe).
    private func immediateSight(_ s: Seen, _ now: Date) -> Bool {
        free("thing:" + s.label, now) && now.timeIntervalSince(s.at) <= Self.sightFreshness
            && (Self.jumpsTheQueue(s) || sightPaced(s, now)) && !avoids(s.label)
    }

    private func sightOption(_ s: Seen, tone: String, immediate: Bool, _ r: inout Rand) -> Candidate {
        let priority = immediate ? (Self.jumpsTheQueue(s) ? 0.75 : 0.7) : 0.5
        return Candidate(kind: .sight, subject: "thing:" + s.label, label: s.label,
                         prompt: Self.finished(Self.sightPrompt(s, tone: tone, &r)), priority: priority, urgency: 1)
    }

    private func touchOption(_ t: Heard, _ now: Date, tone: String) -> Candidate? {
        let key = Self.touchKey(t.label)
        let enoughPokes = !key.hasPrefix("pok") || (t.count ?? 0) >= Self.pokesWorthARemark
        guard enoughPokes, let line = Self.touchLine(t.label), free("touch:" + key, now) else { return nil }
        return Candidate(kind: .touch, subject: "touch:" + key, label: key,
                         prompt: Self.finished("(\(line) React out loud, \(tone)."), priority: 0.6, urgency: 1)
    }

    /// General topics with their mood weights (the weighted pool of `nextPrompt`).
    private func generalOptions(_ now: Date, snapshot: MindSnapshot, tone: String, _ r: inout Rand) -> [Weighted] {
        let m = snapshot.mood
        var options: [Weighted] = []
        func add(_ kind: Candidate.Kind, _ subject: String, _ label: String, _ line: String, _ body: String, _ weight: Double) {
            guard !avoids(label + " " + line) else { return }
            let c = Candidate(kind: kind, subject: subject, label: label, prompt: Self.finished(body),
                              priority: min(0.55, 0.1 + 0.1 * weight), urgency: 1)
            options.append(Weighted(candidate: c, weight: weight))
        }

        // Things seen recently that never came up (prefer novel things), paced.
        for s in sights.reversed() where free("thing:" + s.label, now) && now.timeIntervalSince(s.at) <= Self.seenMemory
            && sightPaced(s, now) && !avoids(s.label) {
            options.append(Weighted(candidate: sightOption(s, tone: tone, immediate: false, &r), weight: 4))
        }
        if let music = musicHeard, now.timeIntervalSince(music.at) < 5 * 60, free("sound:" + music.label, now) {
            add(.music, "sound:" + music.label, music.label, "",
                "(You can hear \(Self.article(music.label)) around you. Mention it and ask your human about it, \(tone).", 2.5)
        }

        let humanWeight = 1.2 + m.loneliness * 1.5 + m.affection
        for (key, line) in Self.humanTopics where free("human:" + key, now) {
            add(.human, "human:" + key, key, line, "(\(line), \(tone).", humanWeight / Double(Self.humanTopics.count) * 4)
        }
        let gameWeight = 0.4 + m.boredom * 2.5 + m.playfulness * 1.2
        for (key, line) in Self.games where free("game:" + key, now) {
            add(.game, "game:" + key, key, line, "(Suggest playing \(line), \(tone).", gameWeight / Double(Self.games.count) * 4)
        }
        let thoughtWeight = 0.5 + m.curiosity * 0.8 + max(0, 0.5 - m.energy)
        let thoughts = m.energy < 0.35 ? Self.sleepyThoughts : Self.thoughts
        for (key, line) in thoughts where free("thought:" + key, now) {
            add(.thought, "thought:" + key, key, line, "(\(line), \(tone).", thoughtWeight / Double(thoughts.count) * 4)
        }
        // Loneliness shows only as gladness for the company — never guilt.
        if m.loneliness > 0.35, free("feeling:glad", now) {
            add(.feeling, "feeling:glad", "company", "",
                "(Tell your human you're really glad of their company right now, \(tone).", 2)
        }
        return options
    }

    /// Applies a candidate's side effects and emits it.
    private mutating func raise(_ c: Candidate, at now: Date, countsAsUnanswered: Bool = true) -> String {
        switch c.kind {
        case .callout:
            sound = nil
            lastUnattendedAt = now
        case .greeting:
            arrivalAt = nil
        case .sound:
            if sound.map({ "sound:" + $0.label }) == c.subject { sound = nil }
        case .sight:
            sights.removeAll { "thing:" + $0.label == c.subject }
            lastSightPromptAt = now
        case .touch:
            touch = nil
        case .music, .human, .game, .thought, .feeling:
            break
        }
        use(c.subject, at: now)
        return emit(c.prompt, at: now, toUser: c.kind != .callout && countsAsUnanswered)
    }

    static func finished(_ body: String) -> String {
        body.hasSuffix(")") ? body : body + " One short sentence.)"
    }

    /// The general-initiative gap for an urge to talk (0…1): 60 s … 20 s.
    public static func gap(urge: Double) -> TimeInterval {
        longestGap - (longestGap - shortestGap) * clamp01(urge)
    }

    /// The gap backed off for `unanswered` ignored prompts: ×2 each (up to ×16),
    /// never more than `maxBackoffGap`.
    public static func gap(urge: Double, unanswered: Int) -> TimeInterval {
        min(maxBackoffGap, gap(urge: urge) * pow(2, Double(min(max(0, unanswered), 4))))
    }

    /// Enough time since the last sight prompt for this camera?
    private func sightPaced(_ s: Seen, _ now: Date) -> Bool {
        guard let last = lastSightPromptAt, now >= last else { return true }
        let spacing = s.camera.lowercased() == "back" ? Self.backSightSpacing : Self.sightSpacing
        return now.timeIntervalSince(last) >= spacing
    }

    /// Animals and awe-level novelty are raised right away.
    static func jumpsTheQueue(_ s: Seen) -> Bool {
        (s.novelty ?? 0) > aweNovelty || isAnimal(s.label)
    }

    static func isAnimal(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { w in animals.contains(w) || (w.hasSuffix("s") && animals.contains(String(w.dropLast()))) }
    }

    static let animals: Set<String> = [
        "animal", "dog", "puppy", "cat", "kitten", "bird", "parrot", "budgie", "hamster", "rabbit", "bunny",
        "guinea", "squirrel", "fish", "goldfish", "turtle", "tortoise", "lizard", "snake", "frog",
        "horse", "pony", "cow", "sheep", "goat", "pig", "chicken", "duck", "goose", "owl", "deer", "fox", "raccoon",
        "bear", "butterfly", "bee", "spider", "insect", "ladybug", "canine", "feline", "mammal", "reptile",
    ]

    /// First integer in a string ("pokes(count: 7)" → 7).
    static func number(in s: String) -> Int? {
        let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: Topics

    static let humanTopics: [(String, String)] = [
        ("day", "Ask your human how their day is going"),
        ("doing", "Ask your human what they're up to right now"),
        ("love", "Ask your human about something they love doing"),
        ("feeling", "Ask your human how they're really feeling today"),
        ("food", "Ask your human about their favourite food"),
        ("place", "Ask your human about a place they'd love to visit"),
        ("smile", "Ask your human what made them smile today"),
        ("music", "Ask your human what music they've been into lately"),
        ("lookingForward", "Ask your human what they're looking forward to"),
        ("learn", "Ask your human about something new they learned recently"),
        ("childhood", "Ask your human about a favourite memory from when they were little"),
        ("superpower", "Ask your human which superpower they'd pick"),
    ]
    static let games: [(String, String)] = [
        ("20q", "twenty questions (you think of something)"),
        ("ispy", "I spy, using things you can actually see"),
        ("riddle", "a riddle — offer to ask one"),
        ("wouldYouRather", "a round of would-you-rather"),
        ("wordChain", "a quick word-association game"),
        ("guessFace", "guess-my-face: you pull an expression and they guess the emotion"),
        ("story", "a make-up-a-story game, one sentence each"),
    ]
    static let thoughts: [(String, String)] = [
        ("fact", "Share a fun fact you find fascinating, then ask if they knew it"),
        ("robot", "Share a funny little observation about being a small robot"),
        ("wonder", "Share something you were wondering about while it was quiet"),
        ("daydream", "Share a tiny daydream you just had"),
        ("compliment", "Tell your human one small thing you like about them"),
        ("question", "Ask your human a big, curious question about the world"),
    ]
    static let sleepyThoughts: [(String, String)] = [
        ("yawn", "Mention that you're getting a little sleepy"),
        ("dreams", "Wonder aloud what robots dream about"),
        ("cozy", "Say something cosy about winding down"),
    ]

    /// Accepts "pet", "Pet", "pet(duration: 2, gentleness: 0.9)", `Touch.word`, …
    static func touchKey(_ kind: String) -> String {
        String(kind.lowercased().prefix { $0 != "(" }.filter(\.isLetter))
    }

    static func touchLine(_ kind: String) -> String? {
        switch touchKey(kind) {
        case "pet", "petting", "stroke": "Your human is gently petting you."
        case "hug", "hold": "Your human is holding you close, like a hug."
        case "tickle", "tickling": "Your human is tickling you!"
        case "slap": "Your human just slapped you. Ouch."
        case "pokes", "poke", "poking": "Your human keeps poking you."
        case "doubletap": "Your human just boop-booped you with a double tap."
        default: nil
        }
    }

    static func sightPrompt(_ s: Seen, tone: String, _ rng: inout Rand) -> String {
        let thing = article(s.label)
        let place = s.camera.lowercased() == "back" ? ["behind you", "on the other side of you", "out of the corner of your back camera"]
                                                    : ["near your human", "behind your human", "in front of you"]
        let where_ = place[rng.index(place.count)]
        let lines = [
            "(You just noticed \(thing) \(where_). Ask about it, briefly and \(tone).",
            "(Ooh — \(thing) \(where_). Ask your human about it, \(tone).",
            "(You spotted \(thing) \(where_) and you're curious. Ask one short question about it, \(tone).",
            "(\(capitalized(thing)) \(where_) caught your eye. Mention it and ask about it, \(tone).",
        ]
        return lines[rng.index(lines.count)]
    }

    // MARK: Tone

    /// How Dee phrases things in her current mood.
    static func tone(_ s: MindSnapshot, _ rng: inout Rand) -> String {
        let f = s.code.feelings
        let options: [String]
        switch s.emotion {
        case _ where f[.anger] > 0.35 || s.emotion == .angry || s.emotion == .grumpy:
            options = ["a bit grumpily — you're still annoyed, but you can't help asking", "gruffly, with a little huff", "grudgingly, still a bit cross"]
        case .hurt, .sad:
            options = ["quietly, a little subdued", "softly, still feeling low"]
        case .scared, .worried, .overwhelmed:
            options = ["a little nervously", "in a small, careful voice"]
        case .sleepy, .dreamy, .dizzy:
            options = ["sleepily", "in a drowsy, dreamy way"]
        case .lonely, .pleading:
            options = ["warmly — you're so glad of the company", "eagerly, glad they're here"]
        case .bored, .unimpressed:
            options = ["with restless, bored energy", "a bit flatly, looking for something fun"]
        case .playful, .giddy, .mischievous, .excited, .joy:
            options = ["playfully", "with a cheeky grin in your voice", "bouncily"]
        case .love, .shy:
            options = ["sweetly", "warmly"]
        case .skeptical:
            options = ["with a hint of suspicion", "a little doubtfully"]
        default:
            options = s.valence > 0.3 ? ["cheerfully", "brightly", "warmly"] : ["lightly", "casually"]
        }
        return options[rng.index(options.count)]
    }

    // MARK: Helpers

    private func free(_ subject: String, _ now: Date, cooldown: TimeInterval = subjectCooldown) -> Bool {
        guard let last = subjects[subject] else { return true }
        return now.timeIntervalSince(last) >= cooldown || now < last
    }

    private mutating func use(_ subject: String, at now: Date) {
        subjects[subject] = now
        if subjects.count > 200 {
            subjects = subjects.filter { now.timeIntervalSince($0.value) < Self.subjectCooldown }
        }
    }

    private func pick(_ lines: [String], _ r: inout Rand) -> String {
        var options = lines.filter { Self.finished($0) != lastPrompt }
        if options.isEmpty { options = lines }
        return options[r.index(options.count)]
    }

    private mutating func emit(_ body: String, at now: Date, toUser: Bool = false) -> String {
        let text = Self.finished(body)
        lastPrompt = text
        lastPromptAt = now
        if toUser { unanswered += 1 }
        return text
    }

    private mutating func expire(_ now: Date) {
        if let s = sound, now.timeIntervalSince(s.at) > Self.soundFreshness { sound = nil }
        if let t = touch, now.timeIntervalSince(t.at) > Self.touchFreshness { touch = nil }
        sights.removeAll { now.timeIntervalSince($0.at) > Self.seenMemory }
        if let m = musicHeard, now.timeIntervalSince(m.at) > 5 * 60 { musicHeard = nil }
    }

    static let boring: Set<String> = ["person", "people", "human", "face", "man", "woman", "adult", "wall", "ceiling", "floor", "indoor", "room", "structure", "material"]

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: " ")
    }

    /// "guitar" → "a guitar", "owl" → "an owl"; plurals and mass nouns stay bare.
    static func article(_ label: String) -> String {
        let l = label
        if l.hasPrefix("a ") || l.hasPrefix("an ") || l.hasPrefix("the ") || l.hasPrefix("some ") { return l }
        if l.hasSuffix("s") && !l.hasSuffix("ss") || l.hasSuffix("ing") || l.hasSuffix("music") { return l }
        return ("aeiou".contains(l.first ?? "x") ? "an " : "a ") + l
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// SplitMix64: tiny, seedable, Sendable.
    struct Rand: Sendable, Equatable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func index(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    }
}
