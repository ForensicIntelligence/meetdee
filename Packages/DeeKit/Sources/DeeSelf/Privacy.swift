import Foundation

// "Forget that", "forget me / that person", "forget everything", and DeeMemory person
// merges, applied to the in-RAM self (SELF.md §10.3). `Cortex.forget…` / `Cortex.merge`
// call these for every *shared* Moment field, then each sub-reducer's hook for its own
// private state. `SelfStore` mirrors the same rules in SQL (tests keep the two in step).

extension Subject {
    /// Whole-word containment either way, plural-tolerant: "interview" ~ "job interview",
    /// "painting" ~ "paintings", but not "view" ~ "interview".
    public func overlaps(_ other: Subject) -> Bool {
        let a = words, b = other.words
        return a.count <= b.count ? Self.contains(b, a) : Self.contains(a, b)
    }

    /// The subject's words appear contiguously, as whole words, in `text` (template
    /// output such as an episode gist).
    public func appears(in text: String) -> Bool {
        let w = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
        return Self.contains(w, words)
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a == b || a == b + "s" || b == a + "s" || a == b + "es" || b == a + "es"
    }

    /// `needle` occurs contiguously in `hay`.
    static func contains(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for i in 0...(hay.count - needle.count) where needle.indices.allSatisfy({ same(hay[i + $0], needle[$0]) }) {
            return true
        }
        return false
    }
}

extension Note {
    /// The note names `s` in one of its slots (rendered slot text).
    func mentions(_ s: Subject) -> Bool { slots.contains { s.appears(in: $0) } }
}

extension Enduring {
    /// What `SelfStore.forgetAll()` keeps: seed, values, humour, signature and the
    /// seeded facets reset to their seeded state.
    public func keepingSeeded() -> Enduring {
        var e = Enduring(seed: seed, values: values, humour: humour, humourSecondary: humourSecondary, signature: signature)
        e.facets = facets.filter { $0.source == .seed }.map { f in
            var g = f
            g.learned = 0
            g.polarity = f.innate
            g.evidence = 0
            g.contrary = 0
            g.revealedAt = nil
            g.reason = nil
            return g
        }
        return e
    }
}

extension Moment {
    /// "Forget that" for every shared field: intentions, expectations, interests,
    /// recent misreads, topic, referents and focus, note candidates naming it, episode
    /// keys tagged with it, gags about it, and learnt tastes about it (only the seeded
    /// facets stay; review finding 1). Boundaries stay (forgetting a subject must not
    /// lift "don't bring up X").
    public mutating func forget(subject s: Subject) {
        let goneIntentions = ongoing.intentions.filter { $0.subject.overlaps(s) }.map(\.id)
        let goneEpisodes = enduring.episodeIndex.filter { $0.topics.contains { $0.overlaps(s) } }.map(\.id)
        ongoing.intentions.removeAll { $0.subject.overlaps(s) }
        ongoing.expectations.removeAll { $0.subject.overlaps(s) }
        ongoing.interests.removeAll { $0.subject.overlaps(s) }
        ongoing.recentMisreads.removeAll { $0.topic?.overlaps(s) == true }
        if ongoing.misreadThisTurn?.topic?.overlaps(s) == true { ongoing.misreadThisTurn = nil }
        ongoing.topic.removeAll { $0.overlaps(s) }
        ongoing.noteCandidates.removeAll { n in
            n.mentions(s) || n.intention.map(goneIntentions.contains) == true || n.episode.map(goneEpisodes.contains) == true
        }
        momentary.referents.removeAll { $0.subject.overlaps(s) }
        switch momentary.focus {
        case .referent(let x, _) where x.overlaps(s), .sound(let x) where x.overlaps(s): momentary.focus = .none
        default: break
        }
        enduring.episodeIndex.removeAll { goneEpisodes.contains($0.id) }
        enduring.gags.removeAll { $0.topic.overlaps(s) }
        enduring.facets.removeAll { $0.source != .seed && $0.subject.overlaps(s) }
    }

    /// Drops episode keys the store deleted (e.g. matched by gist, which RAM never holds).
    public mutating func forget(episodes ids: [UUID]) {
        enduring.episodeIndex.removeAll { ids.contains($0.id) }
        ongoing.noteCandidates.removeAll { $0.episode.map(ids.contains) == true }
    }

    /// Everything learnt; keeps the seeded self and the live conversation's mechanics
    /// (floor, focus, mind). `seeded` defaults to `enduring.keepingSeeded()`.
    public mutating func forgetAll(keepingSeeded seeded: Enduring? = nil) {
        enduring = seeded ?? enduring.keepingSeeded()
        let keep = ongoing
        ongoing = Ongoing(mind: keep.mind, conversationStarted: keep.conversationStarted)
        ongoing.person = keep.person
        ongoing.turnsThisConversation = keep.turnsThisConversation
        ongoing.cutOff = keep.cutOff
        ongoing.promptPerson = keep.promptPerson
        ongoing.promptRendered = keep.promptRendered
        momentary.referents = []
        momentary.beatRequests = []
        momentary.signals = []
    }

    /// One person (DeeMemory `forgetPerson` / `discardPlaceholder`).
    public mutating func forget(person id: PersonID) {
        let goneIntentions = ongoing.intentions.filter { $0.person == id }.map(\.id)
        let goneEpisodes = enduring.episodeIndex.filter { $0.person == id }.map(\.id)
        if ongoing.person == id {
            ongoing.person = nil
            ongoing.hypotheses = []
            ongoing.misreadThisTurn = nil
            ongoing.repair = .fine
            ongoing.awkwardness = 0
        }
        if case .person(id) = momentary.focus { momentary.focus = .person(nil) }
        if ongoing.promptPerson == id { ongoing.promptPerson = nil }
        ongoing.intentions.removeAll { $0.person == id }
        ongoing.expectations.removeAll { $0.person == id }
        ongoing.recentMisreads.removeAll { $0.person == id }
        ongoing.noteCandidates.removeAll { n in
            n.intention.map(goneIntentions.contains) == true || n.episode.map(goneEpisodes.contains) == true
        }
        enduring.lessons.removeAll { $0.person == id }
        enduring.profiles[id] = nil
        enduring.boundaries.removeAll { $0.person == id }
        enduring.gags.removeAll { $0.person == id }
        enduring.rituals.removeAll { $0.person == id }
        enduring.episodeIndex.removeAll { $0.person == id }
    }

    /// DeeMemory folded `from` into `into` (placeholder → named person, or two records
    /// of one person). Same clash rules as `SelfStore.merge(from:into:)`:
    /// lesson (person, situation) → into's row, evidence summed, earliest created,
    /// latest applied; profile / open repair → into's; boundary (topic, owner) → into's,
    /// active if either was; ritual (trigger) → into's.
    public mutating func merge(from: PersonID, into: PersonID) {
        guard from != into else { return }
        if ongoing.person == from { ongoing.person = into }
        if case .person(from) = momentary.focus { momentary.focus = .person(into) }
        if ongoing.promptPerson == from { ongoing.promptPerson = into }
        for i in ongoing.intentions.indices where ongoing.intentions[i].person == from { ongoing.intentions[i].person = into }
        for i in ongoing.expectations.indices where ongoing.expectations[i].person == from { ongoing.expectations[i].person = into }
        for i in ongoing.recentMisreads.indices where ongoing.recentMisreads[i].person == from { ongoing.recentMisreads[i].person = into }
        if ongoing.misreadThisTurn?.person == from { ongoing.misreadThisTurn?.person = into }

        var lessons: [Lesson] = []
        for l in enduring.lessons where l.person != from { lessons.append(l) }
        for l in enduring.lessons where l.person == from {
            if let i = lessons.firstIndex(where: { $0.person == into && $0.situation == l.situation }) {
                lessons[i].evidence += l.evidence
                lessons[i].createdAt = min(lessons[i].createdAt, l.createdAt)
                lessons[i].lastApplied = [lessons[i].lastApplied, l.lastApplied].compactMap { $0 }.max()
            } else {
                var m = l
                m.person = into
                lessons.append(m)
            }
        }
        enduring.lessons = lessons

        if let p = enduring.profiles.removeValue(forKey: from), enduring.profiles[into] == nil { enduring.profiles[into] = p }

        var boundaries: [Boundary] = []
        for b in enduring.boundaries where b.person != from { boundaries.append(b) }
        for b in enduring.boundaries where b.person == from {
            if let i = boundaries.firstIndex(where: { $0.person == into && $0.topic == b.topic && $0.owner == b.owner }) {
                boundaries[i].active = boundaries[i].active || b.active
            } else {
                var c = b
                c.person = into
                boundaries.append(c)
            }
        }
        enduring.boundaries = boundaries

        var rituals: [Ritual] = []
        for r in enduring.rituals where r.person != from { rituals.append(r) }
        for r in enduring.rituals where r.person == from && !rituals.contains(where: { $0.person == into && $0.trigger == r.trigger }) {
            var c = r
            c.person = into
            rituals.append(c)
        }
        enduring.rituals = rituals

        for i in enduring.gags.indices where enduring.gags[i].person == from { enduring.gags[i].person = into }
        for i in enduring.episodeIndex.indices where enduring.episodeIndex[i].person == from { enduring.episodeIndex[i].person = into }
    }
}
