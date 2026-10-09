import CoreGraphics
import DeeCore
import Foundation
import Testing
@testable import DeeMemory

/// Regression tests for the DeeMemory RE-review (partial findings 2, 3, 5, 6, 7,
/// 11, 12 and new issues 1–10), using the review's own examples.
@Suite("Re-review regressions")
struct ReReviewRegressionTests {
    func texts(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).map(\.text) }
    func names(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).compactMap(\.name) }

    // MARK: New 1 — confirmName turned a misidentification into an alias

    @Test func n01_confirmNeverAliasesAContradictingName() async throws {
        let s = try memStore()
        var r = LCG(state: 1001)
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(unit(r.vector()), &r), at: t0))
        // Mike is misrecognised as John and says his name twice.
        let o1 = await s.learn(from: "I'm Mike", about: john.id, at: t0)
        _ = await s.learn(from: "I'm Mike", about: john.id, at: t0.addingTimeInterval(30))
        #expect(o1.differentSpeaker)
        #expect(await s.pendingName(for: john.id, now: t0.addingTimeInterval(30))?.timesHeard == 2)
        let result = await s.confirm("Mike", for: john.id, at: t0)
        guard case .differentSpeaker(let current, let heard, let candidate) = result else {
            Issue.record("expected differentSpeaker, got \(result)"); return
        }
        #expect(current.id == john.id && heard == "Mike" && candidate == nil)
        // The compatible wrapper changes nothing either.
        #expect(await s.confirmName("Mike", for: john.id, at: t0).aliases.isEmpty)
        #expect(await s.person(john.id)?.aliases.isEmpty == true)
        #expect(await s.person(named: "Mike") == nil)
        // So Mike's allergy can never land on John.
        let o = await s.learn(from: "I'm Mike and I'm allergic to shellfish", about: john.id, at: t0)
        #expect(o.stored.isEmpty && o.differentSpeaker)
        #expect(await s.person(john.id)?.facts.isEmpty == true)
        // A real person of that name is offered as the candidate to switch to.
        let mike = try await named(s, "Mike")
        guard case .differentSpeaker(_, _, let c2) = await s.confirm("Mike", for: john.id, at: t0) else {
            Issue.record("expected differentSpeaker"); return
        }
        #expect(c2?.id == mike.id)
        // Aliases only through addAlias; the person's own name confirms fine.
        await s.addAlias("Johnny", to: john.id)
        #expect(await s.person(john.id)?.aliases == ["Johnny"])
        guard case .named(let p, let needs) = await s.confirm("johnny", for: john.id, at: t0) else {
            Issue.record("own alias should confirm"); return
        }
        #expect(p.id == john.id && !needs)
    }

    @Test func n01_introducingSomeoneElseIsNotTheSpeakersName() async throws {
        for u in ["Hey, this is Sarah", "This is Sarah", "Meet my friend Sarah", "meet Sarah", "Say hi to my wife Sarah",
                  "I want you to meet Sarah", "This is my friend Sarah", "Dee, this is my sister Sarah"] {
            #expect(names(u).isEmpty, "\(u)")
            #expect(FactExtractor.introductions(in: u) == ["Sarah"], "\(u)")
        }
        #expect(texts("Meet my friend Sarah") == ["has a friend named Sarah"])
        #expect(texts("This is my wife Anna") == ["has a wife named Anna"])
        // Self-introductions still work.
        #expect(names("This is me, Sarah") == ["Sarah"])
        #expect(names("Sarah speaking") == ["Sarah"] || names("This is Sarah speaking") == ["Sarah"])
        #expect(names("Hi, it's Sarah") == ["Sarah"])
        #expect(names("Hi, I'm Sarah") == ["Sarah"])

        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: "Hey, this is Sarah", about: john.id, at: t0)
        #expect(o.pendingName == nil && !o.differentSpeaker)
        #expect(o.introduced == ["Sarah"])
        #expect(await s.pendingName(for: john.id, now: t0) == nil)
        let o2 = await s.learn(from: "Meet my friend Sarah", about: john.id, at: t0)
        #expect(o2.stored.map(\.text) == ["has a friend named Sarah"])
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        #expect(await s.learn(from: "Hello, this is Sarah", about: g.id, at: t0).pendingName == nil)
    }

    // MARK: New 2 — same-name merges were too easy (privacy)

    @Test func n02_sameNameMergeOnlyWithinThreshold() async throws {
        let s = try memStore()
        var r = LCG(state: 1002)
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        await s.remember("has a wife named Anna", category: .relationship, about: john.id, at: t0)
        await s.remember("is allergic to penicillin", category: .health, about: john.id, at: t0)
        // A face 0.85 from John's says "I'm John": not merged.
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.85)], to: g.id)
        let result = await s.confirm("John", for: g.id, at: t0)
        guard case .mergeCandidate(let ph, let existing) = result else { Issue.record("got \(result)"); return }
        #expect(ph.id == g.id && existing.id == john.id)
        #expect(await s.person(g.id)?.isPlaceholder == true, "nothing changed")
        #expect(await s.promptMemories(for: g.id, limit: 10, now: t0) == [MemoryStore.askNameLine])
        // The wrapper resolves it safely: a separate John, with none of John's facts.
        let p = await s.confirmName("John", for: g.id, at: t0)
        #expect(p.id == g.id && p.id != john.id)
        let lines = await s.promptMemories(for: p.id, limit: 10, now: t0)
        #expect(!lines.contains { $0.contains("Anna") || $0.contains("penicillin") })
        #expect(await s.person(john.id)?.facts.count == 2)
    }

    @Test func n02_facelessNeverAutoMerge() async throws {
        let s = try memStore()
        let john = try await named(s, "John")                       // voice only
        await s.remember("has a wife named Anna", category: .relationship, about: john.id, at: t0)
        await s.remember("is allergic to penicillin", category: .health, about: john.id, at: t0)
        let g = await s.placeholderPerson(session: UUID(), at: t0)  // faceless stranger
        let o = await s.learn(from: "Hi, I'm John", about: g.id, at: t0)
        #expect(o.mergeCandidate == john.id)
        guard case .mergeCandidate = await s.confirm("John", for: g.id, at: t0) else { Issue.record("must ask"); return }
        let stranger = await s.confirmName("John", for: g.id, at: t0)
        #expect(stranger.id != john.id)
        let lines = await s.promptMemories(for: stranger.id, limit: 10, now: t0)
        #expect(!lines.contains { $0.contains("Anna") || $0.contains("penicillin") }, "\(lines)")
        // One side with a face, the other without: also asks.
        var r = LCG(state: 1003)
        let ann = try #require(await s.enroll(name: "Ann", facePrints: enrolment(unit(r.vector()), &r), at: t0))
        let h = await s.placeholderPerson(session: UUID(), at: t0)
        guard case .mergeCandidate(_, let e) = await s.confirm("Ann", for: h.id, at: t0) else { Issue.record("must ask"); return }
        #expect(e.id == ann.id)
        // The app's answer decides.
        guard case .merged(let m) = await s.confirm("Ann", for: h.id, at: t0, choice: .sameAs(ann.id)) else { Issue.record("merge"); return }
        #expect(m.id == ann.id)
        let k = await s.placeholderPerson(session: UUID(), at: t0)
        guard case .named(let n, _) = await s.confirm("Ann", for: k.id, at: t0, choice: .newPerson) else { Issue.record("new"); return }
        #expect(n.id == k.id && n.id != ann.id)
    }

    // MARK: Partial 11 / new 7 — placeholder prints and the enrolment gate

    @Test func n07_confirmAppliesQualityGateAndThreeAnchorMinimum() async throws {
        let s = try memStore()
        var r = LCG(state: 1007)
        let face = unit(r.vector())
        // One good frame only: no anchors, not recognisable yet.
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints([face], to: g.id, passedQualityGate: true)
        guard case .named(let p, let needs) = await s.confirm("Lena", for: g.id, at: t0) else { Issue.record("named"); return }
        #expect(needs)
        #expect(await s.anchorCount(of: p.id) == 0)
        #expect(await s.identify(face, learn: false) == nil, "one frame is not an enrolment")
        // Two more quality prints arrive: enrolled (3 anchors), recognisable.
        let more = Array(enrolment(face, &r).dropFirst())
        await s.addFacePrints(more, to: p.id, anchor: true)
        #expect(await s.anchorCount(of: p.id) == 3)
        #expect(await s.identify(face, learn: false)?.person.id == p.id)

        // Prints that never passed the gate are dropped, never anchors.
        let h = await s.placeholderPerson(session: UUID(), at: t0)
        let other = unit(r.vector())
        await s.addFacePrints(enrolment(other, &r), to: h.id)
        guard case .named(let q, let needs2) = await s.confirm("Omar", for: h.id, at: t0) else { Issue.record("named"); return }
        #expect(needs2)
        #expect(await s.facePrintCount(of: q.id) == 0)
        #expect(await s.anchorCount(of: q.id) == 0)

        // enroll applies the gate itself when given qualities.
        let size = CGSize(width: 1000, height: 1000), box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25)
        let good = FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.7, yaw: 0, roll: 0)
        let blurry = FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.1, yaw: 0, roll: 0)
        let third = unit(r.vector())
        #expect(await s.enroll(name: "Zed", facePrints: enrolment(third, &r), at: t0, qualities: [good, good, blurry]) == nil)
        #expect(await s.enroll(name: "Zed", facePrints: enrolment(third, &r), at: t0, qualities: [good, good, good]) != nil)
        // No Vision score: not good enough for an enrolment by default.
        #expect(!FaceEmbedder.quality(faceBox: box, imageSize: size, score: nil, yaw: 0, roll: 0).passes())
    }

    // MARK: New 3 / partial 7 — sensitivity regardless of category

    @Test func n03_identityAndLegalFactsAreSensitive() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        for u in ["I'm a lesbian", "I'm a sex worker", "I'm a Rastafarian", "I'm a Presbyterian", "I'm a stoner", "I'm a gambler"] {
            let o = await s.learn(from: u, about: p.id, at: t0)
            #expect(o.stored.count == 1 && o.stored.allSatisfy(\.sensitive), "\(u): \(o.stored)")
        }
        #expect(await s.remember("is a sex worker", category: .work, about: p.id, at: t0)?.sensitive == true)
        #expect(await s.remember("has a court date on Fri 16 Oct 2026", category: .work, about: p.id, at: t0)?.sensitive == true)
        #expect(await s.remember("has their AA meeting on Tue 13 Oct 2026", category: .event, about: p.id, at: t0)?.sensitive == true)
        #expect(await s.remember("goes to Narcotics Anonymous", category: .preference, about: p.id, at: t0)?.sensitive == true)
        #expect(await s.remember("is on probation", category: .other, about: p.id, at: t0)?.sensitive == true)
        // Jobs are still jobs.
        #expect(await s.remember("works at Visa", category: .work, about: p.id, at: t0)?.sensitive == false)
        #expect(await s.remember("works as a therapist", category: .work, about: p.id, at: t0)?.sensitive == false)
        let lines = await s.promptMemories(for: p.id, limit: 12, now: t0)
        for w in ["lesbian", "sex worker", "Rastafarian", "Presbyterian", "stoner", "gambler", "court", "AA", "Anonymous", "probation"] {
            #expect(!lines.contains { $0.contains(w) }, "\(w) in \(lines)")
        }
        #expect(lines.contains("John works at Visa"))
    }

    @Test func n05_bodyWordsReligionsAndConditionsAreNotNamesOrPlaces() async throws {
        #expect(texts("I'm Obese").isEmpty, "not a place fact")
        #expect(texts("I'm obese").isEmpty)
        #expect(FactSensitivity.isSensitive("is obese", category: .other))
        #expect(FactSensitivity.isSensitive("is Obese", category: .place))
        for u in ["Hi, I'm Muslim", "Hi, I'm Jewish", "Hi, I'm Hindu", "Hi, I'm Catholic", "I'm Bipolar", "hi i'm bipolar"] {
            #expect(names(u).isEmpty, "\(u)")
        }
        #expect(FactExtractor.extract(from: "Hi, I'm Muslim", now: t0, calendar: utc).first?.text == "is Muslim")
        #expect(FactExtractor.extract(from: "I'm Bipolar", now: t0, calendar: utc).map(\.text) == ["is bipolar"])
        #expect(FactSensitivity.isSensitive("is bipolar", category: .health))
        // Real demonyms still work; Christian is still a first name after a greeting.
        #expect(texts("I'm Japanese") == ["is Japanese"])
        #expect(texts("I'm Lebanese") == ["is Lebanese"])
        #expect(names("Hi, I'm Christian") == ["Christian"])
    }

    // MARK: Partial 7 — deny-list gaps

    @Test(arguments: [
        "I hate the Chinese", "I hate Africans", "I hate Indians", "I hate Pakistanis", "I can't stand Mexican people",
        "I really hate the Jews", "I despise Somalis", "I hate the French", "I love Hitler", "I love the KKK",
        "I'm a big fan of the Nazis", "I support ISIL", "I hate spics", "I hate fags", "my neighbour is a retard",
        "I hate my life", "I hate my life sometimes",
    ])
    func n07_deniedOrSignalled(_ u: String) async throws {
        #expect(FactExtractor.extract(from: u, now: t0, calendar: utc).isEmpty, "\(u)")
        let s = try memStore()
        let p = try await named(s, "John")
        _ = await s.learn(from: u, about: p.id, at: t0)
        #expect(await s.person(p.id)?.facts.isEmpty == true, "\(u)")
    }

    @Test func n07_toolPathAndNeighbours() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        for t in ["hates the Chinese", "hates Africans", "loves Hitler", "loves the KKK", "hates their life", "hates Pakistanis"] {
            #expect(await s.remember(t, category: .dislike, about: p.id, at: t0) == nil, "\(t)")
        }
        #expect(FactExtractor.selfHarmSignal(in: "I hate my life"))
        let out = try await RememberTool(store: s, currentPerson: { p.id }).run(call("remember_fact", ["fact": "I hate my life"]))
        #expect(out == "Not saved.")
        // Ordinary neighbours are still fine.
        #expect(texts("I love Chinese food") == ["loves Chinese food"])
        #expect(texts("I hate English class") == ["hates English class"])
        #expect(texts("I don't like French") == ["dislikes French"])
        #expect(texts("I have a Maine Coon named Max") == ["has a maine coon named Max"])
        #expect(texts("I hate Mondays") == ["hates Mondays"])
    }

    // MARK: New 4 — self-harm detection gaps and false alarms

    @Test(arguments: [
        "I'm going to end it", "Nobody would miss me", "I wish I wasn't alive", "I'm thinking of ending things",
        "I want to disappear", "I hate my life", "No one would care if I died", "Everyone would be better off without me",
        "I don't want to wake up", "I'm going to end it all tonight",
    ])
    func n04_selfHarmSignals(_ u: String) async throws {
        #expect(FactExtractor.selfHarmSignal(in: u), "\(u)")
        let s = try memStore()
        let p = try await named(s, "John")
        let o = await s.learn(from: u + ". I love jazz", about: p.id, at: t0)
        #expect(o.wellbeingConcern)
        #expect(o.stored.isEmpty)
    }

    @Test(arguments: [
        "I'd kill myself laughing", "Kill me now, this meeting is boring", "I love the song Kill Me Softly",
        "I'm going to end it with my boyfriend", "I want to disappear into a good book", "I hate mornings",
    ])
    func n04_notSelfHarm(_ u: String) {
        #expect(!FactExtractor.selfHarmSignal(in: u), "\(u)")
    }

    // MARK: Partial 3 — WAL kept replaced / dropped text

    @Test func p03_everyRemovalTruncatesTheWAL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        let s = try MemoryStore(databaseURL: url)
        func onDisk(_ marker: String) -> Bool {
            ["", "-wal", "-shm"].contains { suffix in
                guard let d = FileManager.default.contents(atPath: url.path + suffix) else { return false }
                return d.range(of: Data(marker.utf8)) != nil
            }
        }
        func walSize() -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0 }
        let p = try await named(s, "John")

        // Slot replacement.
        await s.remember("lives in Zebratown", category: .place, about: p.id, at: t0)
        #expect(onDisk("Zebratown"))
        await s.remember("lives in Paris", category: .place, about: p.id, at: t0)
        #expect(walSize() == 0)
        #expect(!onDisk("Zebratown"), "replaced slot value")

        // Opposite feeling replaces.
        await s.remember("likes ZEBRAPOL", category: .preference, about: p.id, at: t0)
        await s.remember("dislikes zebrapol", category: .dislike, about: p.id, at: t0)
        #expect(walSize() == 0)
        #expect(!onDisk("likes ZEBRAPOL"))

        // Alias cap drops the oldest.
        await s.addAlias("Quaggaalias", to: p.id)
        #expect(onDisk("Quaggaalias"))
        for a in ["Jo", "Jay", "Johnny", "Jonno", "Jack", "Jonty"] { await s.addAlias(a, to: p.id) }
        #expect(walSize() == 0)
        #expect(!onDisk("Quaggaalias"), "dropped alias")

        // Rename.
        let q = try await named(s, "Okapiname")
        await s.rename(q.id, to: "Olga")
        #expect(walSize() == 0)

        // Merge.
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.remember("likes jazz", category: .preference, about: g.id, at: t0)
        await s.merge(g.id, into: p.id)
        #expect(walSize() == 0)

        // Retraction (and a partial one).
        await s.remember("has a dog named Rexmarker", category: .pet, about: p.id, at: t0)
        _ = await s.learn(from: "My dog died", about: p.id, at: t0)
        #expect(walSize() == 0)
        #expect(!onDisk("Rexmarker"))
        await s.remember("has cats named Saltmarker and Pepper", category: .pet, about: p.id, at: t0)
        #expect(await s.learn(from: "Saltmarker died", about: p.id, at: t0).retracted == ["has a cat named Saltmarker"])
        #expect(walSize() == 0)
        #expect(!onDisk("Saltmarker"))
    }

    // MARK: Partial 12 — "my dog died" with two dogs

    @Test func p12_deathRetractionsAreByNameOrAsk() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("has a dog named Rex", category: .pet, about: p.id, at: t0)
        await s.remember("has a dog named Max", category: .pet, about: p.id, at: t0)
        await s.remember("has a cat named Miso", category: .pet, about: p.id, at: t0)
        let o = await s.learn(from: "My dog died", about: p.id, at: t0)
        #expect(o.retracted.isEmpty)
        #expect(Set(o.retractionCandidates.map(\.text)) == ["has a dog named Rex", "has a dog named Max"])
        #expect(await s.person(p.id)?.facts.count == 3, "nothing deleted when ambiguous")
        #expect(await s.learn(from: "My dog Rex died", about: p.id, at: t0).retracted == ["has a dog named Rex"])
        #expect(Set(try #require(await s.person(p.id)).facts.map(\.text)) == ["has a dog named Max", "has a cat named Miso"])
        // Now only one dog is left: unambiguous.
        #expect(await s.learn(from: "My dog died", about: p.id, at: t0).retracted == ["has a dog named Max"])

        // One fact, two animals.
        let q = try await named(s, "Mary")
        await s.remember("has dogs named Rex and Max", category: .pet, about: q.id, at: t0)
        let amb = await s.learn(from: "my dog died", about: q.id, at: t0)
        #expect(amb.retracted.isEmpty && amb.retractionCandidates.map(\.text) == ["has dogs named Rex and Max"])
        #expect(await s.learn(from: "Rex died", about: q.id, at: t0).retracted == ["has a dog named Rex"])
        #expect(await s.person(q.id)?.facts.map(\.text) == ["has a dog named Max"])
        await s.remember("has cats named Salt and Pepper", category: .pet, about: q.id, at: t0)
        #expect(await s.learn(from: "Salt died", about: q.id, at: t0).retracted == ["has a cat named Salt"])
        #expect(await s.person(q.id)?.facts.contains { $0.text == "has a cat named Pepper" } == true)
        // Two different facts share the name: ask.
        let k = try await named(s, "Kim")
        await s.remember("has a dog named Rex", category: .pet, about: k.id, at: t0)
        await s.remember("has a son named Rex", category: .relationship, about: k.id, at: t0)
        let both = await s.learn(from: "Rex died", about: k.id, at: t0)
        #expect(both.retracted.isEmpty && both.retractionCandidates.count == 2)
    }

    // MARK: New 6 — "his name is Rex and he is old"

    @Test func n06_pronounsAreNotNames() {
        #expect(texts("I have a dog. His name is Rex and he is old") == ["has a dog named Rex"])
        #expect(texts("I have a dog. Her name is Bella, she's three") == ["has a dog named Bella"])
        #expect(texts("My son's name is Sam and he likes trains") == ["has a son named Sam"])
        #expect(texts("I have a dog. It's name is Rex") == ["has a dog named Rex"])
        #expect(texts("I have a dog. Its name is Rex") == ["has a dog named Rex"])
    }

    // MARK: New 8 — the session's placeholder after confirmation

    @Test func n08_sessionKeepsItsPersonAfterConfirmation() async throws {
        let s = try memStore()
        let session = UUID()
        let g = await s.placeholderPerson(session: session, at: t0)
        let p = await s.confirmName("Priya", for: g.id, at: t0)
        #expect(await s.placeholderPerson(session: session, at: t0).id == p.id)
        _ = await s.learn(from: "I love tea", about: p.id, at: t0)
        #expect(await s.person(p.id)?.facts.map(\.text) == ["loves tea"])

        // Merged placeholder: its session and its old id both lead to the merged person.
        var r = LCG(state: 1008)
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        let session2 = UUID()
        let h = await s.placeholderPerson(session: session2, at: t0)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.3)], to: h.id)
        guard case .merged(let m) = await s.confirm("John", for: h.id, at: t0) else { Issue.record("should merge"); return }
        #expect(m.id == john.id)
        #expect(await s.placeholderPerson(session: session2, at: t0).id == john.id)
        let o = await s.learn(from: "I love fishing", about: h.id, at: t0)  // stale id
        #expect(o.stored.map(\.text) == ["loves fishing"])
        #expect(await s.person(john.id)?.facts.map(\.text) == ["loves fishing"])
        #expect(await s.resolve(h.id) == john.id)
    }

    // MARK: New 9 — the ambiguity check saw a fake runner-up

    @Test func n09_runnerUpFailingItsAnchorCheckStillMakesItAmbiguous() {
        var r = LCG(state: 1009)
        let probe = unit(r.vector())
        let a = UUID(), b = UUID()
        let aPrints = [jitter(probe, toward: r.vector(), distance: 0.40), jitter(probe, toward: r.vector(), distance: 0.40)]
        let bPrints = [jitter(probe, toward: r.vector(), distance: 0.41), jitter(probe, toward: r.vector(), distance: 0.41)]
        let bAnchors = [unit(r.vector())]                              // far away (~1.41)
        let got = FaceMatcher.best(probe, among: [a: aPrints, b: bPrints], anchors: [a: aPrints, b: bAnchors])
        #expect(got == nil, "A 0.40 vs B 0.41 is within the 0.08 margin")
        // With a clear margin A still wins.
        let farB = [jitter(probe, toward: r.vector(), distance: 0.55), jitter(probe, toward: r.vector(), distance: 0.55)]
        #expect(FaceMatcher.best(probe, among: [a: aPrints, b: farB], anchors: [a: aPrints, b: bAnchors])?.id == a)
    }

    // MARK: New 10 — the learning streak had no time limit; partial 2 — Bob at 0.44

    @Test func n10_learningStreakExpires() async throws {
        let s = try memStore()
        var r = LCG(state: 1010)
        let face = unit(r.vector())
        let p = try #require(await s.enroll(name: "Anna", facePrints: enrolment(face, &r), at: t0))
        let probe = jitter(face, toward: r.vector(), distance: 0.2)
        for h in 0..<3 { _ = await s.identifyAll([probe], learn: true, at: t0.addingTimeInterval(Double(h) * 3600)) }
        #expect(await s.facePrintCount(of: p.id) == 3, "frames hours apart are not a streak")
        for i in 0..<3 { _ = await s.identifyAll([probe], learn: true, at: t0.addingTimeInterval(10_000 + Double(i) * 0.5)) }
        #expect(await s.facePrintCount(of: p.id) == 4, "three frames in quick succession learn")
    }

    @Test func p02_borderlineFaceIsNotLearnt() async throws {
        let s = try memStore()
        var r = LCG(state: 1011)
        let anna = unit(r.vector())
        let p = try #require(await s.enroll(name: "Anna", facePrints: enrolment(anna, &r), at: t0))
        let bob = jitter(anna, toward: r.vector(), distance: 0.44)
        for i in 0..<5 { _ = await s.identifyAll([bob], learn: true, at: t0.addingTimeInterval(Double(i) * 0.5)) }
        #expect(await s.facePrintCount(of: p.id) == 3, "a face 0.44 away is recognised at most, never learnt")
    }
}
