import DeeMemory
import DeeSense
import Foundation

/// Who Dee is talking to, and what she remembers about them.
///
/// Deliberately conservative — a companion that confuses people, or tells one
/// person another's secrets, is worse than one that asks:
/// - A face is "known" only when DeeMemory recognises it.
/// - An unknown face gets a per-session placeholder; nothing it says leaks to
///   anyone else.
/// - A name is applied only to a placeholder, and only once it is confirmed (heard
///   twice, or heard with exactly one face in view). A known person is never given
///   a different person's name; Dee checks out loud instead.
/// - Faces are enrolled only from good-quality captures (≥ 3 prints).
@MainActor
final class People {
    enum Event: Equatable {
        /// A different known person is now in front of Dee.
        case recognised(Person)
        /// Someone told Dee their name and it stuck.
        case learnedName(String)
        /// Dee thought this was `thought`, but they said they're `heard`.
        case nameConflict(heard: String, thought: String)
    }

    let store: MemoryStore
    private(set) var current: Person?
    private var session = UUID()
    private var enrolment: [FacePrint] = []
    private var facesInView = 0
    private var recognisedAt: [UUID: Date] = [:]

    var currentID: UUID? { current?.id }
    var currentName: String? { current.flatMap { $0.isPlaceholder ? nil : $0.name } }

    init?() {
        guard let store = try? MemoryStore(databaseURL: MemoryStore.defaultURL()) else { return nil }
        self.store = store
    }

    /// Someone new in front of Dee (they left and came back, or a new conversation).
    func newSession() {
        session = UUID()
        enrolment.removeAll()
        if let c = current, c.isPlaceholder {
            let id = c.id
            Task { await store.discardPlaceholder(id) }
            current = nil
        }
    }

    // MARK: - Faces

    /// Face crops from the camera (largest first).
    func process(_ crops: [FaceCrop]) async -> Event? {
        facesInView = crops.count
        guard let main = crops.first else { return nil }
        var prints: [FacePrint] = []
        for crop in crops.prefix(3) {
            guard let p = try? await FaceEmbedder.print(of: crop.image, faceBox: crop.box) else { return nil }
            prints.append(p)
        }
        let matches = await store.identifyAll(prints)
        if let match = matches.first ?? nil {
            let person = match.person
            await store.noteEncounter(person.id, at: Date())
            if current?.id != person.id {
                if let c = current, c.isPlaceholder { await store.discardPlaceholder(c.id) }
                current = person
                enrolment.removeAll()
                // Don't re-greet someone who just stepped out of frame for a moment.
                let last = recognisedAt[person.id]
                recognisedAt[person.id] = Date()
                if last.map({ Date().timeIntervalSince($0) > 300 }) ?? true { return .recognised(person) }
            }
            return nil
        }
        // An unknown main face: talk to a placeholder; collect good enrolment prints.
        if current == nil || current?.isPlaceholder == false {
            current = await store.placeholderPerson(session: session, at: Date())
            enrolment.removeAll()
        }
        if crops.count == 1, enrolment.count < 8,
           let p = try? await FaceEmbedder.enrolmentPrint(of: main.image, faceBox: main.box) {
            enrolment.append(p)
        }
        return nil
    }

    // MARK: - Words

    /// Learns facts (and possibly a name) from something the user said.
    func heard(_ text: String) async -> Event? {
        if current == nil { current = await store.placeholderPerson(session: session, at: Date()) }
        guard let person = current else { return nil }
        let outcome = await store.learn(from: text, about: person.id, at: Date())
        guard let name = outcome.pendingName else {
            current = await store.person(person.id) ?? current
            return nil
        }
        if !person.isPlaceholder {
            // A known person never takes on someone else's name.
            return person.answers(to: name) ? nil : .nameConflict(heard: name, thought: person.name)
        }
        let times = await store.pendingName(for: person.id)?.timesHeard ?? 1
        guard times >= 2 || facesInView <= 1 else { return nil }
        let named = await store.confirmName(name, for: person.id, at: Date())
        if enrolment.count >= 3, await store.anchorCount(of: named.id) < 3 {
            await store.addFacePrints(enrolment, to: named.id, anchor: true)
        }
        enrolment.removeAll()
        current = await store.person(named.id) ?? named
        return .learnedName(named.name)
    }

    /// Short lines for the system prompt (~300 tokens max).
    func memories() async -> [String] {
        guard let id = current?.id else { return [] }
        return await store.promptMemories(for: id, limit: 10)
    }
}
