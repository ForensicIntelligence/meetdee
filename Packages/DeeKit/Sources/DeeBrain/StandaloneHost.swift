import DeeCore
import DeeMemory
import DeeMind
import DeeSelf
import DeeWake
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

    // The conversation window (v0.6, providers-wake-onboarding §4). The one rule every
    // host shares: an open window means Dee is engaged and addressed; outside one,
    // nothing is answered — and no server transcript (Dee's name included) ever opens it.
    /// `.alwaysOpen`: the window never closes (the harness's 28-scenario baseline, the
    /// brain tests). `.phrase`: it opens only through `window(_:)` inputs (the local
    /// wake ear, a tap, a greeting) and closes on its own rules.
    public enum WakeMode: String, Sendable, Equatable { case alwaysOpen, phrase }
    public var wakeMode: WakeMode = .alwaysOpen
    public private(set) var window = ConversationWindow()
    /// Every action the window asked for, in order (the harness executes them).
    public private(set) var windowActions: [ConversationWindow.Action] = []
    /// Called with each input's actions (the harness connects / sleeps its voice).
    public var onWindowActions: ((@MainActor ([ConversationWindow.Action]) -> Void))?
    /// Monotonic seconds for the window (tests set a fake clock).
    public var monotonic: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The current wake phrase: commands may follow it ("Computer, go to sleep").
    public var wakePhrase = WakePhrase.default
    /// Who the host speaks as (the session instructions: `DNAPrompt.sessionInstructions(preset:)`).
    public private(set) var persona = PersonaCatalog.classic
    /// "Change your wake phrase to X" waiting for a yes.
    public private(set) var phraseChange = WakePhraseChange()

    /// Feeds the window and returns (and publishes) its actions.
    @discardableResult
    public func window(_ input: ConversationWindow.Input, now: TimeInterval? = nil) -> [ConversationWindow.Action] {
        guard wakeMode == .phrase else { return [] }
        let actions = window.handle(input, now: now ?? monotonic())
        windowActions += actions
        if !actions.isEmpty { onWindowActions?(actions) }
        return actions
    }

    /// Whether the window lets Dee answer at all (always, in `.alwaysOpen`).
    public var windowAnswers: Bool { wakeMode == .alwaysOpen || Engagement.answers(window: window.state) }

    // What happened (for the harness and tests)
    public private(set) var heardLog: [(text: String, verdict: HeardVerdict)] = []
    public private(set) var wordsFailedCount = 0
    public private(set) var commands: [SpokenCommand] = []
    /// Dee's answers to "change your wake phrase" (what Dee would say), and the outcomes.
    public private(set) var phrasePrompts: [WakePhraseChange.Prompt] = []
    public private(set) var phraseOutcomes: [WakePhraseChange.Outcome] = []
    public private(set) var replies: [[ReplyEvent]] = []
    public private(set) var said: [String] = []
    public private(set) var thinkingOn = false
    public private(set) var dnaRequests: [DNARequest] = []
    public private(set) var voiceBaseline = Appraiser.VoiceBaseline()
    private var snapshot: MindSnapshot
    private var speakingUntil = Date.distantPast

    /// - Parameters:
    ///   - mind: e.g. `try Mind(databaseURL: nil)`; `mind.restore(code)` sets a state.
    ///   - seed: the enduring self's seed (`SelfSeeder`); a persona preset uses its own.
    ///   - persona: who the host speaks as. Classic Dee (the default) keeps every tuned
    ///     harness golden; a preset is applied to `mind` and seeds the self from itself.
    public init(mind: Mind, memory: MemoryStore? = nil, person: PersonID? = nil, seed: UInt64 = 7,
                persona: PersonaPreset = PersonaCatalog.classic,
                at now: Date = Date(), utcOffset: TimeInterval = TimeInterval(TimeZone.current.secondsFromGMT())) async {
        self.mind = mind
        self.memory = memory
        self.person = person
        if !persona.isClassic { await mind.apply(persona, at: now) }
        let snap = await mind.snapshot(at: now)
        snapshot = snap
        let enduring = persona.isClassic ? SelfSeeder.seed(personality: snap.code.personality, seed: seed, at: now)
            : SelfSeeder.seed(preset: persona, fallbackSeed: seed, at: now)
        cortex = Cortex(enduring: enduring, mind: snap, at: now, utcOffset: utcOffset)
        cortex.identity = persona
        self.persona = persona
        if !persona.isClassic { wakePhrase = (try? WakePhrase(validating: persona.wakePhraseDefault)) ?? .default }
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

    public var answersOnCommit: Bool { windowAnswers && engaged && !asleep }

    /// Replaces the Cortex's exact-mode signals (tests and the harness: force a
    /// turn that waits for its words).
    public var modeSignalsOverride: CueModeSignals?

    public func modeSignals(at now: Date) -> CueModeSignals {
        modeSignalsOverride ?? CueModeSignals(moment: cortex.moment, identified: person != nil, at: now)
    }

    public func heard(_ turn: HeardTurn) async -> HeardVerdict {
        let now = Date()
        if case .voice = turn.source {
            // Outside a window nothing is for Dee — not even Dee's name in a server
            // transcript (W1: only the on-device ear wakes Dee).
            guard windowAnswers else {
                heardLog.append((turn.text, .ignored))
                return .ignored
            }
            let talking = now < speakingUntil || turn.replyRequested
            if let outcome = phraseChange.answer(turn.text, current: wakePhrase, at: now) {
                if case .saved(let p, _) = outcome { wakePhrase = p }
                phraseOutcomes.append(outcome)
                heardLog.append((turn.text, .handled))
                window(.acceptedTurn)
                return .handled
            }
            let matcher = WakeMatcher(wakePhrase)
            if let c = SpokenCommand.match(turn.text, deeIsTalking: talking, stripLeading: { matcher.stripLeading($0) },
                                           names: persona.isClassic ? [] : persona.addressingWords) {
                commands.append(c)
                // DeeModel: `stop(hush: true)` — Dee's voice and the brain, hushed.
                if c == .stop || c.closesWindow { stopSpeaking(hush: true) }
                if c == .sleep { asleep = true }
                if case .changeWakePhrase(let raw) = c {
                    phrasePrompts.append(phraseChange.propose(raw, current: wakePhrase, at: now))
                    window(.acceptedTurn)
                }
                if c.closesWindow { window(.closeCommand) }
                heardLog.append((turn.text, .handled))
                return .handled
            }
            guard answersOnCommit else {
                heardLog.append((turn.text, .ignored))
                return .ignored
            }
            window(.acceptedTurn)
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

    /// Barge-ins the brain sensed from its own answer (`BrainHost.bargedIn`).
    public private(set) var bargeIns = 0
    /// Stops run (a stop command, or a Cortex `.stopSpeaking`), as DeeModel's `stop()`.
    public private(set) var stops = 0

    /// As DeeModel: the Cortex senses `.bargeInAnswered` and its effects run — a
    /// `.stopSpeaking` would stop Dee as the app's `stop()` does (tune 5 F1: with
    /// `.bargeIn` it did, and cancelled the very answer to the barge-in).
    public func bargedIn() {
        bargeIns += 1
        for e in sense(.bargeInAnswered) {
            if case .stopSpeaking = e { stopSpeaking(hush: false) }
        }
    }

    /// DeeModel's `stop(hush:)` on the brain: Dee's voice stops and the brain cancels.
    public func stopSpeaking(hush: Bool) {
        stops += 1
        guard let brain else { return }
        brain.stopVoice()
        Task { await brain.cancel(hush: hush) }
    }
}
