import DeeMind
import Foundation

/// SELF.md §8.1 — the deterministic Reflector. No LLM, no clock, no global randomness:
/// stored records in, `[SelfWrite]` and an updated `Enduring` out.
///
/// **When:** `EpisodeBuilder` emits `.reflect` (asleep ≥ 300 s, a conversation of ≥ 4
/// user turns ended, or 6 h of awake time). The app then runs, while Cortex is idle:
///
/// ```swift
/// for e in cortex.flush(at: now) { … }                                     // apply pending writes first
/// let input = try await Reflector.load(from: selfStore, enduring: cortex.moment.enduring,
///                                      people: memory.people().map(\.id), at: now)
/// let out = Reflector.reflect(input, at: now)
/// try await Reflector.commit(out, to: selfStore, at: now)                  // one batch + last_reflection
/// cortex.setEnduring(out.enduring)                                         // index, facets, lessons, gags, rituals
/// ```
///
/// **Steps** (in order, each deterministic):
/// 1. Merge near-duplicate episodes: same person, ≥ 2 shared topics, ends within 24 h.
///    The more salient survives (span, topics ≤ 3, recall counts, open loop folded in).
/// 2. Salience × 0.9, except episodes whose open loop is still a live intention. The
///    factor is per nominal daily pass: 0.9^(days since the last reflection, ≤ 7), so
///    running often does not age memories faster (deviation: §8.1 says "per pass").
/// 3. Tastes: crystallise at evidence ≥ 3 and |polarity| ≥ 0.35 with a template reason
///    (innate → "no idea why, you just do"; learned → "since {episode gist}"); a
///    crystallised taste flips (new sign, new reason) only after 3 contrary exposures;
///    below |0.35| without 3 contrary it stays crystallised (hysteresis).
///    Interests are not rewritten: their 7 d half-life is applied from `lastTouched`.
/// 4. Lessons: effective evidence = evidence × 0.95^(weeks since last applied / created);
///    retired (`deleteLesson`) below 1. Skill intentions are not touched: IntentionBoard
///    owns their steps (one per clean conversation) and Cortex's RAM copy would overwrite
///    a Reflector write anyway (review finding 22).
/// 5. Live intentions and pending/asked expectations past `expires` → dropped / expired,
///    silently. Gags with ≥ 6 uses or a flat streak of 2 → retired.
/// 6. Rituals are not touched: Learner owns them (births at 3 consecutive local days,
///    silent streak resets, the variant), in the user's time zone (review finding 22).
///    `ritualEvidence` is accepted for compatibility and ignored.
/// 7. Prune to 300 episodes per person and 1,000 total by lowest salience × recency
///    (exp(−days/30)); live open loops go last. Each pruned episode → `digest.lowSalience`.
/// 8. Rebuild the episode index (top 300 by salience × recency) and the self-block
///    preview used at the next `newConversation`.
public enum Reflector {
    public static let mergeWindow: TimeInterval = 86_400
    public static let mergeSharedTopics = 2
    public static let salienceDecay = 0.9
    public static let maxDecayDays = 7.0
    public static let lessonDecayPerWeek = 0.95
    public static let crystalliseEvidence = 3
    public static let crystallisePolarity = 0.35
    public static let flipContrary = 3
    public static let gagMaxUses = 6
    public static let gagMaxFlat = 2
    public static let skillCleanConversations = 5
    public static let ritualDays = 3
    public static let maxEpisodesPerPerson = 300
    public static let maxEpisodes = 1000
    public static let innateReason = "no idea why, you just do"

    /// A daily digest row (`SelfStore.digest(day:person:)`).
    public struct Digest: Sendable, Equatable {
        public var day: String
        public var person: PersonID?
        public var conversations: Int
        public var lowSalience: Int
        public init(day: String, person: PersonID?, conversations: Int, lowSalience: Int) {
            self.day = day
            self.person = person
            self.conversations = conversations
            self.lowSalience = lowSalience
        }
    }

    /// Days (`yyyy-MM-dd`) on which a ritual trigger happened for a person (Learner).
    public struct RitualEvidence: Sendable, Equatable {
        public var person: PersonID?
        public var trigger: Ritual.Trigger
        public var days: [String]
        public init(person: PersonID?, trigger: Ritual.Trigger, days: [String]) {
            self.person = person
            self.trigger = trigger
            self.days = days
        }
    }

    /// Stored records only (never conversation text).
    public struct Input: Sendable, Equatable {
        public var enduring: Enduring
        public var episodes: [Episode]
        public var intentions: [Intention]
        public var expectations: [Expectation]
        public var misreads: [Misread]
        public var digests: [Digest]
        public var ritualEvidence: [RitualEvidence]
        public var lastReflection: Date?

        public init(enduring: Enduring, episodes: [Episode] = [], intentions: [Intention] = [], expectations: [Expectation] = [],
                    misreads: [Misread] = [], digests: [Digest] = [], ritualEvidence: [RitualEvidence] = [], lastReflection: Date? = nil) {
            self.enduring = enduring
            self.episodes = episodes
            self.intentions = intentions
            self.expectations = expectations
            self.misreads = misreads
            self.digests = digests
            self.ritualEvidence = ritualEvidence
            self.lastReflection = lastReflection
        }
    }

    public struct Report: Sendable, Equatable {
        public var merged = 0, decayed = 0, crystallised = 0, flipped = 0, lessonsRetired = 0, skillsAdvanced = 0, skillsDone = 0
        public var intentionsExpired = 0, expectationsExpired = 0, gagsRetired = 0, ritualsMinted = 0, streaksReset = 0, pruned = 0
        public init() {}
    }

    public struct Output: Sendable, Equatable {
        public var enduring: Enduring
        public var episodes: [Episode]
        public var intentions: [Intention]
        public var expectations: [Expectation]
        /// In order; apply as one batch.
        public var writes: [SelfWrite]
        public var report: Report
        /// The self block the next conversation will render (global; person lines are added at render time).
        public var selfBlockPreview: [String]
    }

    /// Runs one pass with the Reflector's own stream (ids for minted rituals).
    public static func reflect(_ input: Input, at now: Date) -> Output {
        var rng = Rand(seed: input.enduring.seed ^ StableHash.of("Reflector") ^ UInt64(bitPattern: Int64(now.timeIntervalSince1970.rounded(.down))))
        return reflect(input, at: now, rng: &rng)
    }

    public static func reflect(_ input: Input, at now: Date, rng: inout Rand) -> Output {
        var e = input.enduring
        var report = Report()
        var writes: [SelfWrite] = []
        var intentions = input.intentions
        var expectations = input.expectations
        let liveLoops = Set(input.intentions.filter(\.isLive).map(\.id))

        // 1. Merge near-duplicates.
        var episodes = input.episodes.sorted(by: episodeOrder)
        var removed: Set<UUID> = []
        var changed: Set<UUID> = []
        for i in episodes.indices where !removed.contains(episodes[i].id) {
            for j in episodes.indices where j != i && !removed.contains(episodes[j].id) && !removed.contains(episodes[i].id) {
                guard mergeable(episodes[i], episodes[j]) else { continue }
                episodes[i] = merged(episodes[i], episodes[j])
                removed.insert(episodes[j].id)
                changed.insert(episodes[i].id)
                writes.append(.deleteEpisode(episodes[j].id))
                report.merged += 1
            }
        }
        episodes.removeAll { removed.contains($0.id) }

        // 2. Salience decay.
        let days = input.lastReflection.map { min(maxDecayDays, max(0, now.timeIntervalSince($0) / 86_400)) } ?? 1
        let factor = pow(salienceDecay, days)
        if factor < 1 {
            for i in episodes.indices where !(episodes[i].openLoop.map(liveLoops.contains) ?? false) {
                episodes[i].salience *= factor
                changed.insert(episodes[i].id)
                report.decayed += 1
            }
        }

        // 3. Tastes.
        for i in e.facets.indices where e.facets[i].kind == .taste {
            var f = e.facets[i]
            let before = f
            f.polarity = 0.5 * f.innate + 0.5 * f.learned
            if !f.crystallised {
                if f.evidence >= crystalliseEvidence && abs(f.polarity) >= crystallisePolarity {
                    f.crystallised = true
                    f.contrary = 0
                    f.reason = reason(for: f, episodes: episodes)
                    f.source = f.source == .seed ? .seed : .reflection
                    report.crystallised += 1
                }
            } else if f.contrary >= flipContrary {
                f.contrary = 0
                f.crystallised = abs(f.polarity) >= crystallisePolarity
                f.reason = f.crystallised ? reason(for: f, episodes: episodes) : nil
                report.flipped += 1
            }
            if f != before {
                f.updatedAt = now
                e.facets[i] = f
                writes.append(.facet(f))
            }
        }

        // 4. Lessons, skill intentions.
        for l in e.lessons {
            let weeks = max(0, now.timeIntervalSince(l.lastApplied ?? l.createdAt)) / (7 * 86_400)
            if Double(l.evidence) * pow(lessonDecayPerWeek, weeks) < 1 {
                writes.append(.deleteLesson(l.id))
                report.lessonsRetired += 1
            }
        }
        let retired = Set(writes.compactMap { w -> UUID? in if case .deleteLesson(let id) = w { id } else { nil } })
        e.lessons.removeAll { retired.contains($0.id) }

        // 5. Silent expiry; gag retirement.
        for i in intentions.indices where intentions[i].isLive && now >= intentions[i].expires {
            intentions[i].status = .dropped
            intentions[i].updated = now
            writes.append(.intention(intentions[i]))
            report.intentionsExpired += 1
        }
        for i in expectations.indices where (expectations[i].status == .pending || expectations[i].status == .asked) && now >= expectations[i].expires {
            expectations[i].status = .expired
            writes.append(.expectation(expectations[i]))
            report.expectationsExpired += 1
        }
        for i in e.gags.indices where !e.gags[i].retired && (e.gags[i].uses >= gagMaxUses || e.gags[i].flatStreak >= gagMaxFlat) {
            e.gags[i].retired = true
            writes.append(.gag(e.gags[i]))
            report.gagsRetired += 1
        }

        // 7. Prune.
        func keepScore(_ x: Episode) -> Double {
            (x.openLoop.map(liveLoops.contains) ?? false) ? .infinity : keep(x.key, at: now)
        }
        var pruned: Set<UUID> = []
        let people = orderedPeople(episodes)
        for p in people {
            let mine = episodes.filter { $0.person == p }
            guard mine.count > maxEpisodesPerPerson else { continue }
            for x in mine.sorted(by: { lowerKeep($0, $1, keepScore) }).prefix(mine.count - maxEpisodesPerPerson) { pruned.insert(x.id) }
        }
        let left = episodes.filter { !pruned.contains($0.id) }
        if left.count > maxEpisodes {
            for x in left.sorted(by: { lowerKeep($0, $1, keepScore) }).prefix(left.count - maxEpisodes) { pruned.insert(x.id) }
        }
        for x in episodes where pruned.contains(x.id) {
            writes.append(.deleteEpisode(x.id))
            writes.append(.digest(day: EpisodeBuilder.day(x.end), person: x.person, conversations: 0, lowSalience: 1))
            report.pruned += 1
        }
        episodes.removeAll { pruned.contains($0.id) }
        for x in episodes where changed.contains(x.id) { writes.append(.episode(x)) }

        // 8. Index and preview.
        e.episodeIndex = Array(episodes.sorted { a, b in
            let x = keep(a.key, at: now), y = keep(b.key, at: now)
            return x != y ? x > y : episodeOrder(a, b)
        }.prefix(Enduring.maxEpisodeIndex).map(\.key))
        return Output(enduring: e, episodes: episodes, intentions: intentions, expectations: expectations, writes: writes,
                      report: report, selfBlockPreview: SelfBlock.render(e, person: nil))
    }

    // MARK: - Store plumbing (the only impure part: reads and writes through SelfStore)

    /// Loads everything a pass needs from the store. `people` are DeeMemory's ids
    /// (episodes are fetched per person plus the global ones).
    public static func load(from store: SelfStore, enduring: Enduring, people: [PersonID], at now: Date,
                            ritualEvidence: [RitualEvidence] = []) async throws -> Input {
        var episodes: [Episode] = []
        for p in [nil] + people.sorted(by: { $0.uuidString < $1.uuidString }).map(Optional.some) {
            episodes += try await store.episodes(person: p, limit: maxEpisodes + 1)
        }
        let intentions = try await store.intentions(live: false)
        let misreads = try await store.misreads()
        // Digest rows for skill progress: each day since the oldest live skill intention.
        var digests: [Digest] = []
        let skills = intentions.filter { $0.kind == .skill && $0.isLive }
        if let oldest = skills.map(\.created).min() {
            var d = oldest
            var n = 0
            while d <= now && n < 60 {
                let day = EpisodeBuilder.day(d)
                for p in Array(Set(skills.map(\.person))).sorted(by: { ($0?.uuidString ?? "") < ($1?.uuidString ?? "") }) {
                    if let row = try await store.digest(day: day, person: p) {
                        digests.append(Digest(day: day, person: p, conversations: row.conversations, lowSalience: row.lowSalience))
                    }
                }
                d = d.addingTimeInterval(86_400)
                n += 1
            }
        }
        let last = try await store.meta("last_reflection").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return Input(enduring: enduring, episodes: episodes, intentions: intentions, expectations: try await store.expectations(pending: false),
                     misreads: misreads, digests: digests, ritualEvidence: ritualEvidence, lastReflection: last)
    }

    /// Applies the pass as one batch and stamps `last_reflection`.
    @discardableResult
    public static func commit(_ out: Output, to store: SelfStore, at now: Date) async throws -> SelfStore.ApplyResult {
        let r = try await store.apply(out.writes)
        try await store.setMeta("last_reflection", String(now.timeIntervalSince1970))
        return r
    }

    // MARK: - Helpers

    /// salience × recency (exp(−days/30)): what pruning and the index keep.
    public static func keep(_ k: EpisodeKey, at now: Date) -> Double {
        k.salience * exp(-max(0, now.timeIntervalSince(k.end)) / 86_400 / EpisodeBuilder.recallTimescaleDays)
    }

    static func lowerKeep(_ a: Episode, _ b: Episode, _ score: (Episode) -> Double) -> Bool {
        let x = score(a), y = score(b)
        return x != y ? x < y : !episodeOrder(a, b)
    }

    /// Most salient first, then newest, then id (total and stable).
    static func episodeOrder(_ a: Episode, _ b: Episode) -> Bool {
        if a.salience != b.salience { return a.salience > b.salience }
        if a.end != b.end { return a.end > b.end }
        return a.id.uuidString < b.id.uuidString
    }

    static func orderedPeople(_ xs: [Episode]) -> [PersonID?] {
        var out: [PersonID?] = []
        for x in xs where !out.contains(x.person) { out.append(x.person) }
        return out.sorted { ($0?.uuidString ?? "") < ($1?.uuidString ?? "") }
    }

    static func sharedTopics(_ a: Episode, _ b: Episode) -> Int {
        a.topics.filter { t in b.topics.contains { $0.overlaps(t) } }.count
    }

    static func mergeable(_ a: Episode, _ b: Episode) -> Bool {
        a.person == b.person && sharedTopics(a, b) >= mergeSharedTopics && abs(a.end.timeIntervalSince(b.end)) <= mergeWindow
    }

    /// `b` folded into `a` (a survives).
    static func merged(_ a: Episode, _ b: Episode) -> Episode {
        var m = a
        m.start = min(a.start, b.start)
        m.end = max(a.end, b.end)
        m.mindBefore = a.start <= b.start ? a.mindBefore : b.mindBefore
        m.mindAfter = a.end >= b.end ? a.mindAfter : b.mindAfter
        m.topics = Array(EpisodeBuilder.union(a.topics, b.topics).prefix(3))
        let w = max(1e-9, a.salience + b.salience)
        m.valence = (a.valence * a.salience + b.valence * b.salience) / w
        m.salience = max(a.salience, b.salience)
        m.surprise = max(a.surprise, b.surprise)
        m.why = a.why ?? b.why
        m.expected = a.expected ?? b.expected
        m.changed = a.changed ?? b.changed
        m.recalled = a.recalled + b.recalled
        m.lastRecalled = [a.lastRecalled, b.lastRecalled].compactMap { $0 }.max()
        m.openLoop = a.openLoop ?? b.openLoop
        return m
    }

    /// Template reason for a crystallised taste from its strongest contributor.
    static func reason(for f: Facet, episodes: [Episode]) -> String {
        guard abs(f.learned) > abs(f.innate) else { return innateReason }
        let sign: Double = f.polarity >= 0 ? 1 : -1
        let best = episodes.filter { e in e.topics.contains { $0.overlaps(f.subject) } && e.valence * sign > 0 }
            .max { a, b in
                let x = abs(a.valence) * a.salience, y = abs(b.valence) * b.salience
                return x != y ? x < y : episodeOrder(b, a)
            }
        guard let e = best else { return innateReason }
        return EpisodeBuilder.phrase("since " + e.gist)
    }

    /// Whole days from `a` to `b` (`yyyy-MM-dd`).
    static func dayGap(_ a: String, _ b: String) -> Int {
        guard let x = dayNumber(a), let y = dayNumber(b) else { return 0 }
        return y - x
    }

    static func dayNumber(_ s: String) -> Int? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        // days_from_civil (Hinnant).
        let y = p[1] <= 2 ? p[0] - 1 : p[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = p[1] > 2 ? p[1] - 3 : p[1] + 9
        let doy = (153 * mp + 2) / 5 + p[2] - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Length of the run of consecutive days ending today or yesterday.
    static func streak(_ days: [String], endingNear today: String) -> Int {
        let nums = Array(Set(days.compactMap(dayNumber))).sorted()
        guard let t = dayNumber(today), let last = nums.last, t - last <= 1 else { return 0 }
        var run = 1
        var i = nums.count - 1
        while i > 0 && nums[i] - nums[i - 1] == 1 {
            run += 1
            i -= 1
        }
        return run
    }
}
