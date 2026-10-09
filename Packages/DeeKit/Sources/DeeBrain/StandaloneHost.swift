import DeeCore
import DeeMemory
import DeeMind
import DeeSelf
import Foundation

/// A complete `BrainHost` without the app: a real `Mind`, a real `Cortex` and,
/// optionally, a real `MemoryStore` — for the macOS voice harness and the tests.
/// It does what DeeModel does on the speech path (commands, "is this for me?",
/// Mind preview → Cortex.adjust → commit → `.heard`, the DNA inputs), with the
/// body state as plain settable flags.
@MainActor
public final class StandaloneHost: BrainHost {
    public let mind: Mind
    public private(set) var cortex: Cortex
    public let memory: MemoryStore?
    public var person: PersonID?
    public weak var brain: RealtimeBrain?

    // Body (what the camera and the app would know)
    public var engaged = true
    public var asleep = false
    public var someoneHere = true
    public var shareMemories = true
    public var extraNotes: [String] = []

    // What happened (for the harness and tests)
    public private(set) var heardLog: [(text: String, verdict: HeardVerdict)] = []
    public private(set) var wordsFailedCount = 0
    public private(set) var commands: [SpokenCommand] = []
    public private(set) var replies: [[ReplyEvent]] = []
    public private(set) var said: [String] = []
    public private(set) var thinkingOn = false
    public private(set) var dnaRequests: [DNARequest] = []
    public private(set) var voiceBaseline = Appraiser.VoiceBaseline()
    private var snapshot: MindSnapshot
    private var speakingUntil = Date.distantPast

    /// - Parameters:
    ///   - mind: e.g. `try Mind(databaseURL: nil)`; `mind.restore(code)` sets a state.
    ///   - seed: the enduring self's seed (`SelfSeeder`).
    public init(mind: Mind, memory: MemoryStore? = nil, person: PersonID? = nil, seed: UInt64 = 7,
                at now: Date = Date(), utcOffset: TimeInterval = TimeInterval(TimeZone.current.secondsFromGMT())) async {
        self.mind = mind
        self.memory = memory
        self.person = person
        let snap = await mind.snapshot(at: now)
        snapshot = snap
        let enduring = SelfSeeder.seed(personality: snap.code.personality, seed: seed, at: now)
        cortex = Cortex(enduring: enduring, mind: snap, at: now, utcOffset: utcOffset)
        voiceBaseline = await mind.voiceBaseline
        _ = cortex.step(.conversationStarted(now), mind: snap, at: now)
        if let person { _ = cortex.step(.identified(person, distance: 0), mind: snap, at: now) }
        _ = cortex.step(.presence(arrived: true), mind: snap, at: now)
    }

    /// Steps the Cortex with a percept (effects other than persistence are returned).
    @discardableResult
    public func sense(_ p: Percept, at now: Date = Date()) -> [Effect] {
        let effects = cortex.step(p, mind: snapshot, at: now).filter { if case .persist = $0 { false } else { true } }
        if effects.contains(where: { if case .initiative = $0 { true } else { false } }) {
            // Its aim lives in this step's Stance only; keep it for the initiative's DNA.
            initiativeNotes = cortex.stance.notes
            initiatives += 1
        }
        return effects
    }

    /// The notes a Cortex initiative issued (for its DNA), and how many there were.
    public private(set) var initiativeNotes: [Note]?
    public private(set) var initiatives = 0

    /// Replaces the Mind's state (archetypes in the harness).
    public func restore(_ code: MindCode, at now: Date = Date()) async {
        await mind.restore(code, at: now)
        snapshot = await mind.snapshot(at: now)
        sense(.tick, at: now)
    }

    // MARK: BrainHost

    public var answersOnCommit: Bool { engaged && !asleep }

    public func modeSignals(at now: Date) -> CueModeSignals {
        CueModeSignals(moment: cortex.moment, identified: person != nil, at: now)
    }

    public func heard(_ turn: HeardTurn) async -> HeardVerdict {
        let now = Date()
        if case .voice = turn.source {
            let talking = now < speakingUntil || turn.replyRequested
            if let c = SpokenCommand.match(turn.text, deeIsTalking: talking) {
                commands.append(c)
                if c == .stop || c == .sleep { await brain?.cancel() }
                if c == .sleep { asleep = true }
                heardLog.append((turn.text, .handled))
                return .handled
            }
            if !answersOnCommit {
                guard SpokenCommand.addressesDee(turn.text) else {
                    heardLog.append((turn.text, .ignored))
                    return .ignored
                }
                asleep = false
                engaged = true
            }
        }
        let before = snapshot.code
        let cortex = self.cortex
        let (appraisal, snap) = await mind.hear(turn.text, prosody: turn.prosody, at: now, adjust: { cortex.adjust($0) })
        snapshot = snap
        voiceBaseline = await mind.voiceBaseline
        brain?.noteMind(appraisal, before: before, after: snap.code, at: now)
        let loudness = turn.prosody.map { ($0.loudnessDB + 32) / 12 } ?? 0
        sense(.heard(text: turn.text, durationS: turn.duration, loudnessVsBaseline: loudness, appraisal: appraisal), at: now)
        heardLog.append((turn.text, .answer(appraisal)))
        return .answer(appraisal)
    }

    public func wordsFailed() { wordsFailedCount += 1 }

    public func dnaParts(_ r: DNARequest) async -> DNAParts? {
        dnaRequests.append(r)
        let now = r.now
        if r.pickNotes {
            sense(.promptSubmitted, at: now)
            _ = cortex.cue(at: now)
        }
        var personInputs: PersonInputs?
        if let id = person, let memory, let p = await memory.person(id) {
            let lines = shareMemories ? await memory.promptMemories(for: id, limit: 9, now: now) : []
            personInputs = PersonInputs(person: p, promptMemories: lines)
        }
        let state = await mind.state
        let days = await mind.history(days: 30).map { DNADay(day: $0.day, interactions: $0.interactions, regard: $0.regard) }
        let body = BodyInputs(someoneHere: someoneHere, asleep: asleep, lastUserTurnAt: r.lastUserTurnAt,
                              lastContact: personInputs?.lastSeen)
        let context = DNAContext(aging: AgingInputs(state.age), inner: InnerStateCounters(state), rings: r.rings, body: body,
                                 daily: days, shareMemories: shareMemories, guardCorpus: r.corpus)
        var inputs = cortex.dnaInputs(at: now, memories: personInputs, turn: r.turn, appraisal: r.appraisal, context: context)
        // A Cortex initiative's own aim (only for that initiative's DNA; a DNA
        // re-rendered after `forget` or for a retry must not take it).
        if r.turn.kind == .initiative, !r.pickNotes {
            if let issued = initiativeNotes { inputs.stance.notes = issued }
            initiativeNotes = nil
        }
        let notes = extraNotes
        extraNotes = []
        return DNAParts(inputs: inputs, extraNotes: notes)
    }

    public func brainStartedReply(_ reply: BrainReply) {
        consume(reply.events)
    }

    /// Consumes a reply stream the way DeeModel does (deeSaid per heard sentence).
    public func consume(_ events: AsyncThrowingStream<ReplyEvent, Error>) {
        let index = replies.count
        replies.append([])
        Task { @MainActor in
            do {
                for try await e in events {
                    self.replies[index].append(e)
                    switch e {
                    case .content:
                        self.speakingUntil = Date().addingTimeInterval(3)
                    case .sentenceFinished(let s, let heard) where heard:
                        self.said.append(s)
                        self.sense(.deeSaid(tag: nil, sentence: s))
                    case .turnCompleted:
                        self.sense(.deeTurnFinished(text: ""))
                    default:
                        break
                    }
                }
            } catch {}
        }
    }

    public func thinkingModeChanged(_ on: Bool) { thinkingOn = on }
}
