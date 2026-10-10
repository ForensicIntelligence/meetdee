import DeeCore
import DeeMemory
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// docs/DNA.md §5.4 — privacy: the 5-gram rule, telegraphic facts, exclusions.
@Suite struct DNAPrivacyTests {
    /// An independent oracle: joined-string 5-grams over the guard's tokeniser (the guard
    /// itself hashes them).
    static func fiveGrams(_ s: String) -> Set<String> {
        let t = DNAPrompt.Guard.tokens(s)
        guard t.count >= 5 else { return [] }
        return Set((0...(t.count - 5)).map { t[$0..<($0 + 5)].joined(separator: " ") })
    }

    static func leaks(_ render: String, _ corpus: [String]) -> [String] {
        let r = fiveGrams(render)
        return corpus.flatMap { fiveGrams($0).intersection(r) }.sorted()
    }

    /// The render with every stored item replaced by a sentinel: what is left is fixed
    /// vocabulary, names and boundary subjects, which the user may echo (review finding 1).
    static func skeleton(_ dna: DeeDNA, steps: [DegradeStep]) -> String {
        var o = DNAPrompt.Options()
        for s in steps { o.apply(s) }
        let lines = DNAPrompt.compose(dna, o).map { l -> DNAPrompt.Line in
            var l = l
            if l.stored { l.items = l.items.map { _ in "qqsentinelqq" } }
            return l
        }
        return DNAPrompt.join(lines)
    }

    /// Leaks that touch stored content (the only kind the rule forbids).
    static func contentLeaks(_ r: DNARender, _ dna: DeeDNA, _ corpus: [String]) -> [String] {
        let fixed = fiveGrams(skeleton(dna, steps: r.steps))
        return leaks(r.text, corpus).filter { !fixed.contains($0) }
    }

    /// Lines that must survive any user speech: identity, repair, section 9.
    static func checkFixedLinesSurvive(_ text: String, _ tag: String, boundary: String? = nil) {
        let lines = text.split(separator: "\n").map(String.init)
        for prefix in ["You are Dee, a tiny robot", "Repair: ", "Length: ", "Voice: ", "Avoid: ", "Always: ", "DNA TRACE"] {
            #expect(lines.contains { $0.hasPrefix(prefix) }, "\(tag): lost \(prefix)")
        }
        if let boundary { #expect(lines.contains { $0.hasPrefix("Don't bring up: ") && $0.contains(boundary) }, "\(tag): lost the boundary") }
    }

    // MARK: Property: 2 000 sessions, no 5-gram of any transcript in any render

    static let pets = ["Miso", "Biscuit", "Pepper", "Rex", "Luna", "Noodle"]
    static let jobs = ["nurse", "teacher", "plumber", "designer", "baker", "pilot"]
    static let places = ["Halifax", "Toronto", "Leeds", "Austin", "Lyon", "Perth"]
    static let topics = ["job interview", "work", "my ex", "money", "the move", "school"]
    static let things = ["sunset", "football match", "bread", "film", "storm", "garden"]
    static let vocab = ["apple", "river", "quickly", "blue", "seven", "talk", "window", "happy", "under", "garden", "music", "maybe", "train",
                        "paper", "loud", "small", "tomorrow", "cloud", "coffee", "remember", "the", "a", "and", "you", "I", "is"]

    static func session(_ rng: inout Rand) -> [String] {
        func pick(_ a: [String]) -> String { a[rng.index(a.count)] }
        var out = [
            "I have a dog called \(pick(pets)) and he is very silly",
            "I work as a \(pick(jobs)) at the hospital in \(pick(places))",
            "my favourite colour is green and I really love baking bread on Sunday mornings",
            "I have a job interview on Saturday and I am really nervous about it",
            "I don't want to talk about \(pick(topics)) on Saturday please",
            "we watched the \(pick(things)) together and it was really really fun",
            "my sister Ana lives in \(pick(places)) with her two cats",
            // Hyphenated words (review finding 6) and Dee's own fixed vocabulary (findings 1–2).
            "I have a 3-year-old golden retriever named \(pick(pets)) and a sister-in-law in \(pick(places))",
            "she works part-time as a dog-walker in north-east \(pick(places))",
            "I never want to make them feel guilty for being away",
            "why do you keep asking more than one question",
            "please don't bring up her ex again",
            "you are a tiny robot who lives in this phone",
        ]
        out.shuffleSeeded(&rng)
        out = Array(out.prefix(3 + rng.index(4)))
        out.append((0..<(6 + rng.index(10))).map { _ in pick(vocab) }.joined(separator: " "))
        return out
    }

    @Test func noFiveGramOfAnyTranscriptInAnyRender() async throws {
        var rng = Rand(seed: 5_000)
        let utc = Calendar(identifier: .gregorian)
        var cal = utc
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = try MemoryStore(databaseURL: nil, faceMatching: FaceMatching(), calendar: cal)
        let base = DNAKit.fondMorning()
        var factLineDrops = 0
        var guardDrops = 0
        for i in 0..<2_000 {
            let corpus = Self.session(&rng)
            let now = base.inputs.now
            guard let person = await store.addPerson(named: "Person\(i)", at: now) else { Issue.record("addPerson"); continue }
            for u in corpus { await store.learn(from: u, about: person.id, at: now) }
            let p = try #require(await store.person(person.id))
            var inputs = base.inputs
            let lines = await store.promptMemories(for: p.id, limit: 9, now: now)
            inputs.person = PersonInputs(person: p, promptMemories: lines)
            inputs.moment.ongoing.person = p.id
            inputs.userTextCorpus = corpus
            // Adversarial: a gist and an aim note that echo the user (a template bug); the guard must catch them.
            if i % 3 == 0 {
                inputs.episodes = [EpisodeLine(id: DNAKit.id(900), gist: corpus[0], daysAgo: 2, valence: 1)]
                inputs.stance.notes = [Note(.intention, slots: [String(corpus[corpus.count - 1].prefix(88))])]
            }
            let r = DNAPrompt.build(inputs)
            let leaked = Self.contentLeaks(r, DNAAssembler.assemble(inputs), corpus)
            #expect(leaked.isEmpty, "session \(i): \(leaked)")
            Self.checkFixedLinesSurvive(r.text, "session \(i)")
            guardDrops += r.dropped.count
            let fd = r.dropped.filter { $0.lineKind == "facts" }.count
            if fd > 0 && factLineDrops == 0 {
                Issue.record("first fact echo, session \(i): corpus \(corpus) facts \(inputs.person?.facts.map(\.text) ?? [])")
            }
            factLineDrops += fd
            if !leaked.isEmpty { break }
        }
        // The adversarial lines were caught; real facts (telegraphic) never needed the guard.
        #expect(guardDrops > 0)
        #expect(factLineDrops == 0, "telegraphic facts echoed a transcript \(factLineDrops) times")
    }

    // MARK: Guard unit tests

    @Test func guardDropsOnlyTheEchoingFactAndRecordsItsKind() {
        var inputs = DNAKit.fondMorning().inputs
        // A fact whose telegraphic form still shares 5 words with this session's transcript.
        inputs.person?.facts.insert(DNAFact(text: "Maya has a red kite and a blue boat with a green sail", category: .other), at: 0)
        inputs.userTextCorpus = ["she drew a red kite blue boat green sail picture for me"]
        let clean = DNAPrompt.render(DNAAssembler.assemble(DNAKit.fondMorning().inputs))
        let r = DNAPrompt.build(inputs)
        #expect(r.dropped == [GuardDrop(section: 5, lineKind: "facts")])
        #expect(Self.leaks(r.text, inputs.userTextCorpus).isEmpty)
        #expect(r.fixedEchoes == 0)
        // Only that fact went: the other facts are all still there.
        for f in DNAKit.mayaFacts.prefix(4) {
            let t = DNAAssembler.telegraphic(f.text, names: ["Maya", "May"], category: f.category)
            #expect(r.text.contains(t) && clean.text.contains(t), "\(t)")
        }
    }

    @Test func telegraphicFactsNeverKeepFiveWordsTogether() {
        let t = DNAAssembler.telegraphic("Maya gardens loud and quickly loud blue remember cloud", names: ["Maya"])
        #expect(t == "gardens loud quickly loud blue remember")
        #expect(DNAPrivacyTests.fiveGrams(t).isDisjoint(with: DNAPrivacyTests.fiveGrams("gardens loud and quickly loud blue remember cloud")))
    }

    @Test func guardDropsEchoingGistAndNoteLines() {
        var inputs = DNAKit.fondMorning().inputs
        inputs.episodes = [EpisodeLine(id: DNAKit.id(901), gist: "we made pancakes with blueberries for my grandmother", daysAgo: 4, valence: 1)]
        inputs.stance.notes = [Note(.intention, slots: ["Ask about the pancakes with blueberries for my grandmother."])]
        inputs.userTextCorpus = ["we made pancakes with blueberries for my grandmother yesterday"]
        let r = DNAPrompt.build(inputs)
        #expect(Self.leaks(r.text, inputs.userTextCorpus).isEmpty)
        #expect(Set(r.dropped.map(\.lineKind)) == ["memories", "doNow"])
    }

    /// Review findings 1–2: a user echoing Dee's fixed vocabulary is not a leak. Nothing is
    /// dropped, nothing degrades, and section 9, identity, repair and boundaries all stay.
    @Test(arguments: [
        "answer their question first if they asked one",
        "I would never send them to an app for that",
        "why do you keep asking more than one question",
        "please don't bring up her ex again",
        "you are a tiny robot who lives in my phone",
        "it's been a bit awkward with my boss lately",
        "she always gives the benefit of the doubt to everyone",
    ])
    func fixedVocabularyEchoesKeepEveryFixedLine(_ said: String) {
        for a in DNAKit.all {
            var inputs = a.inputs
            if a.name == "fond-morning" { inputs.moment.ongoing.repair = .strained }
            let clean = DNAPrompt.build(inputs)
            inputs.userTextCorpus = [said]
            let r = DNAPrompt.build(inputs)
            #expect(r.text == clean.text, "\(a.name) / \(said): the render changed")
            #expect(r.dropped.isEmpty && r.steps == clean.steps, "\(a.name) / \(said): \(r.dropped) \(r.steps)")
            let boundary = DNAAssembler.assemble(inputs).relationship.userBoundaries.first?.text
            Self.checkFixedLinesSurvive(r.text, "\(a.name) / \(said)", boundary: boundary)
            #expect(Self.contentLeaks(r, DNAAssembler.assemble(inputs), [said]).isEmpty)
        }
        // At least one archetype really echoed it (otherwise the probe proves nothing).
        let echoed = DNAKit.all.contains { a in
            var i = a.inputs
            if a.name == "fond-morning" { i.moment.ongoing.repair = .strained }
            i.userTextCorpus = [said]
            return DNAPrompt.build(i).fixedEchoes > 0
        }
        #expect(echoed, "\(said): no archetype echoes it")
    }

    /// Review finding 2: stating a boundary in the session keeps it in the DNA.
    @Test func statingABoundaryKeepsIt() {
        let a = DNAKit.insultedRuptured()
        var inputs = a.inputs
        inputs.userTextCorpus = ["please don't bring up her ex again"]
        let r = DNAPrompt.build(inputs)
        #expect(r.text.contains("Don't bring up: her ex."))
        #expect(r.fixedEchoes > 0 && r.dropped.isEmpty)
    }

    /// A stored item next to fixed words still goes when the window touches it.
    @Test func mixedWindowsDropTheStoredItemOnly() {
        var inputs = DNAKit.fondMorning().inputs
        // "Coming up for them: football match in 2 days" — the user said the fixed prefix plus the subject.
        inputs.userTextCorpus = ["so coming up for them football match is the big one"]
        let r = DNAPrompt.build(inputs)
        #expect(r.dropped == [GuardDrop(section: 5, lineKind: "upcoming")])
        #expect(!r.text.contains("football match"))
        Self.checkFixedLinesSurvive(r.text, "mixed")
    }

    /// Review finding 6: hyphenated words count as the guard counts them.
    @Test func hyphenatedFactsAndSubjectsNeverKeepFiveGuardWords() {
        let cases = [
            ("Maya has a 3-year-old golden retriever named Max", "I have a 3-year-old golden retriever named Max"),
            ("Maya works part-time as dog-walker north-east Leeds", "I work part-time as dog-walker north-east Leeds"),
            ("Maya's sister-in-law runs fish-and-chip shop", "my sister-in-law runs fish-and-chip shop"),
        ]
        for (fact, said) in cases {
            let t = DNAAssembler.telegraphic(fact, names: ["Maya"])
            #expect(Self.fiveGrams(t).isDisjoint(with: Self.fiveGrams(said)), "\(fact) → \(t)")
            #expect(!t.isEmpty, "\(fact)")
        }
        #expect(DNAAssembler.telegraphic("Maya has a 3-year-old golden retriever named Max", names: ["Maya"]) == "3-year-old golden")
        // A 4-word subject with hyphens is 5+ guard words; the slot keeps at most 4.
        let s = DNAAssembler.slot("my sister-in-law's wedding")
        #expect(DNAPrompt.Guard.tokens(s).count <= DNAAssembler.maxRun && s == "my sister-in-law's")
        #expect(DNAAssembler.slot("football match") == "football match")
        #expect(DNAPrompt.Guard.tokens(DNAAssembler.slot("fish-and-chip-shop-owner")).count == 4)
        // In a render, from an earlier session (no corpus at all).
        var inputs = DNAKit.fondMorning().inputs
        inputs.moment.ongoing.interests = [Interest(subject: DNAKit.subject("my sister-in-law's wedding"), weight: 0.9, lastTouched: inputs.now)]
        let text = DNAPrompt.build(inputs).text
        #expect(Self.fiveGrams(text).isDisjoint(with: Self.fiveGrams("we went to my sister-in-law's wedding")))
    }

    /// Review finding 3: the corpus is built once and added to; one render with an hour of
    /// chat (600 × 15 words) stays fast.
    @Test func incrementalCorpusMatchesBatchAndRendersFast() {
        var rng = Rand(seed: 600)
        let corpus = (0..<600).map { _ in (0..<15).map { _ in Self.vocab[rng.index(Self.vocab.count)] }.joined(separator: " ") }
        var inc = DNAGuardCorpus()
        for u in corpus { inc.add(u) }
        #expect(inc == DNAGuardCorpus(corpus) && inc.texts == 600)
        var inputs = DNAKit.maxLength()
        inputs.guardCorpus = inc
        let r0 = DNAPrompt.build(inputs)
        /// Fastest of 15 single renders (robust to parallel test load).
        func ms(_ i: DNAInputs) -> Double {
            (0..<15).map { _ in
                let t = ContinuousClock().measure { _ = DNAPrompt.build(i) }
                return Double(t.components.seconds) * 1000 + Double(t.components.attoseconds) / 1e15
            }.min()!
        }
        let without = ms(DNAKit.maxLength())
        let with = ms(inputs)
        print("DNA render, max fixture: \(without) ms without corpus, \(with) ms with 600 utterances")
        // The guard's share no longer grows with a session's length: it was 4–15× the render
        // (8–9 ms release); now well under 2× (a ratio, so parallel test load cancels out).
        #expect(with / without < 2, "guard cost \(with - without) ms on \(without) ms")
        var loose = DNAKit.maxLength()
        loose.userTextCorpus = corpus
        #expect(DNAPrompt.build(loose) == r0)
    }

    // MARK: Telegraphic facts (30 golden pairs)

    @Test func telegraphicPairs() {
        let pairs: [(String, Fact.Category?, String)] = [
            ("Maya has a job interview on Sat 3 Oct", .event, "job interview Sat 3 Oct"),
            ("Maya's favourite colour is green", .preference, "favourite colour green"),
            ("Maya has a dog named Miso", .pet, "pet: dog named Miso"),
            ("Maya works as a nurse", .work, "work: works as nurse"),
            ("Maya lives in Halifax", .place, "place: lives Halifax"),
            ("Maya's birthday is on 12 May", .birthday, "birthday 12 May"),
            ("Maya has a sister called Ana", .relationship, "family: sister called Ana"),
            ("Maya likes jazz", .preference, "likes jazz"),
            ("Maya doesn't like mushrooms", .dislike, "doesn't like mushrooms"),
            ("Maya had a dentist appointment on Tue 6 Oct", .event, "dentist appointment Tue 6 Oct"),
            ("Maya is going to Lisbon in November 2026", .event, "going Lisbon November 2026"),
            ("Maya was going to Lisbon in November 2026", .event, "going Lisbon November 2026"),
            ("Maya plays the guitar", .preference, "plays guitar"),
            ("Maya is learning Spanish", .other, "learning Spanish"),
            ("Maya has two cats named Salt and Pepper", .pet, "pet: two cats named Salt Pepper"),
            ("Maya's last name is Okafor", .identity, "last name Okafor"),
            ("Maya is 34 years old", .identity, "34 years old"),
            ("Maya is a student at the art school", .work, "work: student art school"),
            ("Maya's partner is called Sam", .relationship, "family: partner called Sam"),
            ("Maya loves baking sourdough bread", .preference, "loves baking sourdough bread"),
            ("Maya has a football match on Sun 11 Oct", .event, "football match Sun 11 Oct"),
            ("Maya is from Lagos", .place, "place: from Lagos"),
            ("Maya hates the cold", .dislike, "hates cold"),
            ("Maya's son is called Leo", .relationship, "family: son called Leo"),
            ("Maya is vegetarian", .preference, "vegetarian"),
            ("Maya has an exam on Mon 12 Oct", .event, "exam Mon 12 Oct"),
            ("Maya drives a red van", .other, "drives red van"),
            ("Maya works at the bakery on Elm Street", .work, "work: works bakery Elm Street"),
            ("Maya goes by May", .identity, "goes by May"),
            ("Maya's cat is called Biscuit", .pet, "pet: cat called Biscuit"),
        ]
        for (line, cat, want) in pairs {
            #expect(DNAAssembler.telegraphic(line, names: ["Maya", "May"], category: cat) == want, "\(line)")
        }
    }

    // MARK: Exclusions

    @Test func sensitiveFactsNeverReachTheDNA() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let store = try MemoryStore(databaseURL: nil, faceMatching: FaceMatching(), calendar: cal)
        let now = DNAKit.local(9, 0)
        let p = try #require(await store.addPerson(named: "Maya", at: now))
        _ = await store.remember("has diabetes", category: .health, about: p.id, at: now)
        _ = await store.remember("likes jazz", category: .preference, about: p.id, at: now)
        let person = try #require(await store.person(p.id))
        var inputs = DNAKit.fondMorning().inputs
        let lines = await store.promptMemories(for: p.id, limit: 9, now: now)
        inputs.person = PersonInputs(person: person, promptMemories: lines)
        let text = DNAPrompt.build(inputs).text
        #expect(text.contains("likes jazz"))
        #expect(!text.lowercased().contains("diabetes"))
    }

    @Test func unrevealedTastesAndBoundaryTopicsNeverAppear() {
        for a in DNAKit.all {
            var inputs = a.inputs
            // An episode, a fact and an interest naming the boundary topic must all be filtered.
            inputs.episodes.append(EpisodeLine(id: DNAKit.id(902), gist: "she talked about her ex at length", daysAgo: 1, valence: -1))
            inputs.person?.facts.append(DNAFact(text: "Maya is still upset about her ex", category: .other))
            inputs.moment.ongoing.interests.append(Interest(subject: Subject("her ex")!, weight: 1, lastTouched: inputs.now))
            let text = DNAPrompt.build(inputs).text
            #expect(!text.contains("jazz piano"), "\(a.name): unrevealed taste")
            let lines = text.split(separator: "\n").filter { !$0.hasPrefix("Don't bring up: ") }
            #expect(!lines.contains { $0.contains("her ex") }, "\(a.name): boundary topic leaked")
        }
    }

    @Test func memorySharingOffRemovesMemories() {
        var inputs = DNAKit.fondMorning().inputs
        inputs.shareMemories = false
        let dna = DNAAssembler.assemble(inputs)
        #expect(dna.knowledge.facts.isEmpty && dna.knowledge.episodes.isEmpty && dna.knowledge.interests.isEmpty && dna.knowledge.upcoming.isEmpty)
        let text = DNAPrompt.text(dna)
        #expect(text.contains("Memories are private on this device right now"))
        for leaked in ["Miso", "nurse", "Halifax", "bread rise", "running shoes", "sourdough", "football match"] {
            let outside = text.split(separator: "\n").filter { !$0.hasPrefix("Keep in mind") && !$0.hasPrefix("Do now") }
            #expect(!outside.contains { $0.contains(leaked) }, "\(leaked)")
        }
        #expect(text.contains("Maya"))   // names are still allowed
    }

    @Test func noReproachOutsideHerOwnFeelingWords() {
        let a = DNAKit.reunion9Days()
        let text = DNAPrompt.build(a.inputs).text
        let lines = text.split(separator: "\n").map(String.init)
        let feelingSection = Set(lines.filter { l in Feeling.allCases.contains { l.hasPrefix("\($0.rawValue) ") } })
        for l in lines where !feelingSection.contains(l) {
            for w in CueWriter.reproachWords where l.lowercased().contains(w) {
                // The fixed "never blame / never guilt" wording is allowed; real reproach is not.
                #expect(l.hasPrefix("Always:") || l.contains("Never guilt") || l.contains("never blame"), "reproach '\(w)': \(l)")
            }
        }
        // Tune 3: the time apart is named lightly (glad, no guilt) instead of avoided.
        let g = DNAAssembler.assemble(a.inputs).guidance
        #expect(g.avoidLines.contains("any guilt about the time apart"))
        #expect(g.doLines.contains { $0.contains("in the same sentence, mention lightly that it's been about a week, glad they're back") }, "\(g.doLines)")
    }
}

extension Array {
    /// Seeded Fisher–Yates (tests only; `shuffled()` is banned in pure code).
    mutating func shuffleSeeded(_ rng: inout Rand) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) { swapAt(i, rng.index(i + 1)) }
    }
}
