import DeeMemory
import DeeSense
import Foundation

/// Who Dee is talking to, and what Dee remembers about them.
///
/// Deliberately conservative — a companion that confuses people, or tells one
/// person another's secrets, is worse than one that asks:
/// - A face is "known" only when DeeMemory recognises it.
/// - An unknown face gets a per-session placeholder; good-quality prints of that
///   face are attached to it so the store can judge "same face?" later.
/// - A name is confirmed only on a placeholder: heard twice, or heard with at most
///   one face in view. A known person is never given someone else's name.
/// - "Have we met?": when a same-named person exists and the faces can't settle
///   it, Dee asks, and the next yes/no decides.
@MainActor
final class People {
    enum Event: Equatable {
        /// A different known person is now in front of Dee.
        case recognised(Person)
        /// Someone told Dee their name and it stuck.
        case learnedName(String)
        /// Dee thought this was `thought`, but they said they're `heard`.
        case nameConflict(heard: String, thought: String)
        /// "Are you the Sarah I've met before?" — waiting for yes/no.
        case askSamePerson(name: String)
        /// The user introduced someone else ("this is my friend Sarah").
        case introduced([String])
        /// Something they said sounded like they might be hurting.
        case wellbeingConcern
        /// "My dog died" with two dogs on record — ask which.
        case askWhich([String])
    }

    let store: MemoryStore
    private(set) var current: Person? {
        didSet { if oldValue?.id != current?.id { onCurrentChanged?(current) } }
    }
    private var session = UUID()
    private var facesInView = 0
    private var recognisedAt: [UUID: Date] = [:]
    /// Pending "have we met?" question: name and the existing person.
    private var pendingSameAs: (name: String, existing: UUID, placeholder: UUID)?

    /// Keeps DeeSelf in step with identity changes the memory store makes.
    var onMerged: ((_ from: UUID, _ into: UUID) -> Void)?
    var onDiscarded: ((UUID) -> Void)?
    var onCurrentChanged: ((Person?) -> Void)?

    var currentID: UUID? { current?.id }
    var currentName: String? { current.flatMap { $0.isPlaceholder ? nil : $0.name } }

    init?() {
        guard let store = try? MemoryStore(databaseURL: MemoryStore.defaultURL()) else { return nil }
        self.store = store
    }

    /// Someone new in front of Dee (they left and came back, or a new conversation).
    func newSession() {
        session = UUID()
        pendingSameAs = nil
        if let c = current, c.isPlaceholder {
            onDiscarded?(c.id)
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
                if let c = current, c.isPlaceholder { onDiscarded?(c.id) }
                current = person
                pendingSameAs = nil
                // Don't re-greet someone who just stepped out of frame for a moment.
                let last = recognisedAt[person.id]
                recognisedAt[person.id] = Date()
                if last.map({ Date().timeIntervalSince($0) > 300 }) ?? true { return .recognised(person) }
            }
            return nil
        }
        // Unknown main face: talk to this session's placeholder and attach good
        // prints of the face to it (the store needs them to judge "same face?").
        if current == nil || current?.isPlaceholder == false {
            current = await store.placeholderPerson(session: session, at: Date())
        }
        if crops.count == 1, let id = current?.id,
           let p = try? await FaceEmbedder.enrolmentPrint(of: main.image, faceBox: main.box) {
            await store.addFacePrints([p], to: id, anchor: false, passedQualityGate: true)
        }
        return nil
    }

    // MARK: - Words

    /// Learns facts (and possibly a name) from something the user said.
    func heard(_ text: String) async -> Event? {
        if let pending = pendingSameAs, let answer = Self.yesNo(text) {
            pendingSameAs = nil
            let choice: SameNameChoice = answer ? .sameAs(pending.existing) : .newPerson
            let result = await store.confirm(pending.name, for: pending.placeholder, at: Date(), choice: choice)
            return adopt(result, name: pending.name)
        }
        if current == nil { current = await store.placeholderPerson(session: session, at: Date()) }
        guard let person = current else { return nil }
        let outcome = await store.learn(from: text, about: person.id, at: Date())
        if outcome.wellbeingConcern { return .wellbeingConcern }
        if outcome.differentSpeaker, let heard = outcome.pendingName {
            return .nameConflict(heard: heard, thought: person.name)
        }
        if let alias = outcome.suggestedAlias, !person.isPlaceholder {
            await store.addAlias(alias, to: person.id)
        }
        if outcome.retractionCandidates.count > 1 {
            return .askWhich(outcome.retractionCandidates.map(\.text))
        }
        guard let name = outcome.pendingName else {
            current = await store.person(person.id) ?? current
            return outcome.introduced.isEmpty ? nil : .introduced(outcome.introduced)
        }
        guard person.isPlaceholder else { return nil }
        let times = await store.pendingName(for: person.id)?.timesHeard ?? 1
        guard times >= 2 || facesInView <= 1 else { return nil }
        return adopt(await store.confirm(name, for: person.id, at: Date(), choice: .ask), name: name)
    }

    private func adopt(_ result: ConfirmResult, name: String) -> Event? {
        switch result {
        case .named(let p, _):
            current = p
            return .learnedName(p.name)
        case .merged(let p):
            if let from = current?.id, from != p.id { onMerged?(from, p.id) }
            current = p
            return .learnedName(p.name)
        case .mergeCandidate(let placeholder, let existing):
            current = placeholder
            pendingSameAs = (name, existing.id, placeholder.id)
            return .askSamePerson(name: name)
        case .differentSpeaker(let c, let heard, _):
            return .nameConflict(heard: heard, thought: c.name)
        case .rejected:
            return nil
        }
    }

    /// A plain yes/no answer, or nil if the utterance isn't one.
    static func yesNo(_ text: String) -> Bool? {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let yes = ["yes", "yeah", "yep", "yup", "that's me", "it's me", "that was me", "sure", "of course", "we have", "you have", "yes we have"]
        let no = ["no", "nope", "nah", "not me", "we haven't", "never", "no we haven't", "different person", "that's not me"]
        if yes.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return true }
        if no.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return false }
        return nil
    }

    /// Short lines for the system prompt (~300 tokens max). `limit` lets a caller with
    /// a tighter budget (the cloud voice's session instructions) ask for fewer.
    func memories(limit: Int = 10) async -> [String] {
        guard let id = current?.id else { return [] }
        return await store.promptMemories(for: id, limit: limit)
    }
}
