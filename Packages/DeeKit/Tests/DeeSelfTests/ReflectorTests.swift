import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Reflector (SELF.md §8.1, step 0.5.3). Owner: EpisodeBuilder.
@Suite struct ReflectorTests {
    static let day = 86_400.0
    static func s(_ t: String) -> Subject { Subject(t)! }
    static func at(_ days: Double) -> Date { Kit.t0.addingTimeInterval(days * day) }

    static func ep(_ topics: [String], person: PersonID? = Kit.john, end: Double = 0, salience: Double = 0.8, valence: Double = 0.5,
                   gist: String = "we talked about it", openLoop: UUID? = nil, id: UUID = UUID()) -> Episode {
        Episode(id: id, person: person, start: at(end).addingTimeInterval(-60), end: at(end), kind: .conversation,
                topics: topics.map(s), gist: gist, valence: valence, salience: salience, mindBefore: Kit.snap().code,
                mindAfter: Kit.snap().code, openLoop: openLoop)
    }

    static func taste(_ subject: String, innate: Double, learned: Double, evidence: Int, contrary: Int = 0, crystallised: Bool = false) -> Facet {
        Facet(id: UUID(), kind: .taste, subject: s(subject), innate: innate, learned: learned, evidence: evidence, contrary: contrary,
              crystallised: crystallised, source: .heuristic, updatedAt: Kit.t0)
    }

    static func input(_ episodes: [Episode] = [], edit: (inout Reflector.Input) -> Void = { _ in }) -> Reflector.Input {
        var i = Reflector.Input(enduring: Kit.enduring(), episodes: episodes, lastReflection: at(-1))
        edit(&i)
        return i
    }

    static func deleted(_ o: Reflector.Output) -> [UUID] {
        o.writes.compactMap { if case .deleteEpisode(let id) = $0 { id } else { nil } }
    }

    @Test func mergesNearDuplicates() {
        let a = Self.ep(["job interview", "nerves", "suit"], end: 0, salience: 0.9, gist: "they said they have a job interview tomorrow")
        let b = Self.ep(["interview", "nerves"], end: 0.5, salience: 0.5)
        let c = Self.ep(["interview", "nerves"], end: 3, salience: 0.6)            // > 24 h later
        let d = Self.ep(["interview", "nerves"], person: Kit.ann, end: 0.2)         // someone else
        let e = Self.ep(["interview", "cooking"], end: 0.1)                         // one shared topic
        let out = Reflector.reflect(Self.input([a, b, c, d, e]), at: Self.at(4))
        #expect(Self.deleted(out) == [b.id])
        #expect(out.report.merged == 1)
        let m = out.episodes.first { $0.id == a.id }!
        #expect(m.gist == a.gist && m.end == b.end && m.start == a.start && m.recalled == 0)
        #expect(m.topics.count == 3)
        #expect(out.episodes.count == 4)
    }

    @Test func salienceDecaysPerDayExceptLiveOpenLoops() {
        let loop = UUID()
        let it = Intention(id: loop, kind: .followUp, subject: Self.s("exam"), person: Kit.john, reason: "they were nervous about it",
                           notBefore: Self.at(1), expires: Self.at(30), priority: 0.8, source: "plan", created: Kit.t0)
        let open = Self.ep(["exam"], salience: 1, openLoop: loop)
        let plain = Self.ep(["guitar"], salience: 1)
        let out = Reflector.reflect(Self.input([open, plain]) { $0.intentions = [it] }, at: Self.at(0))
        #expect(out.episodes.first { $0.id == open.id }!.salience == 1)
        #expect(abs(out.episodes.first { $0.id == plain.id }!.salience - 0.9) < 1e-12, "one nominal day since the last pass")
        let quarter = Reflector.reflect(Self.input([plain]) { $0.lastReflection = Self.at(-0.25) }, at: Self.at(0))
        #expect(abs(quarter.episodes[0].salience - pow(0.9, 0.25)) < 1e-12, "running often does not age memories faster")
        let first = Reflector.reflect(Self.input([plain]) { $0.lastReflection = nil }, at: Self.at(0))
        #expect(abs(first.episodes[0].salience - 0.9) < 1e-12)
        #expect(first.writes == [.episode(first.episodes[0])])
    }

    @Test func tastesCrystalliseAndFlipWithHysteresis() {
        let painting = Self.ep(["painting"], valence: 0.8, gist: "they showed me a painting")
        let innate = Self.taste("rain sounds", innate: 0.8, learned: 0.1, evidence: 3)
        let learned = Self.taste("painting", innate: 0.1, learned: 0.8, evidence: 4)
        let thin = Self.taste("vacuum cleaners", innate: -0.9, learned: -0.2, evidence: 2)
        let weak = Self.taste("lamps", innate: 0.2, learned: 0.2, evidence: 5)
        let out = Reflector.reflect(Self.input([painting]) { $0.enduring.facets = [innate, learned, thin, weak] }, at: Self.at(0))
        let f = Dictionary(uniqueKeysWithValues: out.enduring.facets.map { ($0.subject.text, $0) })
        #expect(f["rain sounds"]!.crystallised && f["rain sounds"]!.reason == Reflector.innateReason)
        #expect(f["painting"]!.crystallised && f["painting"]!.reason == "since they showed me a painting")
        #expect(f["painting"]!.source == .reflection && f["painting"]!.updatedAt == Self.at(0))
        #expect(!f["vacuum cleaners"]!.crystallised, "evidence < 3")
        #expect(!f["lamps"]!.crystallised, "|polarity| < 0.35")
        #expect(out.report.crystallised == 2)
        #expect(out.writes.filter { if case .facet = $0 { true } else { false } }.count == 2)

        // Hysteresis: a crystallised taste holds below 0.35 until 3 contrary exposures.
        let holding = Self.taste("tea", innate: 0.4, learned: -0.2, evidence: 6, contrary: 2, crystallised: true)
        let flipping = Self.taste("coffee", innate: 0.1, learned: -0.9, evidence: 7, contrary: 3, crystallised: true)
        let o2 = Reflector.reflect(Self.input { $0.enduring.facets = [holding, flipping] }, at: Self.at(0))
        let g = Dictionary(uniqueKeysWithValues: o2.enduring.facets.map { ($0.subject.text, $0) })
        #expect(g["tea"]!.crystallised && g["tea"]!.contrary == 2)
        #expect(g["coffee"]!.crystallised && g["coffee"]!.contrary == 0 && g["coffee"]!.polarity < 0)
        #expect(o2.report.flipped == 1)
    }

    @Test func lessonsDecayAndRetire() {
        var e = Kit.enduring()
        let fresh = Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, evidence: 2, lastApplied: Self.at(-7), createdAt: Self.at(-30))
        let stale = Lesson(id: UUID(), person: Kit.john, situation: .tookLiterally, evidence: 2, createdAt: Self.at(-100))
        let strong = Lesson(id: UUID(), person: nil, situation: .askedTooMuch, evidence: 5, createdAt: Self.at(-100))
        e.lessons = [fresh, stale, strong]
        let out = Reflector.reflect(Reflector.Input(enduring: e), at: Kit.t0)
        #expect(out.writes == [.deleteLesson(stale.id)], "2 × 0.95^14.3 < 1")
        #expect(out.enduring.lessons.map(\.id) == [fresh.id, strong.id])
    }

    /// Review finding 22: one owner per concern. Skill steps are IntentionBoard's (the
    /// Reflector's row would be overwritten by Cortex's RAM copy anyway).
    @Test func skillIntentionsAreLeftToIntentionBoard() {
        let skill = Intention(id: UUID(), kind: .skill, subject: Self.s("telling jokes apart"), person: Kit.john, reason: "get better at it",
                              notBefore: Self.at(0), expires: Self.at(60), priority: 0.5, stepsNeeded: 5, source: "misread", created: Self.at(0))
        let digests = [1.0, 2, 3, 4, 5, 6].map { Reflector.Digest(day: EpisodeBuilder.day(Self.at($0)), person: Kit.john, conversations: 1, lowSalience: 0) }
        let out = Reflector.reflect(Self.input { $0.intentions = [skill]; $0.digests = digests }, at: Self.at(7))
        #expect(out.intentions == [skill])
        #expect(!out.writes.contains { if case .intention = $0 { true } else { false } })
        #expect(out.report.skillsAdvanced == 0 && out.report.skillsDone == 0)
    }

    @Test func silentExpiryAndGagRetirement() {
        let it = Intention(id: UUID(), kind: .ask, subject: Self.s("music"), person: Kit.john, reason: "curious about it",
                           notBefore: Kit.t0, expires: Self.at(1), priority: 0.5, source: "curiosity", created: Kit.t0)
        let x = Expectation(id: UUID(), person: Kit.john, subject: Self.s("trip"), due: Kit.t0, expires: Self.at(1), framing: .excited)
        let resolved = Expectation(id: UUID(), person: Kit.john, subject: Self.s("exam"), due: Kit.t0, expires: Self.at(1), framing: .nervous,
                                   status: .resolved)
        let worn = Gag(id: UUID(), person: Kit.john, topic: Self.s("toaster"), hookTemplate: 0, uses: 6)
        let flat = Gag(id: UUID(), person: Kit.john, topic: Self.s("socks"), hookTemplate: 1, uses: 2, flatStreak: 2)
        let alive = Gag(id: UUID(), person: Kit.john, topic: Self.s("cat"), hookTemplate: 1, uses: 2, laughs: 2)
        let out = Reflector.reflect(Self.input {
            $0.intentions = [it]
            $0.expectations = [x, resolved]
            $0.enduring.gags = [worn, flat, alive]
        }, at: Self.at(2))
        #expect(out.intentions[0].status == .dropped)
        #expect(out.expectations.map(\.status) == [.expired, .resolved])
        #expect(out.enduring.gags.map(\.retired) == [true, true, false])
        #expect(out.report.intentionsExpired == 1 && out.report.expectationsExpired == 1 && out.report.gagsRetired == 2)
    }

    /// Review finding 22: rituals are Learner's (local days, its own variant hash).
    @Test func ritualsAreLeftToLearner() {
        let days = [-2.0, -1, 0].map { EpisodeBuilder.day(Self.at($0)) }
        let old = Ritual(id: UUID(), person: Kit.ann, trigger: .goodnight, variant: 1, mannerism: .nod, count: 9, streak: 4, lastDone: Self.at(-3))
        let out = Reflector.reflect(Self.input {
            $0.enduring.rituals = [old]
            $0.ritualEvidence = [Reflector.RitualEvidence(person: Kit.john, trigger: .firstSightOfDay, days: days)]
        }, at: Self.at(0.5))
        #expect(out.enduring.rituals == [old])
        #expect(out.report.ritualsMinted == 0 && out.report.streaksReset == 0)
        #expect(!out.writes.contains { if case .ritual = $0 { true } else { false } })
    }

    @Test func prunesPerPersonAndTotalIntoTheDigest() {
        var eps: [Episode] = []
        for i in 0..<310 { eps.append(Self.ep(["topic \(i)"], person: Kit.john, end: -Double(i) / 10, salience: 0.5)) }
        for i in 0..<700 { eps.append(Self.ep(["thing \(i)"], person: Kit.ann, end: -Double(i) / 10, salience: 0.5)) }
        for i in 0..<100 { eps.append(Self.ep(["global \(i)"], person: nil, end: -Double(i) / 10, salience: 0.5)) }
        let out = Reflector.reflect(Self.input(eps) { $0.lastReflection = Kit.t0 }, at: Kit.t0)
        #expect(out.episodes.filter { $0.person == Kit.john }.count == 300)
        #expect(out.episodes.filter { $0.person == Kit.ann }.count == 300)
        #expect(out.episodes.count == 700)
        #expect(out.report.pruned == 410)
        let digests = out.writes.filter { if case .digest(_, _, 0, 1) = $0 { true } else { false } }
        #expect(digests.count == 410)
        // The oldest go first.
        #expect(!out.episodes.contains { $0.topics == [Self.s("topic 309")] })
        #expect(out.episodes.contains { $0.topics == [Self.s("topic 0")] })
        #expect(out.enduring.episodeIndex.count == Enduring.maxEpisodeIndex)
    }

    @Test func indexAndPreview() {
        let eps = [Self.ep(["apples"], end: -1, salience: 0.5), Self.ep(["birds"], end: 0, salience: 0.9), Self.ep(["cats"], end: -40, salience: 1)]
        let out = Reflector.reflect(Self.input(eps), at: Kit.t0)
        #expect(out.enduring.episodeIndex.map(\.topics) == [[Self.s("birds")], [Self.s("apples")], [Self.s("cats")]], "salience × recency")
        #expect(out.selfBlockPreview == SelfBlock.render(out.enduring, person: nil))
    }

    @Test func deterministicAndQuietWhenNothingIsDue() {
        let input = Self.input([Self.ep(["guitar"])]) { $0.ritualEvidence = [Reflector.RitualEvidence(person: nil, trigger: .goodnight,
                                                                                                         days: ["2026-09-19", "2026-09-20", "2026-09-21"])] }
        #expect(Reflector.reflect(input, at: Kit.t0) == Reflector.reflect(input, at: Kit.t0))
        let quiet = Reflector.reflect(Self.input { $0.lastReflection = Kit.t0 }, at: Kit.t0)
        #expect(quiet.writes.isEmpty && quiet.report == Reflector.Report())
    }

    @Test func storeRoundTrip() async throws {
        let store = try SelfStore(url: nil)
        let enduring = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        let a = Self.ep(["job interview", "nerves"], end: 0, salience: 0.9)
        let b = Self.ep(["interview", "nerves"], end: 0.2, salience: 0.4)
        let g = Self.ep(["rain"], person: nil, end: 0)
        let x = Expectation(id: UUID(), person: Kit.john, subject: Self.s("trip"), due: Kit.t0, expires: Self.at(1), framing: .excited)
        try await store.apply([.episode(a), .episode(b), .episode(g), .expectation(x)])
        let input = try await Reflector.load(from: store, enduring: enduring, people: [Kit.john], at: Self.at(2))
        #expect(input.episodes.count == 3 && input.lastReflection == nil)
        let out = Reflector.reflect(input, at: Self.at(2))
        let r = try await Reflector.commit(out, to: store, at: Self.at(2))
        #expect(r.failed.isEmpty)
        #expect(try await store.episode(b.id) == nil)
        #expect(try await store.episode(a.id)?.salience == 0.9 * 0.9)
        #expect(try await store.expectations().first?.status == .expired)
        let again = try await Reflector.load(from: store, enduring: out.enduring, people: [Kit.john], at: Self.at(2))
        #expect(again.lastReflection == Self.at(2))
        #expect(Set(out.enduring.episodeIndex.map(\.id)) == Set(try await store.episodeIndex().map(\.id)))
    }
}
