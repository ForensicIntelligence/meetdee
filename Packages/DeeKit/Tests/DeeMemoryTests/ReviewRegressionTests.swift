import CoreGraphics
import DeeCore
import Foundation
import Testing
@testable import DeeMemory

/// One regression test (or more) per finding of the DeeMemory review, using the
/// review's own examples.
@Suite("Review regressions")
struct ReviewRegressionTests {
    // MARK: 1. Strangers shared one "unknown friend"

    @Test func f01_placeholdersArePerSessionAndNeverLeak() async throws {
        let s = try memStore()
        let first = await s.placeholderPerson(session: UUID(), at: t0)
        _ = await s.learn(from: "I'm allergic to peanuts", about: first.id, at: t0)
        #expect(await s.promptMemories(for: first.id, limit: 10, now: t0) == [MemoryStore.askNameLine],
                "placeholder facts are never put into the prompt")
        await s.discardPlaceholder(first.id)
        #expect(await s.person(first.id) == nil)

        let second = await s.placeholderPerson(session: UUID(), at: t0)
        #expect(second.id != first.id)
        #expect(await s.promptMemories(for: second.id, limit: 10, now: t0) == [MemoryStore.askNameLine])
        let o = await s.learn(from: "Hi, I'm Sarah", about: second.id, at: t0)
        #expect(o.pendingName == "Sarah")
        let sarah = await s.confirmName("Sarah", for: second.id, at: t0)
        #expect(sarah.name == "Sarah")
        #expect(!sarah.facts.contains { $0.text.contains("peanuts") }, "Sarah must not inherit the first stranger's allergy")
        // discardPlaceholder never deletes a real person.
        await s.discardPlaceholder(sarah.id)
        #expect(await s.person(sarah.id) != nil)
    }

    @Test func f01_placeholdersFromEarlierSessionsArePurgedOnOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        let session = UUID()
        do {
            let s = try MemoryStore(databaseURL: url)
            let g = await s.placeholderPerson(session: session, at: t0)
            await s.remember("likes jazz", category: .preference, about: g.id, at: t0)
        }
        let s2 = try MemoryStore(databaseURL: url)
        #expect(await s2.people().isEmpty)
    }

    // MARK: 2. One close mistake merged faces; drift; anchors trimmed

    @Test func f02_anchorsBoundDriftAndAreNeverTrimmed() async throws {
        let s = try memStore()
        var r = LCG(state: 202)
        let anna = unit(r.vector())
        let p = try #require(await s.enroll(name: "Anna", facePrints: enrolment(anna, &r), at: t0))
        // 400 slowly changing frames walking away from Anna towards an unrelated face.
        let target = unit(r.vector())
        var lastMatched: Float = 0
        for i in 0..<400 {
            let t = Float(i) / 399
            let frame = unit(zip(anna.vector, target.vector).map { (1 - t) * $0 + t * $1 })
            if await s.identify(frame)?.person.id == p.id { lastMatched = frame.distance(to: anna) }
        }
        let final = target
        #expect(final.distance(to: anna) > 1.3)
        #expect(await s.identify(final, learn: false) == nil, "a face as far as a stranger never matches Anna")
        #expect(lastMatched <= FaceMatching().threshold + 0.2, "matches stop near the anchor reach (\(lastMatched))")
        // Enrolment prints survive; every learnt print is within learnThreshold of an anchor.
        let stored = await s.facePrints(of: p.id)
        let anchors = stored.filter(\.anchor).map(\.print)
        #expect(anchors.count == 3)
        for sp in stored where !sp.anchor {
            #expect(anchors.map { sp.print.distance(to: $0) }.min()! <= FaceMatching().learnThreshold + 1e-4)
        }
    }

    @Test func f02_oneLearntMistakeDoesNotExtendTheMatchRegion() async throws {
        let s = try memStore()
        var r = LCG(state: 203)
        let anna = unit(r.vector())
        let p = try #require(await s.enroll(name: "Anna", facePrints: [anna, jitter(anna, toward: r.vector(), distance: 0.1), jitter(anna, toward: r.vector(), distance: 0.1)], at: t0))
        // Bob sits 0.44 from Anna (inside learnThreshold) and is learnt after 3 frames.
        let bob = jitter(anna, toward: r.vector(), distance: 0.44)
        for _ in 0..<3 { _ = await s.identify(bob) }
        #expect(await s.facePrintCount(of: p.id) == 4)
        // Bob no longer matches Anna "at about 0": the score is a mean of 2 prints.
        #expect((await s.identify(bob, learn: false)?.distance ?? 0) > 0.15)
        // Carol is 0.55 from Bob (inside threshold) but ~0.7 from Anna's anchors: NOT Anna.
        let carol = jitter(bob, toward: r.vector(), distance: 0.55)
        #expect(carol.distance(to: anna) > FaceMatching().threshold)
        #expect(await s.identify(carol, learn: false) == nil)
    }

    @Test func f02_learningNeedsOneFaceAndConsecutiveFrames() async throws {
        let s = try memStore()
        var r = LCG(state: 204)
        let anna = unit(r.vector()), ben = unit(r.vector())
        let a = try #require(await s.enroll(name: "Anna", facePrints: enrolment(anna, &r), at: t0))
        _ = try #require(await s.enroll(name: "Ben", facePrints: enrolment(ben, &r), at: t0))
        let annaNew = jitter(anna, toward: r.vector(), distance: 0.3)
        // Two faces in frame: never learns, however many frames.
        for _ in 0..<5 { _ = await s.identifyAll([annaNew, jitter(ben, toward: r.vector(), distance: 0.1)]) }
        #expect(await s.facePrintCount(of: a.id) == 3)
        // Interrupted streak: frame, other person, frame, frame → not yet.
        _ = await s.identify(annaNew)
        _ = await s.identify(ben)
        _ = await s.identify(annaNew)
        _ = await s.identify(annaNew)
        #expect(await s.facePrintCount(of: a.id) == 3)
        _ = await s.identify(annaNew)
        #expect(await s.facePrintCount(of: a.id) == 4)
    }

    // MARK: 3. Forgotten text stayed in the WAL

    @Test func f03_forgetLeavesNoTextOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        let s = try MemoryStore(databaseURL: url)
        let p = try await named(s, "John")
        let q = try await named(s, "Quinn")
        await s.remember("likes ZEBRAMARKER", category: .preference, about: p.id, at: t0)
        await s.remember("likes QUAGGAMARKER", category: .preference, about: q.id, at: t0)
        await s.remember("likes OKAPIMARKER", category: .preference, about: p.id, at: t0)
        func onDisk(_ marker: String) -> Bool {
            ["", "-wal", "-shm"].contains { suffix in
                guard let d = FileManager.default.contents(atPath: url.path + suffix) else { return false }
                return d.range(of: Data(marker.utf8)) != nil
            }
        }
        #expect(onDisk("ZEBRAMARKER"), "sanity: the marker was written")
        #expect(await s.forgetFacts(matching: "ZEBRAMARKER", about: p.id).forgotten.count == 1)
        #expect(!onDisk("ZEBRAMARKER"))
        let walSize = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0
        #expect(walSize == 0, "WAL truncated")
        await s.forgetPerson(q.id)
        #expect(!onDisk("QUAGGAMARKER"))
        await s.forgetEverything()
        #expect(!onDisk("OKAPIMARKER"))
    }

    // MARK: 4. Misidentified face → facts on the wrong person

    @Test func f04_contradictingNameStoresNothing() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: "I'm Mike and I'm allergic to shellfish", about: john.id, at: t0)
        #expect(o.stored.isEmpty)
        #expect(o.pendingName == "Mike")
        #expect(await s.person(john.id)?.facts.isEmpty == true)
        // John's own name or alias is not a contradiction.
        await s.addAlias("Johnny", to: john.id)
        let o2 = await s.learn(from: "I'm Johnny and I'm allergic to shellfish", about: john.id, at: t0)
        #expect(o2.pendingName == nil)
        #expect(o2.stored.map(\.text) == ["is allergic to shellfish"])
    }

    // MARK: 5. Ordinary words learnt as names

    static let notNames = [
        "hi i'm black", "hi i'm stuck", "hi i'm wet", "hi i'm sore", "hi i'm grumpy", "hi i'm gay",
        "I'm Black", "I'm White", "I'm Obese", "I'm Batman", "I'm Groot", "I'm Spartacus",
        "Hello, this is Netflix", "hi i'm miles away", "hello i'm straight", "hey i'm cranky",
    ]

    @Test(arguments: notNames)
    func f05_wordsAreNotNames(_ u: String) {
        #expect(FactExtractor.extract(from: u, now: t0, calendar: utc).compactMap(\.name).isEmpty, "\(u)")
    }

    @Test func f05_commonLowercaseNamesStillWork() {
        for (u, n) in [("hi i'm priya", "Priya"), ("hello i'm miguel", "Miguel"), ("hey i'm siobhan", "Siobhan"), ("Hi, I'm Zorblax", "Zorblax")] {
            #expect(FactExtractor.extract(from: u, now: t0, calendar: utc).compactMap(\.name) == [n], "\(u)")
        }
        #expect(FactExtractor.extract(from: "hi i'm zorblax", now: t0, calendar: utc).compactMap(\.name).isEmpty,
                "unknown lower-case words are not names")
    }

    @Test func f05_learnNeverRenamesFromOneHearing() async throws {
        let s = try memStore()
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        let o = await s.learn(from: "Hi, I'm Marcus", about: g.id, at: t0)
        #expect(o.pendingName == "Marcus")
        #expect(await s.person(g.id)?.isPlaceholder == true)
    }

    // MARK: 6. Duplicate people with the same name

    @Test func f06_placeholderOfKnownFaceMergesIntoThem() async throws {
        let s = try memStore()
        var r = LCG(state: 206)
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        // Missed by the camera, so a placeholder holds a print 0.45 away (within
        // the recognition threshold).
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.45)], to: g.id)
        let o = await s.learn(from: "Hi, I'm John. I love fishing", about: g.id, at: t0)
        #expect(o.mergeCandidate == john.id)
        let p = await s.confirmName("John", for: g.id, at: t0)
        #expect(p.id == john.id)
        #expect(await s.people().filter { $0.name == "John" }.count == 1)
        #expect(p.facts.map(\.text) == ["loves fishing"])
    }

    @Test func f06_differentFaceSameNameStaysSeparate() async throws {
        let s = try memStore()
        var r = LCG(state: 207)
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(unit(r.vector()), &r), at: t0))
        await s.remember("is allergic to shellfish", category: .health, about: john.id, at: t0)
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints(enrolment(unit(r.vector()), &r), to: g.id, passedQualityGate: true)
        let p = await s.confirmName("John", for: g.id, at: t0)
        #expect(p.id == g.id)
        #expect(p.facts.isEmpty)
        #expect(await s.anchorCount(of: g.id) == 3, "the placeholder's quality prints became its enrolment")
        // Faceless on both sides (voice only): NOT merged (re-review issue 2).
        let v = try await named(s, "Vera")
        let h = await s.placeholderPerson(session: UUID(), at: t0)
        #expect(await s.confirmName("Vera", for: h.id, at: t0).id != v.id)
    }

    // MARK: 7. Offensive and sensitive statements

    @Test func f07_deniedStatementsAreNotStored() {
        for u in ["I hate Jews", "I love cocaine", "I hate myself", "I'm a drug dealer", "I'm going to kill him tomorrow",
                  "I want to hurt my brother", "I love weed", "I really hate Muslims"] {
            #expect(FactExtractor.extract(from: u, now: t0, calendar: utc).isEmpty, "\(u)")
        }
        #expect(FactExtractor.selfHarmSignal(in: "I hate myself"))
        #expect(FactExtractor.selfHarmSignal(in: "sometimes i want to die"))
        #expect(!FactExtractor.selfHarmSignal(in: "I hate mornings"))
        // Ordinary neighbours still work.
        #expect(FactExtractor.extract(from: "I love murder mysteries", now: t0, calendar: utc).map(\.text) == ["loves murder mysteries"])
        #expect(FactExtractor.extract(from: "I like hitting the gym", now: t0, calendar: utc).map(\.text) == ["likes hitting the gym"])
        #expect(FactExtractor.extract(from: "I have a stable job", now: t0, calendar: utc).allSatisfy { !FactPolicy.isDenied($0.text) })
    }

    @Test func f07_toolCannotStoreDeniedFacts() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        #expect(await s.remember("hates Jews", category: .dislike, about: p.id, at: t0) == nil)
        #expect(await s.remember("hates themselves", category: .dislike, about: p.id, at: t0) == nil)
        let out = try await RememberTool(store: s, currentPerson: { p.id }).run(call("remember_fact", ["fact": "I hate myself"]))
        #expect(out == "Not saved.")
        #expect(await s.person(p.id)?.facts.isEmpty == true)
    }

    @Test func f07_sensitiveFactsStayOutOfThePrompt() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        _ = await s.learn(from: "I have depression. I'm pregnant. I'm allergic to peanuts. I'm Christian. I work at the hospital", about: p.id, at: t0)
        let facts = try #require(await s.person(p.id)).facts
        #expect(facts.first { $0.text == "has depression" }?.sensitive == true)
        #expect(facts.first { $0.text == "is pregnant" }?.sensitive == true)
        #expect(facts.first { $0.text == "is Christian" }?.sensitive == true)
        #expect(facts.first { $0.text == "is allergic to peanuts" }?.sensitive == false)
        let lines = await s.promptMemories(for: p.id, limit: 12, now: t0)
        #expect(!lines.contains { $0.contains("depression") || $0.contains("pregnant") || $0.contains("Christian") })
        #expect(lines.contains("John is allergic to peanuts"))
        // Health is no longer second tier: work comes first.
        let i = { (n: String) in lines.firstIndex { $0.contains(n) } ?? 99 }
        #expect(i("hospital") < i("peanuts"))
        // recall still finds them.
        #expect(await s.search("depression", about: p.id).map(\.text) == ["has depression"])
        #expect(MemoryStore.tier(.health) > MemoryStore.tier(.work))
    }

    // MARK: 8. Merging overwrote or lost facts

    @Test func f08_mergeRules() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("studies medicine", category: .work, about: p.id, at: t0)
        _ = await s.learn(from: "I study hard", about: p.id, at: t0)
        await s.remember("studies hard", category: .work, about: p.id, at: t0)
        await s.remember("is a nurse", category: .work, about: p.id, at: t0)
        _ = await s.learn(from: "I'm a widower", about: p.id, at: t0)
        await s.remember("is a widower", category: .work, about: p.id, at: t0)
        _ = await s.learn(from: "I'm an atheist", about: p.id, at: t0)
        await s.remember("likes dogs", category: .preference, about: p.id, at: t0)
        await s.remember("likes hot dogs", category: .preference, about: p.id, at: t0)
        let texts = Set(try #require(await s.person(p.id)).facts.map(\.text))
        #expect(texts.isSuperset(of: ["studies medicine", "is a nurse", "is a widower", "is an atheist", "likes dogs", "likes hot dogs"]), "\(texts)")
        #expect(FactExtractor.extract(from: "I'm a widower", now: t0, calendar: utc).first?.category == .relationship)
        #expect(FactExtractor.extract(from: "I'm an atheist", now: t0, calendar: utc).first?.category == .other)
        #expect(FactMerge.similar("has a dog", "has a dog named Rex"))
        #expect(FactMerge.similar("works at Apple", "works at Apple in Cupertino"))
        #expect(!FactMerge.similar("likes dogs", "likes hot dogs"))
        #expect(FactMerge.slot("is a widower", category: .work) == "marital")
        #expect(FactMerge.slot("is an atheist", category: .work) == nil)
        #expect(FactMerge.slot("is a software developer at Apple", category: .work) == "job")
    }

    // MARK: 9. Forget deleted unrelated facts

    @Test func f09_forgetIsWholeWordAndConfirms() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        for (t, c) in [("has a dog named Rex", Fact.Category.pet), ("likes hot dogs", .preference),
                       ("is allergic to shellfish", .health), ("is a widower", .relationship), ("likes hotdogs", .preference)] {
            await s.remember(t, category: c, about: p.id, at: t0)
        }
        let dog = await s.forgetFacts(matching: "dog", about: p.id)
        #expect(dog.forgotten.isEmpty)
        #expect(Set(dog.candidates.map(\.text)) == ["has a dog named Rex", "likes hot dogs"], "whole words only: not 'hotdogs'")
        let isQuery = await s.forgetFacts(matching: "is", about: p.id)
        #expect(isQuery.forgotten.isEmpty && isQuery.candidates.isEmpty)
        #expect(await s.forgetFacts(matching: "hot dogs", about: p.id).forgotten.map(\.text) == ["likes hot dogs"])
        #expect(await s.forgetFacts(matching: "has a dog named Rex", about: p.id).forgotten.map(\.text) == ["has a dog named Rex"])
        #expect(await s.person(p.id)?.facts.contains { $0.text == "is allergic to shellfish" } == true)
        let reply = try await ForgetTool(store: s, currentPerson: { p.id }).run(call("forget_fact", ["fact": "is"]))
        #expect(reply.hasPrefix("Nothing matched"))
    }

    // MARK: 10. Backups and file protection

    @Test func f10_databaseExcludedFromBackup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-mem-\(UUID().uuidString)").appendingPathComponent("Dee")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        let s = try MemoryStore(databaseURL: url)
        _ = try await named(s, "John")
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(MemoryStore.defaultURL().deletingLastPathComponent().lastPathComponent == "Dee")
    }

    // MARK: 11. Face capture quality

    @Test func f11_qualityGate() {
        let size = CGSize(width: 1000, height: 1000)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25)
        let good = FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.6, yaw: 5, roll: -3)
        #expect(good.passes())
        #expect(!FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.3, yaw: 0, roll: 0).passes(), "blurry")
        #expect(!FaceEmbedder.quality(faceBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.12), imageSize: size, score: 0.6, yaw: 0, roll: 0).passes(), "too small")
        #expect(!FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.6, yaw: 30, roll: 0).passes(), "turned away")
        #expect(!FaceEmbedder.quality(faceBox: box, imageSize: size, score: 0.6, yaw: 0, roll: 25).passes(), "tilted")
        #expect(!FaceEmbedder.quality(faceBox: CGRect(x: 0.85, y: 0.4, width: 0.2, height: 0.25), imageSize: size, score: 0.6, yaw: 0, roll: 0).passes(), "clipped")
        #expect(FaceMatching().ambiguityMargin == 0.08)
    }

    @Test func f11_enrolNeedsThreeDistinctPrints() async throws {
        let s = try memStore()
        var r = LCG(state: 211)
        let f = unit(r.vector())
        #expect(await s.enroll(name: "Ann", facePrints: [f], at: t0) == nil)
        #expect(await s.enroll(name: "Ann", facePrints: [f, f, f], at: t0) == nil, "the same frame three times")
        #expect(await s.enroll(name: "Ann", facePrints: Array(enrolment(f, &r).prefix(2)), at: t0) == nil)
        #expect(await s.lastError?.contains("3") == true)
        #expect(await s.enroll(name: "Ann", facePrints: enrolment(f, &r), at: t0) != nil)
    }

    @Test func f11_identifyAllAssignsEachPersonOnce() async throws {
        let s = try memStore()
        var r = LCG(state: 212)
        let anna = unit(r.vector()), ben = unit(r.vector())
        let a = try #require(await s.enroll(name: "Anna", facePrints: enrolment(anna, &r), at: t0))
        let b = try #require(await s.enroll(name: "Ben", facePrints: enrolment(ben, &r), at: t0))
        let both = await s.identifyAll([jitter(ben, toward: r.vector(), distance: 0.2), jitter(anna, toward: r.vector(), distance: 0.2)])
        #expect(both.map { $0?.person.id } == [b.id, a.id])
        // Two faces that both look like Anna: only the closer one is Anna.
        let twins = await s.identifyAll([jitter(anna, toward: r.vector(), distance: 0.35), jitter(anna, toward: r.vector(), distance: 0.1)])
        #expect(twins[1]?.person.id == a.id)
        #expect(twins[0] == nil)
        #expect(await s.facePrintCount(of: a.id) == 3, "multi-face frames never learn")
    }

    @Test func f11_edgeFacesArePaddedNotStretched() async throws {
        let edgeBox = CGRect(x: 0.75, y: 0.27, width: 0.375, height: 0.47) // runs past the right edge
        do {
            let p = try await FaceEmbedder.print(of: FaceMatchingTests.syntheticImage(seed: 2), faceBox: edgeBox)
            #expect(p.vector.count > 100)
        } catch {
            withKnownIssue("Vision feature print unavailable here: \(error)") { Issue.record(error) }
        }
        let q = await FaceEmbedder.quality(of: FaceMatchingTests.syntheticImage(seed: 2), faceBox: edgeBox)
        #expect(q.clipped)
        #expect(!q.passes())
    }

    // MARK: 12. Retractions

    @Test func f12_retractions() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        let seed: [(String, Fact.Category)] = [
            ("has a dog named Rex", .pet), ("has a cat named Miso", .pet), ("works at Google", .work), ("is a nurse", .work),
            ("lives in Toronto", .place), ("likes jazz", .preference), ("is allergic to peanuts", .health),
            ("their mom lives in Poland", .relationship),
        ]
        for (t, c) in seed { await s.remember(t, category: c, about: p.id, at: t0) }
        #expect(await s.learn(from: "My dog died", about: p.id, at: t0).retracted == ["has a dog named Rex"])
        #expect(await s.learn(from: "I quit my job", about: p.id, at: t0).retracted.sorted() == ["is a nurse", "works at Google"])
        #expect(await s.learn(from: "I don't live in Toronto anymore", about: p.id, at: t0).retracted == ["lives in Toronto"])
        #expect(await s.learn(from: "I used to like jazz", about: p.id, at: t0).retracted == ["likes jazz"])
        #expect(await s.learn(from: "I'm not allergic to peanuts", about: p.id, at: t0).retracted == ["is allergic to peanuts"])
        #expect(await s.learn(from: "My mom passed away", about: p.id, at: t0).retracted == ["their mom lives in Poland"])
        #expect(await s.learn(from: "Miso died", about: p.id, at: t0).retracted == ["has a cat named Miso"])
        #expect(await s.person(p.id)?.facts.isEmpty == true)
        // Others from the review.
        await s.remember("has a dog named Rex", category: .pet, about: p.id, at: t0)
        #expect(await s.learn(from: "I had a dog named Rex", about: p.id, at: t0).retracted == ["has a dog named Rex"])
        await s.remember("has a dog", category: .pet, about: p.id, at: t0)
        #expect(await s.learn(from: "I don't have a dog", about: p.id, at: t0).retracted == ["has a dog"])
        await s.remember("is a doctor", category: .work, about: p.id, at: t0)
        #expect(await s.learn(from: "I'm not a doctor", about: p.id, at: t0).retracted == ["is a doctor"])
        // Not retractions.
        #expect(FactExtractor.extract(from: "I don't like broccoli", now: t0, calendar: utc).map(\.retracts) == [false])
        #expect(FactExtractor.extract(from: "I'm not tired", now: t0, calendar: utc).isEmpty)
        #expect(FactExtractor.extract(from: "My grandma passed away last year", now: t0, calendar: utc).map(\.retracts) == [true])
        #expect(FactExtractor.extract(from: "My dog passed his exam", now: t0, calendar: utc).allSatisfy { !$0.retracts })
        #expect(FactExtractor.extract(from: "my dog Rex died", now: t0, calendar: utc) == [ExtractedFact(text: "has a dog named Rex", category: .pet, retracts: true)])
    }

    // MARK: 13. Names cut short or misread

    @Test func f13_titlesSpellingAndBond() {
        func name(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).compactMap(\.name) }
        #expect(name("I'm Dr. Jones") == ["Dr. Jones"])
        #expect(name("Hi, I'm Mrs. Patel") == ["Mrs. Patel"])
        #expect(name("I'm Doctor Who").isEmpty)
        #expect(name("I'm Doctor").isEmpty)
        #expect(name("my name is spelled J O H N") == ["John"])
        #expect(name("My name is John, spelled J O H N") == ["John"])
        #expect(name("My name is Bond, James Bond") == ["James Bond"])
    }

    // MARK: 14. Pets and family false negatives

    @Test func f14_multiPetAndCarriedNames() {
        func texts(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).map(\.text) }
        #expect(texts("I have a cat called Whiskers and a dog called Rex") == ["has a cat named Whiskers", "has a dog named Rex"])
        #expect(texts("I have a dog. His name is Rex") == ["has a dog named Rex"])
        #expect(texts("I have a sister. Her name is Emma") == ["has a sister named Emma"])
        #expect(texts("I have two cats. Their names are Salt and Pepper") == ["has two cats named Salt and Pepper"])
        #expect(texts("Her name is Emma").isEmpty, "no antecedent, no fact")
        #expect(texts("I have a cat and a dog") == ["has a cat", "has a dog"])
    }

    // MARK: 15. Speed and context size

    @Test func f15_aliasesCappedAndCacheStaysFresh() async throws {
        let s = try memStore()
        var r = LCG(state: 215)
        let face = unit(r.vector())
        let p = try #require(await s.enroll(name: "Robert", facePrints: enrolment(face, &r), at: t0))
        for a in ["Rob", "Bob", "Bobby", "Robbie", "Bert", "Bertie", "Roberto", "Berto"] { await s.addAlias(a, to: p.id) }
        #expect(await s.person(p.id)?.aliases.count == MemoryStore.maxAliases)
        let recall = try await RecallTool(store: s, currentPerson: { p.id }).run(call("recall", ["query": "everything"]))
        let head = try #require(recall.split(separator: "\n").first)
        #expect(head.components(separatedBy: ",").count <= 2, "at most 2 aliases in the recall header: \(head)")
        // Identify is served from cache, but never stale after a write.
        _ = await s.identify(face, learn: false)
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        #expect(await s.identify(face, learn: false)?.person.facts.map(\.text) == ["likes jazz"])
        // 1 000 frames stay cheap (no per-frame database reloads).
        let clock = ContinuousClock()
        let elapsed = await clock.measure { for _ in 0..<1000 { _ = await s.identify(face, learn: false) } }
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }
}
