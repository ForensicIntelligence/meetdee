import Foundation
import Testing
@testable import DeeMemory

func memStore() throws -> MemoryStore { try MemoryStore(databaseURL: nil, faceMatching: FaceMatching(), calendar: utc) }

/// A voice-only person (no face prints).
func named(_ s: MemoryStore, _ name: String, at: Date = thursdayNoon) async throws -> Person {
    try #require(await s.addPerson(named: name, at: at))
}

let t0 = thursdayNoon

@Suite("MemoryStore")
struct MemoryStoreTests {
    @Test func enrollAndLookUp() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        #expect(p.name == "John")
        #expect(p.encounters == 1)
        #expect(await s.person(p.id)?.name == "John")
        #expect(await s.person(named: "john")?.id == p.id)
        #expect(await s.people().count == 1)
    }

    /// Finding 6 B: a voice-only John is NOT assumed to be a newly enrolled face.
    @Test func enrollDoesNotAttachToFacelessNamesakeUnlessReused() async throws {
        let s = try memStore()
        var r = LCG(state: 61)
        let a = try await named(s, "John")
        await s.remember("is allergic to shellfish", category: .health, about: a.id, at: t0)
        let b = try #require(await s.enroll(name: "john", facePrints: enrolment(unit(r.vector()), &r), at: t0.addingTimeInterval(3600)))
        #expect(a.id != b.id)
        #expect(b.facts.isEmpty, "the new face does not inherit the other John's facts")
        let c = try #require(await s.enroll(name: "John", facePrints: enrolment(unit(r.vector()), &r), at: t0, reuse: true))
        #expect(c.id == a.id || c.id == b.id)
        #expect(await s.anchorCount(of: c.id) >= 3)
    }

    @Test func enrollingSameNameWithSameFaceReusesPerson() async throws {
        let s = try memStore()
        var r = LCG(state: 62)
        let face = unit(r.vector())
        let a = try #require(await s.enroll(name: "Alex", facePrints: enrolment(face, &r), at: t0))
        let b = try #require(await s.enroll(name: "alex", facePrints: enrolment(jitter(face, toward: r.vector(), distance: 0.2), &r), at: t0))
        #expect(a.id == b.id)
    }

    @Test func enrollingSameNameWithDifferentFaceCreatesSecondPerson() async throws {
        let s = try memStore()
        var r = LCG(state: 63)
        let a = try #require(await s.enroll(name: "Alex", facePrints: enrolment(unit(r.vector()), &r), at: t0))
        let b = try #require(await s.enroll(name: "Alex", facePrints: enrolment(unit(r.vector()), &r), at: t0))
        #expect(a.id != b.id)
    }

    @Test func persistsAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-mem-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id: UUID
        var mayaFace = FacePrint(vector: [])
        do {
            let s = try MemoryStore(databaseURL: url)
            var r = LCG(state: 64)
            let p = try #require(await s.enroll(name: "Maya", facePrints: enrolment(FacePrint(vector: r.vector()), &r), at: t0))
            id = p.id
            mayaFace = (await s.facePrints(of: id)).first!.print
            await s.remember("likes jazz", category: .preference, about: id, at: t0)
            await s.addAlias("May", to: id)
        }
        let s2 = try MemoryStore(databaseURL: url)
        let p = try #require(await s2.person(id))
        #expect(p.name == "Maya")
        #expect(p.aliases == ["May"])
        #expect(p.facts.map(\.text) == ["likes jazz"])
        #expect(await s2.facePrintCount(of: id) == 3)
        #expect(await s2.anchorCount(of: id) == 3)
        #expect(await s2.identify(mayaFace, learn: false)?.person.id == id)
    }

    @Test func duplicateFactsMerge() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        let a = try #require(await s.remember("likes jazz", category: .preference, about: p.id, at: t0))
        let b = try #require(await s.remember("Likes jazz.", category: .preference, about: p.id, at: t0.addingTimeInterval(60)))
        #expect(a.id == b.id)
        #expect(b.confidence > a.confidence)
        #expect(b.updatedAt == t0.addingTimeInterval(60))
        #expect(await s.person(p.id)?.facts.count == 1)
    }

    @Test func moreDetailedWordingWins() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("has a dog", category: .pet, about: p.id, at: t0)
        await s.remember("has a dog named Rex", category: .pet, about: p.id, at: t0)
        #expect(await s.person(p.id)?.facts.map(\.text) == ["has a dog named Rex"])
        await s.remember("has a dog", category: .pet, about: p.id, at: t0)
        #expect(await s.person(p.id)?.facts.map(\.text) == ["has a dog named Rex"])
    }

    @Test func differentPetsStaySeparate() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("has a cat named Miso", category: .pet, about: p.id, at: t0)
        await s.remember("has a cat named Tofu", category: .pet, about: p.id, at: t0)
        #expect(await s.person(p.id)?.facts.count == 2)
    }

    @Test func contradictionReplaces() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        await s.remember("dislikes jazz", category: .dislike, about: p.id, at: t0.addingTimeInterval(10))
        let facts = await s.person(p.id)?.facts ?? []
        #expect(facts.map(\.text) == ["dislikes jazz"])
        #expect(facts.first?.category == .dislike)
        await s.remember("loves jazz", category: .preference, about: p.id, at: t0.addingTimeInterval(20))
        #expect(await s.person(p.id)?.facts.map(\.text) == ["loves jazz"])
    }

    @Test func singleValuedSlotsUpdate() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("lives in Toronto", category: .place, about: p.id, at: t0)
        await s.remember("lives in Ottawa", category: .place, about: p.id, at: t0)
        await s.remember("is 41 years old", category: .identity, about: p.id, at: t0)
        await s.remember("is 42 years old", category: .identity, about: p.id, at: t0)
        await s.remember("favourite colour is blue", category: .preference, about: p.id, at: t0)
        await s.remember("favourite colour is green", category: .preference, about: p.id, at: t0)
        await s.remember("favourite food is sushi", category: .preference, about: p.id, at: t0)
        await s.remember("works as a nurse", category: .work, about: p.id, at: t0)
        await s.remember("is a doctor", category: .work, about: p.id, at: t0)
        let texts = Set(await s.person(p.id)?.facts.map(\.text) ?? [])
        #expect(texts == ["lives in Ottawa", "is 42 years old", "favourite colour is green", "favourite food is sushi", "is a doctor"])
    }

    @Test func factTextIsNormalised() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        #expect(await s.remember("John likes jazz.", category: .preference, about: p.id, at: t0)?.text == "likes jazz")
        #expect(await s.remember("The user has a cat", category: .pet, about: p.id, at: t0)?.text == "has a cat")
        #expect(await s.remember("they love hiking", category: .preference, about: p.id, at: t0)?.text == "loves hiking")
        #expect(await s.remember("John's wife is Sarah", category: .relationship, about: p.id, at: t0)?.text == "their wife is Sarah")
    }

    @Test func forgetMatching() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        await s.remember("has a cat named Miso", category: .pet, about: p.id, at: t0)
        #expect(await s.forget(factMatching: "jazz", about: p.id))
        #expect(await s.forget(factMatching: "that I have a cat named Miso", about: p.id))
        #expect(await s.person(p.id)?.facts.isEmpty == true)
        #expect(await s.forget(factMatching: "skiing", about: p.id) == false)
    }

    @Test func forgetDoesNotWipeOnVagueQuery() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        await s.remember("lives in Ottawa", category: .place, about: p.id, at: t0)
        #expect(await s.forget(factMatching: "something about rugby", about: p.id) == false)
        #expect(await s.person(p.id)?.facts.count == 2)
    }

    @Test func encountersAreDebounced() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.noteEncounter(p.id, at: t0.addingTimeInterval(60))
        await s.noteEncounter(p.id, at: t0.addingTimeInterval(120))
        #expect(await s.person(p.id)?.encounters == 1)
        await s.noteEncounter(p.id, at: t0.addingTimeInterval(3 * 3600))
        let q = await s.person(p.id)
        #expect(q?.encounters == 2)
        #expect(q?.lastSeen == t0.addingTimeInterval(3 * 3600))
    }

    @Test func renameKeepsOldNameAsAlias() async throws {
        let s = try memStore()
        let p = try await named(s, "Jon")
        await s.rename(p.id, to: "John")
        let q = await s.person(p.id)
        #expect(q?.name == "John")
        #expect(q?.aliases == ["Jon"])
        #expect(await s.person(named: "Jon")?.id == p.id)
    }

    @Test func placeholdersArePerSessionAndRenameCleanly() async throws {
        let s = try memStore()
        let session = UUID()
        let a = await s.placeholderPerson(session: session, at: t0)
        #expect(await s.placeholderPerson(session: session, at: t0).id == a.id)
        #expect(await s.placeholderPerson(session: UUID(), at: t0).id != a.id, "never shared across sessions")
        #expect(a.isPlaceholder)
        #expect(a.session == session)
        let k = await s.confirmName("Kim", for: a.id, at: t0)
        #expect(k.id == a.id)
        #expect(k.name == "Kim")
        #expect(k.aliases.isEmpty)
        #expect(k.session == nil)
        #expect(await s.placeholderPerson(session: session, at: t0).id != a.id)
    }

    @Test func mergeFoldsEverything() async throws {
        let s = try memStore()
        var r = LCG(state: 65)
        let ghost = await s.placeholderPerson(session: UUID(), at: t0)
        await s.remember("likes jazz", category: .preference, about: ghost.id, at: t0)
        await s.remember("has a cat named Miso", category: .pet, about: ghost.id, at: t0)
        await s.noteEncounter(ghost.id, at: t0.addingTimeInterval(7200))
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0.addingTimeInterval(-86_400)))
        await s.remember("likes jazz", category: .preference, about: john.id, at: t0)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.3)], to: ghost.id)
        await s.merge(ghost.id, into: john.id)
        #expect(await s.person(ghost.id) == nil)
        let j = try #require(await s.person(john.id))
        #expect(Set(j.facts.map(\.text)) == ["likes jazz", "has a cat named Miso"])
        #expect(j.aliases.isEmpty)
        #expect(j.encounters == 3)
        #expect(j.firstMet == t0.addingTimeInterval(-86_400))
        #expect(j.lastSeen == t0.addingTimeInterval(7200))
        #expect(await s.facePrintCount(of: john.id) == 4)
        #expect(await s.anchorCount(of: john.id) == 3)
    }

    @Test func mergeOfNamedPersonAddsAlias() async throws {
        let s = try memStore()
        let a = try await named(s, "Johnny")
        let b = try await named(s, "John")
        await s.merge(a.id, into: b.id)
        #expect(await s.person(b.id)?.aliases == ["Johnny"])
    }

    @Test func forgetEverythingEmptiesStore() async throws {
        let s = try memStore()
        var r = LCG(state: 66)
        let face = unit(r.vector())
        let p = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        await s.forgetEverything()
        #expect(await s.people().isEmpty)
        #expect(await s.identify(face) == nil)
    }

    @Test func forgetPersonOnly() async throws {
        let s = try memStore()
        let a = try await named(s, "A")
        let b = try await named(s, "B")
        await s.forgetPerson(a.id)
        #expect(await s.people().map(\.id) == [b.id])
    }

    @Test func promptMemoriesRanking() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("likes jazz", category: .preference, about: p.id, at: t0)
        await s.remember("has an exam on Fri 9 Oct 2026", category: .event, about: p.id, at: t0)
        await s.remember("has a daughter named Emma", category: .relationship, about: p.id, at: t0)
        await s.remember("is 42 years old", category: .identity, about: p.id, at: t0)
        await s.remember("had a trip on Mon 1 Jun 2026", category: .event, about: p.id, at: t0)
        await s.remember("has a dog named Rex", category: .pet, about: p.id, at: t0)
        await s.remember("works as a nurse", category: .work, about: p.id, at: t0)
        let lines = await s.promptMemories(for: p.id, limit: 10, now: t0)
        #expect(lines.first == "Name: John")
        #expect(lines[1] == "John is 42 years old")
        let idx = { (needle: String) in lines.firstIndex { $0.contains(needle) } ?? 99 }
        #expect(idx("daughter") < idx("nurse"))
        #expect(idx("Rex") < idx("nurse"))
        #expect(idx("nurse") < idx("jazz"))
        #expect(idx("jazz") < idx("exam"))
        #expect(!lines.contains { $0.contains("trip") }, "stale events are dropped")
        let short = await s.promptMemories(for: p.id, limit: 3, now: t0)
        #expect(short.count == 3)
        #expect(lines.allSatisfy { $0.count <= 100 })
    }

    @Test func promptForPlaceholderOnlyAsksName() async throws {
        let s = try memStore()
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.remember("likes jazz", category: .preference, about: g.id, at: t0)
        await s.remember("birthday is March 3", category: .birthday, about: g.id, at: t0)
        let lines = await s.promptMemories(for: g.id, limit: 5, now: t0)
        #expect(lines == [MemoryStore.askNameLine])
    }

    @Test func promptAliasesAndEncounters() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.addAlias("Johnny", to: p.id)
        await s.noteEncounter(p.id, at: t0.addingTimeInterval(86_400))
        let first = await s.promptMemories(for: p.id, limit: 1, now: t0)
        #expect(first == ["Name: John (also Johnny); met 2 times since October 2026"])
        #expect(await s.promptMemories(for: p.id, limit: 0, now: t0).isEmpty)
        #expect(await s.promptMemories(for: UUID(), limit: 5, now: t0).isEmpty)
    }

    @Test func searchFindsByKeywordAndCategory() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        await s.remember("has a cat named Miso", category: .pet, about: p.id, at: t0)
        await s.remember("likes jazz music", category: .preference, about: p.id, at: t0)
        await s.remember("birthday is March 3", category: .birthday, about: p.id, at: t0)
        #expect(await s.search("pets", about: p.id).first?.text == "has a cat named Miso")
        #expect(await s.search("Miso", about: p.id).first?.text == "has a cat named Miso")
        #expect(await s.search("musics", about: p.id).first?.text == "likes jazz music")
        #expect(await s.search("when is my birthday", about: p.id).first?.text == "birthday is March 3")
        #expect(await s.search("everything", about: p.id).count == 3)
        #expect(await s.search("rugby", about: p.id).isEmpty)
    }

    @Test func learnKeepsNamePendingUntilConfirmed() async throws {
        let s = try memStore()
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        let o = await s.learn(from: "Hi, I'm Priya and I have a dog named Bean", about: g.id, at: t0)
        #expect(o.pendingName == "Priya")
        #expect(o.mergeCandidate == nil)
        #expect(o.stored.map(\.text) == ["has a dog named Bean"])
        #expect(await s.person(g.id)?.isPlaceholder == true, "a name heard once is not applied")
        #expect(await s.pendingName(for: g.id, now: t0)?.timesHeard == 1)
        _ = await s.learn(from: "I'm Priya", about: g.id, at: t0.addingTimeInterval(120))
        #expect(await s.pendingName(for: g.id, now: t0.addingTimeInterval(120))?.timesHeard == 2)
        #expect(await s.pendingName(for: g.id, now: t0.addingTimeInterval(120 + 11 * 60)) == nil, "expires")
        let p = await s.confirmName("Priya", for: g.id, at: t0)
        #expect(p.id == g.id)
        #expect(p.name == "Priya")
        #expect(p.facts.map(\.text) == ["has a dog named Bean"])
    }

    @Test func learnDoesNotRenameAKnownPerson() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        let o = await s.learn(from: "My name is Peter. Call me Pete.", about: p.id, at: t0)
        #expect(o.pendingName == "Peter")
        #expect(o.stored.isEmpty)
        let q = await s.person(p.id)
        #expect(q?.name == "John")
        #expect(q?.aliases.isEmpty == true, "aliases are not applied without confirmation")
        // Thomas confirming his own name plus a nickname keeps the facts and pends the alias.
        let t = try await named(s, "Thomas")
        let o2 = await s.learn(from: "I'm Thomas but everyone calls me Tom. I love chess", about: t.id, at: t0)
        #expect(o2.pendingName == "Tom")
        #expect(o2.stored.map(\.text) == ["loves chess"])
        #expect(await s.confirmName("Tom", for: t.id, at: t0).aliases == ["Tom"])
    }

    @Test func unknownPersonIsHarmless() async throws {
        let s = try memStore()
        let f = await s.remember("likes jazz", category: .preference, about: UUID(), at: t0)
        #expect(f == nil)
        #expect(await s.people().isEmpty)
        #expect(await s.forget(factMatching: "jazz", about: UUID()) == false)
        await s.noteEncounter(UUID(), at: t0)
        await s.rename(UUID(), to: "X")
    }

    @Test func defaultURLIsApplicationSupport() {
        let url = MemoryStore.defaultURL()
        #expect(url.lastPathComponent == "DeeMemory.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Dee")
        #expect(url.path.contains("Application Support/Dee/"))
    }

    @Test func codableModelsRoundTrip() throws {
        let p = Person(name: "John", aliases: ["J"], firstMet: t0, lastSeen: t0, encounters: 3,
                       facts: [Fact(text: "likes jazz", category: .preference, createdAt: t0)])
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Person.self, from: data) == p)
        let fp = FacePrint(vector: [0.1, -0.2, 0.3])
        #expect(try JSONDecoder().decode(FacePrint.self, from: JSONEncoder().encode(fp)) == fp)
        #expect(FacePrint(blob: fp.blob) == fp)
    }
}
