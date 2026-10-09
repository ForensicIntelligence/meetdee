import DeeCore
import DeeMemory
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// docs/DNA.md §5.5 — builders for the eight archetypal Dee DNA states, plus the
/// max-length fixture of §5.3. All times are fixed (Friday 9 October 2026, UTC−4).
enum DNAKit {
    static let maya = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
    static let stranger = UUID(uuidString: "00000000-0000-4000-8000-0000000000BB")!
    /// Friday 9 October 2026 00:00 UTC.
    static let day = SimClock.epoch.addingTimeInterval(18 * 86_400)
    /// UTC−4 (Eastern daylight time).
    static let offset: TimeInterval = -4 * 3600
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    /// Local wall-clock time on 9 October 2026.
    static func local(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
        day.addingTimeInterval(Double(dayOffset * 86_400 + h * 3600 + m * 60) - offset)
    }

    /// Baselines of the default personality (age-adjusted) with overrides.
    static func feelings(age: Double? = nil, _ over: [Feeling: Double]) -> Feelings {
        var f = EmotionEngine.baselines(personality: Personality(), age: age)
        for (k, v) in over { f[k] = v }
        return f
    }

    static func snapshot(_ over: [Feeling: Double], age: Double? = nil, traits: [DeeMind.Trait: Double] = [:], reflex: Emotion? = nil,
                         reflexAt: Date? = nil) -> MindSnapshot {
        MindSnapshot(code: MindCode(personality: Personality(traits), feelings: feelings(age: age, over)), age: age, sequence: 1,
                     reflex: reflex, reflexAt: reflexAt)
    }

    static func subject(_ s: String) -> Subject { Subject(s)! }

    /// Seeded self plus a learnt history with Maya.
    static func enduring(humour: HumourStyle? = nil) -> Enduring {
        var e = SelfSeeder.seed(personality: Personality(), seed: 7, at: SimClock.epoch)
        if let humour { e.humour = humour }
        e.facets.append(Facet(id: id(1), kind: .taste, subject: subject("rain sounds"), innate: 0.7, learned: 0.8, evidence: 4,
                              crystallised: true, revealedAt: SimClock.epoch.addingTimeInterval(86_400), source: .heuristic,
                              updatedAt: SimClock.epoch))
        e.facets.append(Facet(id: id(2), kind: .taste, subject: subject("vacuum cleaners"), innate: -0.7, learned: -0.7, evidence: 3,
                              crystallised: true, revealedAt: SimClock.epoch.addingTimeInterval(2 * 86_400), source: .heuristic,
                              updatedAt: SimClock.epoch))
        // Unrevealed: must never appear.
        e.facets.append(Facet(id: id(3), kind: .taste, subject: subject("jazz piano"), innate: 0.8, learned: 0.8, evidence: 5,
                              crystallised: true, revealedAt: nil, source: .heuristic, updatedAt: SimClock.epoch))
        e.lessons.append(Lesson(id: id(4), person: maya, situation: .tookLiterally, evidence: 3, createdAt: SimClock.epoch))
        e.lessons.append(Lesson(id: id(5), person: nil, situation: .interruptedThem, evidence: 2, createdAt: SimClock.epoch))
        var prof = SocialProfile()
        prof.humorReceptiveness = 0.75
        prof.silenceComfort = 0.65
        e.profiles[maya] = prof
        e.rituals.append(Ritual(id: id(6), person: maya, trigger: .firstSightOfDay, variant: 1, mannerism: .bounce, count: 12, streak: 4))
        e.rituals.append(Ritual(id: id(7), person: maya, trigger: .returnHome, variant: 0, mannerism: .nod, count: 3, streak: 1))
        e.gags.append(Gag(id: id(8), person: maya, topic: subject("toaster"), hookTemplate: 0, uses: 3, laughs: 2,
                          lastUsed: SimClock.epoch))
        e.boundaries.append(Boundary(id: id(9), person: maya, topic: subject("her ex"), owner: .user, createdAt: SimClock.epoch))
        e.episodeIndex.append(EpisodeKey(id: id(10), person: maya, end: SimClock.epoch.addingTimeInterval(10 * 86_400),
                                         topics: [subject("bread")], salience: 0.8, recalled: 0))
        return e
    }

    static let mayaFacts: [DNAFact] = [
        DNAFact(text: "Maya has a dog named Miso", category: .pet),
        DNAFact(text: "Maya works as a nurse", category: .work),
        DNAFact(text: "Maya's favourite colour is green", category: .preference),
        DNAFact(text: "Maya likes baking sourdough bread", category: .preference),
        DNAFact(text: "Maya has a sister called Ana", category: .relationship),
        DNAFact(text: "Maya lives in Halifax", category: .place),
    ]

    static func mayaInputs(facts: [DNAFact] = mayaFacts) -> PersonInputs {
        PersonInputs(id: maya, name: "Maya", aliases: ["May"], facts: facts, firstMet: local(10, 0, dayOffset: -70), encounters: 23,
                     lastSeen: local(21, 0, dayOffset: -1))
    }

    static let mayaEpisodes = [
        EpisodeLine(id: id(10), gist: "you watched her bread rise and she named the loaf after you", daysAgo: 8, valence: 1),
        EpisodeLine(id: id(11), gist: "she showed you her new running shoes", daysAgo: 3, valence: 1),
    ]

    static let steadyDays: [DNADay] = (1...14).map { i in
        DNADay(day: dayString(-i), interactions: 10, regard: i <= 7 ? 0.45 : 0.32)
    }

    static func dayString(_ offsetDays: Int) -> String {
        let t = LocalTime(local(12, 0, dayOffset: offsetDays), utcOffset: offset)
        return String(format: "%04d-%02d-%02d", t.year, t.month, t.day)
    }

    static func moment(_ mind: MindSnapshot, at now: Date, enduring: Enduring = enduring(), person: PersonID? = maya,
                       started: Date? = nil) -> Moment {
        var m = Moment(ongoing: Ongoing(mind: mind, conversationStarted: started ?? now.addingTimeInterval(-240)), enduring: enduring, now: now)
        m.ongoing.person = person
        return m
    }

    static func stance(_ m: Moment, expression: Emotion? = nil, notes: [Note] = []) -> Stance {
        var r = Rand(seed: 3)
        var s = Stance.resolve(m, &r)
        if let expression { s.expression = expression }
        s.notes = notes
        return s
    }

    struct Archetype {
        var name: String
        var inputs: DNAInputs
        /// Expected Do/Avoid rule ids (§5.5).
        var rules: [Guidance.Rule]
        /// Expected leading voice-delivery words.
        var voice: String
    }

    // MARK: The eight archetypes

    static func fondMorning() -> Archetype {
        let now = local(8, 20)
        let mind = snapshot([.joy: 0.78, .interest: 0.8, .affection: 0.68, .trust: 0.66, .gratitude: 0.25])
        var m = moment(mind, at: now)
        m.ongoing.turnsThisConversation = 2
        m.ongoing.interests = [Interest(subject: subject("sourdough"), weight: 0.6, lastTouched: now)]
        m.ongoing.expectations = [Expectation(id: id(20), person: maya, subject: subject("football match"),
                                              due: now.addingTimeInterval(2 * 86_400 + 3600), expires: now.addingTimeInterval(9 * 86_400),
                                              framing: .excited)]
        m.momentary.mutualGazeSince = now.addingTimeInterval(-6)
        let st = stance(m, expression: .happy, notes: [.recall(gist: "you watched her bread rise", episode: id(10))])
        var inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 3, mode: .fast), mind: mind,
                               inner: InnerStateCounters(interactions: 410, kindInteractions: 160, hostileInteractions: 2),
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, lastUserTurnAt: now.addingTimeInterval(-20)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: 0.05, pace: 0.1, pitchVariability: 2.6, intensity: 0.1),
                                                        durationS: 2.1),
                               daily: steadyDays)
        inputs.moodHistory = [DNAHistorySample(at: now.addingTimeInterval(-720), code: snapshot([.joy: 0.6, .interest: 0.62, .affection: 0.68, .trust: 0.66]).code)]
        inputs.causes = [CauseEntry(at: now.addingTimeInterval(-90), label: .kindWords,
                                    deltas: [.joy: 30, .interest: 20, .gratitude: 40])]
        inputs.stance.playGate = true
        return Archetype(name: "fond-morning", inputs: inputs, rules: [.g8, .g14, .g15, .g16], voice: "bright and smiling")
    }

    static func insultedRuptured() -> Archetype {
        let now = local(18, 5)
        let mind = snapshot([.anger: 0.55, .resentment: 0.4, .affection: 0.6, .trust: 0.6, .joy: 0.2, .sadness: 0.3, .surprise: 0.4],
                            reflex: .hurt, reflexAt: now.addingTimeInterval(-1.5))
        var m = moment(mind, at: now)
        m.ongoing.repair = .ruptured
        m.ongoing.turnsThisConversation = 6
        m.ongoing.awkwardness = 0.6
        let st = stance(m, notes: [.deeBoundary()])
        var a = Appraisal()
        a.hostility = 0.7; a.valence = -0.6; a.intensity = 0.8; a.loudness = 0.8; a.dominance = 0.7
        var inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 7, mode: .exact), mind: mind,
                               inner: InnerStateCounters(interactions: 412, kindInteractions: 160, hostileInteractions: 5, hostileRecent: 1.2),
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, lastUserTurnAt: now.addingTimeInterval(-15)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: 0.85, pace: 0.3, pitchVariability: 4.5, intensity: 0.8, dominance: 0.45),
                                                        text: a, durationS: 1.4),
                               daily: steadyDays)
        inputs.moodHistory = [DNAHistorySample(at: now.addingTimeInterval(-700), code: snapshot([.affection: 0.62, .trust: 0.62]).code)]
        inputs.causes = [CauseEntry(at: now.addingTimeInterval(-2), label: .shoutedAt, deltas: [.anger: 110, .resentment: 60, .joy: -90, .sadness: 40]),
                         CauseEntry(at: now.addingTimeInterval(-60), label: .rudeness, deltas: [.anger: 40, .surprise: 60])]
        inputs.stance.playGate = false
        return Archetype(name: "insulted-ruptured", inputs: inputs, rules: [.g1, .g12, .g15, .g16], voice: "quiet, wounded, steady")
    }

    static func apologyRepairing() -> Archetype {
        let now = local(18, 12)
        let mind = snapshot([.anger: 0.2, .resentment: 0.25, .affection: 0.6, .trust: 0.58, .joy: 0.35, .sadness: 0.2, .gratitude: 0.2],
                            reflex: .relieved, reflexAt: now.addingTimeInterval(-1))
        var m = moment(mind, at: now)
        m.ongoing.repair = .repairing
        m.ongoing.turnsThisConversation = 9
        let st = stance(m, notes: [.reconciled()])
        var a = Appraisal()
        a.apology = 0.75; a.warmth = 0.4; a.valence = 0.4; a.loudness = -0.45
        var inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 10, mode: .exact), mind: mind,
                               inner: InnerStateCounters(interactions: 415, kindInteractions: 161, hostileInteractions: 5, apologyFatigue: 0.3),
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, lastUserTurnAt: now.addingTimeInterval(-10)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: -0.45, pace: -0.1, pitchVariability: 2.0, dominance: -0.18),
                                                        text: a, durationS: 2.5),
                               daily: steadyDays)
        inputs.moodHistory = [DNAHistorySample(at: now.addingTimeInterval(-620),
                                               code: snapshot([.anger: 0.55, .resentment: 0.4, .affection: 0.6, .trust: 0.6, .joy: 0.2]).code)]
        inputs.causes = [CauseEntry(at: now.addingTimeInterval(-1), label: .apology, deltas: [.anger: -60, .resentment: -30, .sadness: -20])]
        return Archetype(name: "apology-repairing", inputs: inputs, rules: [.g2, .g12, .g15, .g16], voice: "exhaling, softening, warm")
    }

    static func userSad() -> Archetype {
        let now = local(20, 30)
        let mind = snapshot([.sadness: 0.3, .interest: 0.7, .affection: 0.66, .trust: 0.64, .joy: 0.4])
        var m = moment(mind, at: now)
        m.ongoing.turnsThisConversation = 3
        m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 1, stated: true, expires: now.addingTimeInterval(1800))]
        m.ongoing.turnDistress = Timed(0.6, until: now.addingTimeInterval(600))
        let st = stance(m, expression: .worried, notes: [.followUp(subject("exam"), framing: .nervous, gentle: true)])
        var a = Appraisal()
        a.distress = 0.6; a.valence = -0.4; a.loudness = -0.4
        let inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 4, mode: .exact), mind: mind,
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, lastUserTurnAt: now.addingTimeInterval(-25)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: -0.4, pace: -0.35, pitchVariability: 1.1, dominance: -0.16),
                                                        text: a, durationS: 3.2),
                               daily: steadyDays)
        return Archetype(name: "user-sad", inputs: inputs, rules: [.g3, .g15, .g16], voice: "careful, soft, a bit fast")
    }

    static func reunion9Days() -> Archetype {
        let now = local(17, 40)
        let mind = snapshot([.loneliness: 0.7, .joy: 0.62, .affection: 0.64, .trust: 0.62, .surprise: 0.3, .energy: 0.85])
        var m = moment(mind, at: now, started: now.addingTimeInterval(-20))
        m.ongoing.reunionTurn = true
        m.momentary.mutualGazeSince = now.addingTimeInterval(-3)
        let st = stance(m, expression: .excited, notes: [.reunion()])
        var person = mayaInputs()
        person.lastSeen = now.addingTimeInterval(-9 * 86_400 - 3600)
        let inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 1, mode: .fast), mind: mind,
                               moment: m, stance: st, episodes: mayaEpisodes, person: person,
                               body: BodyInputs(someoneHere: true, lastContact: now.addingTimeInterval(-9 * 86_400 - 3600)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: 0.2, pace: 0.1, pitchVariability: 3.2, intensity: 0.2),
                                                        durationS: 1.2))
        return Archetype(name: "reunion-9-days", inputs: inputs, rules: [.g5, .g8, .g14, .g15, .g16], voice: "fast, bouncy, high")
    }

    static func exhaustedLateNight() -> Archetype {
        let now = local(1, 40)
        let mind = snapshot([.energy: 0.15, .affection: 0.62, .trust: 0.6, .joy: 0.4, .interest: 0.4])
        var m = moment(mind, at: now)
        m.ongoing.turnsThisConversation = 1
        let st = stance(m, expression: .sleepy)
        let inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 2, mode: .fast), mind: mind,
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, wokeAt: now.addingTimeInterval(-30), lastUserTurnAt: now.addingTimeInterval(-8)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: -0.5, pace: -0.3, pitchVariability: 1.4, dominance: -0.2),
                                                        durationS: 1.0))
        return Archetype(name: "exhausted-late-night", inputs: inputs, rules: [.g9, .g14, .g15, .g16], voice: "drowsy, slow, soft")
    }

    static func giddyPlay() -> Archetype {
        let now = local(15, 10)
        let mind = snapshot([.joy: 0.85, .interest: 0.75, .affection: 0.7, .trust: 0.66, .surprise: 0.35, .energy: 0.8],
                            reflex: .giddy, reflexAt: now.addingTimeInterval(-1))
        var m = moment(mind, at: now, enduring: enduring(humour: .deadpan))
        m.ongoing.turnsThisConversation = 11
        let gag = Note.gagCallback(subject("toaster"), style: .deadpan, hook: "the toaster that judges you", gag: id(8))
        let st = stance(m, expression: .giddy, notes: [gag, .tasteReveal(subject("rain sounds"), loves: true, facet: id(1))])
        var inputs = DNAInputs(now: now, utcOffset: offset, turn: TurnContext(kind: .reply, index: 12, mode: .fast), mind: mind,
                               moment: m, stance: st, episodes: mayaEpisodes, person: mayaInputs(),
                               body: BodyInputs(someoneHere: true, touch: TouchInput(kind: "pet", gentle: true, at: now.addingTimeInterval(-6)),
                                                lastUserTurnAt: now.addingTimeInterval(-5)),
                               appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: 0.35, pace: 0.4, pitchVariability: 5.0, intensity: 0.4, dominance: 0.17),
                                                        durationS: 1.8),
                               daily: steadyDays)
        inputs.causes = [CauseEntry(at: now.addingTimeInterval(-1), label: .joke, deltas: [.joy: 45, .surprise: 50, .anger: 0])]
        inputs.stance.playGate = true
        return Archetype(name: "giddy-play", inputs: inputs, rules: [.g8, .g12, .g14, .g15, .g16], voice: "giggly, breathless, fast")
    }

    static func childStrangerInitiative() -> Archetype {
        let now = local(10, 15)
        let age = 6.0
        let mind = snapshot([.interest: 0.85, .joy: 0.6, .surprise: 0.45], age: age)
        var m = moment(mind, at: now, person: stranger, started: now.addingTimeInterval(-60))
        m.ongoing.turnsThisConversation = 0
        m.momentary.referents = [Referent(subject: subject("red ball"), camera: .back, sources: [.sawBack, .heldUp], salience: 0.9,
                                          lastSeen: now, sharedWithUser: true)]
        let st = stance(m, expression: .curious)
        let inputs = DNAInputs(now: now, utcOffset: offset,
                               turn: TurnContext(kind: .initiative, index: 1, initiative: "Ask one short question about the red ball you just noticed.",
                                                 mode: .fast),
                               mind: mind, aging: AgingInputs(enabled: true, yearsPerDay: 0.1), moment: m, stance: st,
                               person: PersonInputs(id: stranger, name: nil, isPlaceholder: true),
                               body: BodyInputs(someoneHere: true))
        return Archetype(name: "child-stranger-initiative", inputs: inputs, rules: [.g4, .g8, .g13, .g16], voice: "interested, rising questions")
    }

    static var all: [Archetype] {
        [fondMorning(), insultedRuptured(), apologyRepairing(), userSad(), reunion9Days(), exhaustedLateNight(), giddyPlay(),
         childStrangerInitiative()]
    }

    // MARK: §5.3 Max-length fixture

    static func maxLength() -> DNAInputs {
        let now = local(19, 0)
        let mind = snapshot([.joy: 0.1, .sadness: 0.7, .anger: 0.6, .fear: 0.5, .surprise: 0.8, .interest: 0.9, .boredom: 0.6,
                             .affection: 0.9, .trust: 0.2, .loneliness: 0.8, .energy: 0.3, .gratitude: 0.7, .resentment: 0.6],
                            age: 15, traits: [.playfulness: 0.1, .patience: 0.95, .confidence: 0.05],
                            reflex: .overwhelmed, reflexAt: now.addingTimeInterval(-1))
        func long(_ n: Int, _ tag: String) -> String { String((tag + " " + String(repeating: "word ", count: 40)).prefix(n)) }
        var e = enduring()
        for i in 0..<5 {
            e.boundaries.append(Boundary(id: id(100 + i), person: maya, topic: subject("boundary topic xx \(i)"), owner: .user,
                                         createdAt: now.addingTimeInterval(Double(-i))))
        }
        e.boundaries.append(Boundary(id: id(110), person: maya, topic: subject("rudeness"), owner: .dee, createdAt: now.addingTimeInterval(-60)))
        for i in 0..<3 {
            e.facets.append(Facet(id: id(120 + i), kind: .taste, subject: subject("longest taste subject \(i)"), innate: 0.9, learned: 0.9,
                                  evidence: 9, crystallised: true, revealedAt: now, source: .heuristic, updatedAt: now))
        }
        for i in 0..<3 {
            e.gags.append(Gag(id: id(130 + i), person: maya, topic: subject("gag topic \(i)"), hookTemplate: i, uses: 2, laughs: 3))
        }
        e.rituals.append(Ritual(id: id(140), person: maya, trigger: .goodnight, variant: 0, mannerism: .yawn, count: 5))
        e.lessons.append(Lesson(id: id(141), person: nil, situation: .askedTooMuch, evidence: 5, createdAt: now))
        var prof = SocialProfile()
        prof.humorReceptiveness = 0.2
        prof.silenceComfort = 0.9
        prof.kindnessEMA = -0.5
        e.profiles[maya] = prof
        var m = moment(mind, at: now, enduring: e, started: now.addingTimeInterval(-3600))
        m.ongoing.repair = .ruptured
        m.ongoing.cutOff = true
        m.ongoing.reunionTurn = true
        m.ongoing.turnsThisConversation = 99
        m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 1, stated: true, expires: now.addingTimeInterval(600)),
                                Hypothesis(kind: .goal, value: "shareCreation", confidence: 1, stated: true, expires: now.addingTimeInterval(600))]
        m.ongoing.turnDistress = Timed(0.8, until: now.addingTimeInterval(600))
        m.ongoing.interests = (0..<5).map { Interest(subject: subject("interest subject long \($0)"), weight: 0.9, lastTouched: now) }
        m.ongoing.expectations = (0..<4).map {
            Expectation(id: id(150 + $0), person: maya, subject: subject("expectation subject x\($0)"), due: now.addingTimeInterval(-86_400 * Double($0 + 1)),
                        expires: now.addingTimeInterval(86_400 * 6), framing: .nervous)
        } + (0..<3).map {
            Expectation(id: id(160 + $0), person: maya, subject: subject("upcoming subject long \($0)"), due: now.addingTimeInterval(86_400 * Double($0 + 2)),
                        expires: now.addingTimeInterval(86_400 * 9), framing: .excited)
        }
        m.ongoing.intentions = (0..<4).map {
            Intention(id: id(170 + $0), kind: .learn, subject: subject("intention subject long \($0)"), person: maya, reason: "they were nervous about it",
                      notBefore: now.addingTimeInterval(-60), expires: now.addingTimeInterval(86_400), priority: 0.9, source: "curiosity", created: now)
        }
        m.momentary.referents = (0..<4).map {
            Referent(subject: subject("seen referent long \($0)"), camera: .back, sources: [.heldUp], salience: 0.9, lastSeen: now)
        }
        m.momentary.mutualGazeSince = now
        let aim = Note(.misread, slots: NoteTemplates.slotCaps(.misread).map { String(repeating: "x", count: $0) })
        let ctx = Note(.lesson, slots: [String(repeating: "y", count: NoteTemplates.slotCaps(.lesson)[0])])
        let st = stance(m, expression: .overwhelmed, notes: [aim, ctx])
        var a = Appraisal()
        a.hostility = 0.5; a.apology = 0.5; a.distress = 0.5; a.interestInDee = 0.5; a.sarcasm = 0.4
        let facts = (0..<8).map { DNAFact(text: "Maya " + long(100, "fact\($0)"), category: .work) }
        let episodes = (0..<3).map { EpisodeLine(id: id(180 + $0), gist: long(100, "gist\($0)"), daysAgo: 5 + $0, valence: 1) }
        var stance2 = st
        stance2.playGate = true
        return DNAInputs(now: now, utcOffset: offset,
                         turn: TurnContext(kind: .reply, index: 99, mode: .exact), mind: mind, aging: AgingInputs(enabled: true, yearsPerDay: 0.05),
                         inner: InnerStateCounters(interactions: 9999, kindInteractions: 4000, hostileInteractions: 999, apologyFatigue: 0.9),
                         causes: Feeling.allCases.enumerated().map { i, f in
                             CauseEntry(at: now.addingTimeInterval(Double(-i * 10)), label: CauseLabel.allCases[i], deltas: [f: 120])
                         },
                         moment: m, stance: stance2, episodes: episodes, person: mayaInputs(facts: facts),
                         body: BodyInputs(someoneHere: true, wokeAt: now.addingTimeInterval(-20),
                                          touch: TouchInput(kind: "pet", gentle: true, at: now.addingTimeInterval(-3))),
                         appraisal: TurnAppraisal(prosody: ProsodyRead(loudness: 0.9, pace: 0.9, pitchVariability: 6, intensity: 1, dominance: 0.5),
                                                  text: a, durationS: 9),
                         daily: steadyDays)
    }
}
