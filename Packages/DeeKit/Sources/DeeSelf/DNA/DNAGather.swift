import DeeCore
import DeeMemory
import DeeMind
import Foundation

/// Everything `DNAInputs` needs that Cortex does not hold (RealtimeBrain / DeeModel / Mind).
public struct DNAContext: Sendable, Equatable {
    public var aging: AgingInputs
    public var inner: InnerStateCounters
    public var rings: DNARings
    public var body: BodyInputs
    public var daily: [DNADay]
    public var shareMemories: Bool
    /// RAM only, for the 5-gram guard (loose strings; prefer `guardCorpus`).
    public var userTextCorpus: [String]
    /// RAM only: add each user transcript once with `guardCorpus.add(_:)` (§2.7).
    public var guardCorpus: DNAGuardCorpus

    public init(aging: AgingInputs = AgingInputs(), inner: InnerStateCounters = InnerStateCounters(), rings: DNARings = DNARings(),
                body: BodyInputs = BodyInputs(), daily: [DNADay] = [], shareMemories: Bool = true, userTextCorpus: [String] = [],
                guardCorpus: DNAGuardCorpus = DNAGuardCorpus()) {
        self.aging = aging
        self.inner = inner
        self.rings = rings
        self.body = body
        self.daily = daily
        self.shareMemories = shareMemories
        self.userTextCorpus = userTextCorpus
        self.guardCorpus = guardCorpus
    }
}

extension Cortex {
    /// §1.6 — up to 3 shared memories with `person`: indexed episodes whose gist is citable,
    /// not recalled by NotePicker within its cooldown, ranked by salience × 0.5^(age / 14 d).
    /// (Boundary topics are filtered by the assembler.)
    public func episodeLines(person: PersonID?, at now: Date) -> [EpisodeLine] {
        guard let person else { return [] }
        let gists = episodeBuilder.gists
        let recalled = picker.recalledEpisodes
        return moment.enduring.episodeIndex
            .filter { k in
                k.person == person && gists[k.id] != nil
                    && (recalled[k.id].map { now.timeIntervalSince($0) >= NotePicker.recallSameEpisodeCooldown } ?? true)
            }
            .map { k in (k, k.salience * pow(0.5, max(0, now.timeIntervalSince(k.end)) / (14 * 86_400))) }
            .sorted { ($0.1, $1.0.id.uuidString) > ($1.1, $0.0.id.uuidString) }
            .prefix(DNALimits.episodes)
            .map { k, _ in EpisodeLine(id: k.id, gist: gists[k.id] ?? "", daysAgo: Int(now.timeIntervalSince(k.end) / 86_400), valence: 0) }
    }

    /// The `DNAInputs` for the next response. Call `cue(at:)` first (it picks the notes
    /// into `stance` and returns their bookkeeping effects, which the app executes).
    public func dnaInputs(at now: Date, memories person: PersonInputs?, turn: TurnContext,
                          appraisal: TurnAppraisal = TurnAppraisal(), context c: DNAContext = DNAContext()) -> DNAInputs {
        // §4 "last talked …": the contact before this conversation (tune 3). The host's
        // `lastContact` (`PersonInputs.lastSeen`) and `lastUserTurnAt` are refreshed by
        // the conversation itself, so a reunion after 50 h read "last talked just now".
        // A first meeting has none: no "last talked" line at all (never "just now").
        var body = c.body
        var person = person
        if let who = person?.id ?? moment.ongoing.person {
            body.lastContact = lastContactBeforeConversation(who)
            if body.lastContact == nil { person?.lastSeen = nil }
        }
        return DNAInputs(now: now, utcOffset: utcOffset, turn: turn, mind: moment.ongoing.mind, aging: c.aging, inner: c.inner,
                  moodHistory: c.rings.history, causes: c.rings.causes, moment: moment, stance: stance,
                  episodes: episodeLines(person: person?.id ?? moment.ongoing.person, at: now), person: person, body: body,
                  appraisal: appraisal, daily: c.daily, shareMemories: c.shareMemories, userTextCorpus: c.userTextCorpus,
                  guardCorpus: c.guardCorpus)
    }

    /// The Dee DNA snapshot for the next response (see `dnaInputs`).
    public func dna(at now: Date, memories person: PersonInputs?, turn: TurnContext,
                    appraisal: TurnAppraisal = TurnAppraisal(), context: DNAContext = DNAContext()) -> DeeDNA {
        DNAAssembler.assemble(dnaInputs(at: now, memories: person, turn: turn, appraisal: appraisal, context: context))
    }

    /// Snapshot + render with the context's corpus for the guard.
    public func dnaRender(at now: Date, memories person: PersonInputs?, turn: TurnContext,
                          appraisal: TurnAppraisal = TurnAppraisal(), context: DNAContext = DNAContext(),
                          budget: DNABudget = .standard) -> DNARender {
        DNAPrompt.build(dnaInputs(at: now, memories: person, turn: turn, appraisal: appraisal, context: context), budget: budget)
    }
}
