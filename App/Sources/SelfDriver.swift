import DeeCore
import DeeMemory
import DeeMind
import DeeSelf
import Foundation
import os

/// The app's bridge to DeeSelf: owns the Cortex (Dee's one shared interpretation of
/// the moment) and its store, batches persistence, and hands every other effect
/// back to DeeModel to execute. See docs/contracts-0.5/self.md "What the app calls".
@MainActor
final class SelfDriver {
    private(set) var cortex: Cortex
    let store: SelfStore
    private var pending: [SelfWrite] = []
    private var lastFlush = Date()
    private static let log = Logger(subsystem: "ca.forensicintelligence.dee", category: "self")

    var stance: Stance { cortex.stance }
    var reconciledTag: Emotion? { cortex.reconciledTag }

    private init(cortex: Cortex, store: SelfStore) {
        self.cortex = cortex
        self.store = store
    }

    /// Opens the self store (inside DeeMemory's database file) and builds the Cortex.
    /// `preset`: the persona the self belongs to (seeded from it on first use);
    /// `reseed`: the persona just changed — its seeded self (values, humour, mannerisms,
    /// tastes) replaces the old one; everything learnt about people is kept.
    static func open(memory: MemoryStore?, snapshot: MindSnapshot, preset: PersonaPreset = PersonaCatalog.classic,
                     reseed: Bool = false) async -> SelfDriver? {
        do {
            let store = try SelfStore.open()
            if let memory {
                let known = await memory.people().map(\.id)
                _ = try await store.forgetPeople(notIn: known)
            }
            let now = Date()
            if reseed { try await store.reseed(for: preset, fallbackSeed: UInt64.random(in: .min ... .max), at: now) }
            let enduring = try await store.loadEnduring(personality: snapshot.code.personality,
                                                        seed: UInt64.random(in: .min ... .max), at: now, preset: preset)
            let carried = try await store.loadCarried(at: now)
            let session = try await store.nextSession()
            var cortex = Cortex(enduring: enduring, mind: snapshot, at: now, carried: carried, session: session,
                                utcOffset: TimeInterval(TimeZone.current.secondsFromGMT(for: now)))
            cortex.identity = preset
            return SelfDriver(cortex: cortex, store: store)
        } catch {
            log.error("DeeSelf unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Steps the Cortex; persistence is batched here, everything else is returned
    /// for DeeModel to execute in order.
    func step(_ p: Percept, mind: MindSnapshot, at now: Date = Date()) -> [Effect] {
        absorb(cortex.step(p, mind: mind, at: now))
    }

    /// The whole `<dee_state>` for the next LLM turn (call after `.promptSubmitted`).
    func cue(at now: Date = Date()) -> (String, [Effect]) {
        let (text, effects) = cortex.cue(at: now)
        return (text, absorb(effects))
    }

    /// Loads this person's past episodes so Dee can recall shared moments from
    /// earlier launches (call when someone is identified).
    func prefetch(person: UUID) async {
        if let episodes = try? await store.episodes(person: person, limit: 20), !episodes.isEmpty {
            cortex.prefetch(episodes: episodes)
        }
    }

    func persona(_ base: Persona, person: UUID?, at now: Date = Date()) -> Persona {
        cortex.persona(base, person: person, at: now)
    }

    private func absorb(_ effects: [Effect]) -> [Effect] {
        var out: [Effect] = []
        for e in effects {
            if case .persist(let w) = e { pending.append(w) } else { out.append(e) }
        }
        if pending.count >= 24 || Date().timeIntervalSince(lastFlush) > 30 { Task { await self.save() } }
        return out
    }

    /// Writes the pending batch.
    func save() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        lastFlush = Date()
        do {
            let result = try await store.apply(batch)
            if !result.failed.isEmpty { Self.log.error("self writes failed: \(result.failed.count)") }
        } catch {
            Self.log.error("self store: \(String(describing: error), privacy: .public)")
        }
    }

    /// On background / sleep / quit: everything learnt so far goes to disk.
    func flush(at now: Date = Date()) async -> [Effect] {
        let rest = absorb(cortex.flush(at: now))
        await save()
        return rest
    }

    // MARK: - People and forgetting (Cortex first, then pending writes, then stores)

    func merge(from: UUID, into: UUID, memory: MemoryStore) async {
        cortex.merge(from: from, into: into)
        await save()
        await memory.merge(from, into: into)
        try? await store.merge(from: from, into: into)
    }

    func forgetPerson(_ id: UUID, memory: MemoryStore, placeholder: Bool) async {
        cortex.forgetPerson(id)
        await save()
        if placeholder { await memory.discardPlaceholder(id) } else { await memory.forgetPerson(id) }
        _ = try? await store.forgetPerson(id)
    }

    func forgetEverything(memory: MemoryStore) async {
        cortex.forgetAll()
        pending.removeAll()
        await memory.forgetEverything()
        try? await store.forgetAll()
    }
}
