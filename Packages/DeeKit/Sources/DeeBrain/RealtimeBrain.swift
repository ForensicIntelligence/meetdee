import DeeCore
import DeeMind
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation

/// Dee's brain on the OpenAI realtime session (design B4): the one consumer of
/// `CloudVoice.brainEvents`, and the app's `ReplyEngine`.
///
/// **When she answers.** The server commits each user utterance; the brain decides
/// (`TurnPolicy.onCommit`):
/// - engaged and awake → the Dee DNA is built at once from the current state and
///   this turn's local prosody and the reply is requested (fast mode, docs/DNA.md §4.3);
///   or, when the words change the right answer (repair, a loud voice, a pending
///   follow-up, a stated mood, a stranger's first turn, speech right after her voice
///   — maybe "stop"), it waits ≤ 0.4 s for the transcript and runs the full path
///   first (exact mode);
/// - asleep or nobody engaged → it waits for the words, and only answers if the host
///   says they were for her (her name wakes her). A TV is never answered.
///
/// Every transcript goes to the host (`BrainHost.heard`: commands, people, Mind,
/// Cortex) and into the 5-gram guard corpus. Commands are never answered.
///
/// **What she is told.** Before every reply and initiative the brain renders the Dee
/// DNA (`DNAPrompt`) and hands it to the session with the request
/// (`requestResponse(dna:)`, `initiative(dna:)`): the session gives it an id,
/// deletes the previous one (exactly one DNA in context, §4.1) and, if the server
/// refuses it, holds the response back and resends it behind the previous DNA — no
/// response ever runs without one. Tool follow-ups and the session's own
/// re-requests reuse the live DNA; after `forget` and on a preempted reply the
/// brain replaces it first (`replaceDNA`). Per-response `instructions` are never
/// used for replies or initiatives (D6).
///
/// **What she said.** Her transcript reaches the app per sentence as playback
/// passes it (`ReplyEvent.sentenceFinished(heard:)` → `Percept.deeSaid`).
///
/// It never calls `stopSpeaking` on the user-utterance path (except to take back an
/// unheard reply to speech that turned out not to be for her), never re-requests on
/// `.replyPreempted` (the session does that itself after an echo; the brain only
/// renders a fresh `retry` DNA for it), and closes the floor when a transcript fails.
///
/// **What she remembers.** Speech that was not for her is deleted from the realtime
/// conversation and its history (`dropUserItem`), and a new conversation resets
/// both (`resetConversation`). Canned lines (`say`) go out of band
/// (`RealtimeSession.say`). Turns she deliberately leaves unanswered (a command,
/// "hold on") are released (`userTurnHandled`) so they never hold a rollover.
///
/// **Unfinished turns.** The server ends turns at `high` eagerness (plain turns end
/// fast); a turn whose words say they are not done ("Hold on.", "…and") is not
/// answered: an unheard reply to it is taken back and the next commit answers
/// both (`TurnPolicy.unfinished`).
///
/// **Her voice.** Requests go to the session directly (CloudVoice has no DNA entry
/// point yet). What CloudVoice's own `respond` / `initiative` did around a request
/// is done here: a reply still playing is cut first; a request never goes out
/// within `stopGuard` of a stop the brain or app made (CloudVoice's reply gate keeps
/// a response that starts within 0.25 s of a stop silent, and the stop's cancel
/// must reach the session first); the timeline gets its `response_create_sent`
/// mark; an initiative or canned line is refused while the user talks or her voice
/// plays, and taken back if the user starts before its first audio.
@MainActor
public final class RealtimeBrain: ReplyEngine {
    public struct Options: Sendable {
        public var exactWait: TimeInterval = TurnPolicy.exactWait
        public var waitBeforeAnswering: TimeInterval = TurnPolicy.waitBeforeAnswering
        /// A channel whose response is done but whose audio never reported back is
        /// closed after this (never while one of its items is still playing).
        public var channelTail: TimeInterval = 20
        /// …and after this even while playing (a stuck player).
        public var channelMax: TimeInterval = 300
        /// An utterance waiting for the "is this for me?" check is given up after this.
        public var addressWait: TimeInterval = TurnPolicy.addressWait
        /// After a tool round with no follow-up started, close the channel after this.
        public var toolFollowUpWait: TimeInterval = 4
        /// Housekeeping period.
        public var tick: TimeInterval = 0.05
        /// No request goes out sooner than this after a stop of her voice (see
        /// "Her voice"). Above CloudVoice's 0.25 s reply-gate guard.
        public var stopGuard: TimeInterval = 0.3
        /// A trailing turn ("…and") is answered after this much quiet.
        public var trailingWait: TimeInterval = TurnPolicy.trailingWait
        /// A riddle's set-up is answered after this much quiet.
        public var riddleWait: TimeInterval = TurnPolicy.riddleWait
        /// Speech over her voice waits this long for its first settled words.
        public var overlapWait: TimeInterval = TurnPolicy.overlapWait
        /// Transcription deltas are taken as the turn's words after this much quiet.
        public var partialSettle: TimeInterval = TurnPolicy.partialSettle
        /// An item in the voice's floor hold is not answered blind for this long after
        /// its commit (the voice settles a hold within ~6.5 s: `pauseHoldMax`).
        public var holdLimit: TimeInterval = 6.5
        /// Per-response `max_output_tokens` sized to the DNA `Length:` line (tune 2).
        public var capReplyTokens = true
        public init() {}
    }

    /// Reasoning effort for ordinary turns (thinking mode off): tune 3. Live tune 2,
    /// the model's time to first audio followed its reasoning tokens (create → first
    /// audio p50 / p90: 0 tokens 0.44 / 0.45 s; 1–39 0.58 / 0.70; 40–99 0.72 / 0.92;
    /// 100–199 1.06 / 1.33; 200+ 1.64 / 1.76 s at `low`), not the DNA size (≤ 2.5k
    /// input tokens p90 1.06 s, > 3k 1.33 s). Thinking mode keeps its own effort.
    public nonisolated static let ordinaryEffort: ReasoningEffort = .minimal

    /// `ThinkingMode`'s chat effort becomes `ordinaryEffort`; thinking efforts stay.
    nonisolated static func effective(_ e: ReasoningEffort) -> ReasoningEffort {
        e == ThinkingMode.chatEffort ? ordinaryEffort : e
    }

    public let voice: CloudVoice
    private var session: RealtimeSession { voice.session }
    public let prosody: ProsodyTap
    public weak var host: (any BrainHost)?
    public private(set) var toolbox: BrainToolbox
    public let options: Options
    private let clock: @Sendable () -> Date

    // Conversation state (RAM only)
    private var thinking = ThinkingMode()
    private var rings = DNARings()
    private var corpus = DNAGuardCorpus()
    private var lastUserTurnAt: Date?
    private var responseIndex = 0
    private var lastDNANotes: Set<Note.Kind> = []
    private var lastMode: CueMode = .fast
    /// The last DNA's `Voice:` line (for canned lines, §4.2).
    private var lastVoiceWords: String?
    private var lastInitiativeDirective: String?
    private var toolsRunning = 0
    private var lastPlaybackAt: Date?
    /// The last stop of her voice (brain or app): requests wait out `stopGuard`.
    private var lastStopAt: Date?
    /// An initiative or canned line sent and not yet audible: the user starting
    /// first takes it back.
    private var speakFirst: Int?
    public private(set) var connected = false

    // Utterances the brain still has to decide about
    private struct Utterance {
        var item: String
        var plan: TurnPolicy.OnCommit
        var committedAt: Date
        var deadline: Date?
        var requested = false
        var effort: ReasoningEffort = .low
        var heard = false
        var channel: Int?
        /// For a retry after a refused request: what exact mode knew.
        var text: String?
        var appraisal: Appraisal?
        var mode: CueMode = .fast
        /// Unfinished ("…and"): waits for the rest until `deadline`.
        var held = false
        /// `waitForPartial`: its settled first words were looked at.
        var partialDecided = false
        /// Its words were a backchannel ("keep going"): not a turn of its own.
        var backchannel = false
    }
    private var utterances: [String: Utterance] = [:]
    private var speechStartedAt: [String: Date] = [:]
    /// Speech that started while her voice was playing (a barge-in).
    private var startedOverHerVoice: Set<String> = []
    /// An utterance whose reply could not go out (a response was in flight).
    private var retryItem: String?
    /// Transcription deltas so far per user item, and when the last one came (the
    /// turn's provisional words once settled, ~0.2 s before the full transcript).
    private var partials: [String: (text: String, at: Date)] = [:]
    private var partialsChecked: Set<String> = []
    /// The newest committed user item.
    private var lastCommittedItem: String?
    /// Her reply transcript so far per item, while its first words are checked for
    /// a spoken preamble; items done with that check.
    private var replyOpenings: [String: String] = [:]
    private var openingsChecked: Set<String> = []
    /// Her items with a narrated later sentence: she stops when it starts playing.
    private var narrationItems: Set<String> = []
    /// User items whose reply was already cut once for a preamble (never twice).
    private var preambleRetried: Set<String> = []
    /// Her items whose response hit `max_output_tokens`: playback stops before
    /// their unfinished last sentence.
    private var tokenLimited: Set<String> = []
    /// The sentence of each item playing now.
    private var currentSentence: [String: String] = [:]
    /// A backchannel she talked on through, and when: if her voice is cut right
    /// after anyway (a barge-in decided on the sound), she carries on.
    private var continuedThrough: (item: String, at: Date)?

    // Responses and their channels
    private struct Channel {
        var continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation
        var responseIDs: Set<String> = []
        var items: Set<String> = []
        var pending: Set<String> = []
        var heard: [String: [String]] = [:]
        var done = false
        var doneAt: Date?
        var calledTools = false
        var toolWaitUntil: Date?
        var item: String?
        /// A canned line (`say`): not a reply, never handed to the host.
        var aside = false
        /// Cut for a spoken preamble: the user item to answer again when it ends.
        var preambleRetry: String?
    }
    private var channels: [Int: Channel] = [:]
    private var nextChannel = 0
    /// Requests sent whose `.responseStarted` has not come yet, oldest first.
    private var awaiting: [Int] = []
    /// The channel of the response generating now.
    private var generating: Int?
    private var lastBound: Int?
    private var itemChannel: [String: Int] = [:]
    private var playing: Set<String> = []
    private var herVoiceEndedAt: Date?

    // Plumbing
    private enum Input {
        case brain(CloudVoice.BrainEvent)
        case hold(CloudVoice.HoldEvent)
        case tick
        case request(ReplyRequest, Int)
        case cancel(hush: Bool, at: Date)
    }
    private let inputs: AsyncStream<Input>
    private let feed: AsyncStream<Input>.Continuation
    private var loop: Task<Void, Never>?
    private var pumps: [Task<Void, Never>] = []

    /// What happened, without any text (debug traces, tests, the harness).
    public private(set) var trace: [BrainTrace] = []
    public var onTrace: ((BrainTrace) -> Void)?

    public init(voice: CloudVoice, host: (any BrainHost)?, toolbox: BrainToolbox = BrainToolbox(tools: []),
                prosody: ProsodyTap? = nil, options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.voice = voice
        self.host = host
        self.toolbox = toolbox
        self.prosody = prosody ?? ProsodyTap(graph: voice.graph)
        self.options = options
        self.clock = clock
        (inputs, feed) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Source compatibility for the old wiring: the wire is a pass-through now.
    @available(*, deprecated, message: "RealtimeSession carries the DNA itself; drop the wire.")
    public convenience init(voice: CloudVoice, wire: DNAWire, host: (any BrainHost)?, toolbox: BrainToolbox = BrainToolbox(tools: []),
                            prosody: ProsodyTap? = nil, options: Options = Options(),
                            clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(voice: voice, host: host, toolbox: toolbox, prosody: prosody, options: options, clock: clock)
    }

    /// Sets the session up (stable instructions, tools, tool handler) and starts
    /// consuming the voice's brain events. Call before `voice.start()`.
    public func start() async {
        guard loop == nil else { return }
        await voice.session.updateSession(instructions: DNASessionInstructions.current, tools: toolbox.realtimeTools)
        await voice.session.setToolHandler { [weak self] call in
            guard let self else { return RealtimeToolResult(output: "Error: unavailable", followUp: .never) }
            return await self.runTool(call)
        }
        let events = voice.brainEvents
        let feed = self.feed
        pumps.append(Task { for await e in events { feed.yield(.brain(e)) } })
        let holds = voice.holdEvents
        pumps.append(Task { for await e in holds { feed.yield(.hold(e)) } })
        let period = options.tick
        pumps.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(period))
                feed.yield(.tick)
            }
        })
        loop = Task { [weak self] in
            guard let stream = self?.inputs else { return }
            for await input in stream {
                guard let self else { return }
                await self.handle(input)
            }
        }
    }

    /// Stops the loops (the voice is shut down separately).
    public func stop() {
        pumps.forEach { $0.cancel() }
        pumps.removeAll()
        loop?.cancel()
        loop = nil
        feed.finish()
        for (_, c) in channels { c.continuation.finish() }
        channels.removeAll()
    }

    /// Replaces the tools (the "share memories" setting changed). Costs one cache miss.
    public func setToolbox(_ box: BrainToolbox) async {
        toolbox = box
        await voice.session.updateSession(tools: box.realtimeTools)
    }

    /// The app went to the background: the guard corpus and the prosody frames go.
    public func backgrounded() {
        corpus.removeAll()
        prosody.reset()
        utterances.removeAll()
    }

    /// Something is in progress: words awaited or a reply not finished.
    public var isBusy: Bool {
        utterances.values.contains { !$0.requested && $0.plan != .waitForAddress } || channels.values.contains { !$0.done }
    }

    public var thinkingIsOn: Bool { thinking.isOn }

    /// The debug toggle.
    public func setThinking(_ on: Bool) {
        thinking.set(on)
        host?.thinkingModeChanged(on)
    }

    // MARK: Mind rings (§1.4) — the host reports what it fed the Mind

    /// After `Mind.hear/commit/react/catchUp`: the cause ring.
    public func noteMind(_ appraisal: Appraisal, before: MindCode, after: MindCode, at now: Date? = nil) {
        rings.record(appraisal, before: before, after: after, at: now ?? clock())
    }

    /// A cause without an appraisal (`time alone`, `rest` after `catchUp`).
    public func noteCause(_ label: CauseLabel, before: MindCode, after: MindCode, at now: Date? = nil) {
        rings.record(CauseEntry(at: now ?? clock(), label: label, before: before, after: after))
    }

    /// A `Mind.tick` result (kept at most every 30 s).
    public func noteMood(_ code: MindCode, at now: Date? = nil) {
        rings.sample(code, at: now ?? clock())
    }

    public var dnaRings: DNARings { rings }
    public var guardCorpus: DNAGuardCorpus { corpus }

    // MARK: ReplyEngine

    public nonisolated func respond(_ request: ReplyRequest, state: String?, effort: ReasoningEffort) -> AsyncThrowingStream<ReplyEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ReplyEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        Task { @MainActor [weak self] in
            guard let self else { continuation.finish(); return }
            let id = self.openChannel(continuation)
            self.feed.yield(.request(request, id))
        }
        return stream
    }

    /// A barge-in or a stopped reply: her voice stops; the user's own utterances
    /// (the one that interrupted her above all) are still answered.
    public func cancel() async {
        await cancel(hush: false)
    }

    /// - Parameter hush: the user asked for quiet (palm, "stop"): utterances they
    ///   finished before this are not answered either (later ones are).
    public func cancel(hush: Bool) async {
        stopVoice()
        feed.yield(.cancel(hush: hush, at: clock()))
    }

    /// Stops her voice (`CloudVoice.stopSpeaking`) and notes when, so the next
    /// request waits out `stopGuard`. The app calls this instead of stopping the
    /// voice itself.
    public func stopVoice() {
        voice.stopSpeaking()
        lastStopAt = clock()
    }

    /// A new conversation: counters reset, and the realtime conversation is cleared
    /// (everything but the live DNA and the turn being answered), so the old talk is
    /// neither in context nor in a later rollover's summary or seed.
    public func newConversation(persona: Persona, now: Date) async {
        thinking = ThinkingMode()
        responseIndex = 0
        lastUserTurnAt = nil
        lastDNANotes = []
        lastMode = .fast
        // The turn being answered (or about to be) stays; everything before it goes.
        var keep = Set(utterances.filter { !$0.value.requested || $0.value.channel.map { channels[$0] != nil } == true }.keys)
        for c in channels.values where !c.done {
            if let i = c.item { keep.insert(i) }
            keep.formUnion(c.items)
        }
        await session.resetConversation(keeping: keep)
    }

    /// The outcome of a canned line.
    public enum SayOutcome: Sendable, Equatable {
        /// Every sentence of it was played.
        case played
        /// It started but was cut (or nothing of it was heard).
        case cut
        /// It never went out (not connected, the user talking, she is speaking…).
        case refused(String)
    }

    /// A verbatim line in her session voice ("Okay. Goodnight!", the AI-voice
    /// disclosure): out of band, no context, the last DNA's `Voice:` words
    /// (docs/DNA.md §4.2). It is not a reply: the host is not told about it.
    /// Returns once it has played out (or was cut or refused).
    public func say(_ line: String) async -> SayOutcome {
        guard connected else { return .refused("not connected") }
        let (stream, continuation) = AsyncThrowingStream<ReplyEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let id = openChannel(continuation)
        channels[id]?.aside = true
        awaiting.append(id)
        let quoted = line.replacingOccurrences(of: "\"", with: "'")
        var instructions = "Say exactly this, word for word, in your own voice, and nothing else: \"\(quoted)\""
        if let words = lastVoiceWords, !words.isEmpty { instructions += "\n" + words }
        let text = instructions
        let outcome = await speakFirst(channel: id, kind: "say") { session in
            await session.say(instructions: text, maxOutputTokens: 400)
        }
        if case .refused(let why) = outcome {
            awaiting.removeAll { $0 == id }
            finish(id)
            record(.requestFailed("say: \(why)"))
            return .refused("\(why)")
        }
        var total = 0, heard = 0
        do {
            for try await e in stream {
                if case .sentenceFinished(_, let h) = e {
                    total += 1
                    if h { heard += 1 }
                }
            }
        } catch {}
        return total > 0 && heard == total ? .played : .cut
    }

    /// Tests: an event as if CloudVoice had sent it (it is handled in order with
    /// the real ones).
    func inject(_ e: CloudVoice.BrainEvent) {
        feed.yield(.brain(e))
    }

    /// Tests: a hold event as if CloudVoice had sent it.
    func injectHold(_ e: CloudVoice.HoldEvent) {
        feed.yield(.hold(e))
    }

    // MARK: The loop

    private func handle(_ input: Input) async {
        switch input {
        case .brain(let e): await handleBrain(e)
        case .hold(let e): await handleHold(e)
        case .tick: await housekeeping()
        case .request(let r, let id): await serve(r, channel: id)
        case .cancel(let hush, let at):
            // A barge-in never drops the turn that caused it (its commit may arrive
            // just before or after this). A hush drops what was finished before it.
            guard hush else { return }
            let dropped = utterances.filter { !$0.value.requested && $0.value.committedAt <= at }.keys
            utterances = utterances.filter { $0.value.requested || $0.value.committedAt > at }
            if let r = retryItem, utterances[r] == nil { retryItem = nil }
            // Hushed, not answered: they no longer hold the session busy.
            for item in dropped { await session.userTurnHandled(itemID: item) }
        }
    }

    private func handleBrain(_ e: CloudVoice.BrainEvent) async {
        switch e {
        case .session(let s): await handleSession(s)
        case .sentenceStarted(let item, _, let text):
            playing.insert(item)
            lastPlaybackAt = clock()
            currentSentence[item] = text
            if tokenLimited.contains(item), !TurnPolicy.isCompleteSentence(text) {
                // The token limit cut this sentence short: she stops before it.
                record(.tokenLimitStop)
                tokenLimited.remove(item)
                stopVoice()
            } else if narrationItems.contains(item), TurnPolicy.isNarration(text) {
                // A narrated sentence after her answer ("Let me think about how to respond."): never heard.
                narrationReached(item)
            }
            guard let id = channel(for: item) else { return }
            if speakFirst == id { speakFirst = nil }
            channels[id]?.pending.insert(item)
            channels[id]?.continuation.yield(.content(text + " "))
        case .sentenceFinished(let item, _, let text, let heard):
            lastPlaybackAt = clock()
            guard let id = channel(for: item) else { return }
            if heard { channels[id]?.heard[item, default: []].append(text) }
            channels[id]?.continuation.yield(.sentenceFinished(text, heard: heard))
        case .itemPlayed(let item, _, let cut):
            playing.remove(item)
            herVoiceEndedAt = clock()
            currentSentence[item] = nil
            narrationItems.remove(item)
            tokenLimited.remove(item)
            if cut, let c = continuedThrough, clock().timeIntervalSince(c.at) < 3 {
                // She talked on through "keep going", then was cut anyway (a
                // barge-in decided on the sound): she carries on.
                continuedThrough = nil
                if playing.isEmpty { await carryOn(c.item) }
            }
            lastPlaybackAt = herVoiceEndedAt
            guard let id = itemChannel[item] else { return }
            let said = channels[id]?.heard[item]?.joined(separator: " ") ?? ""
            channels[id]?.continuation.yield(.messageCompleted(said))
            channels[id]?.pending.remove(item)
            finishIfComplete(id)
        case .clipPlayed:
            herVoiceEndedAt = clock()
        case .connection:
            break
        }
    }

    private func handleSession(_ e: RealtimeEvent) async {
        let now = clock()
        switch e {
        case .connected:
            connected = true
        case .disconnected:
            connected = false
            forgetPendingTurns()
        case .rolledOver, .recovered:
            // A new connection: utterances of the old one have no audio here (a
            // reply to them would answer blind); their transcripts died with it.
            forgetPendingTurns()
        case .userSpeechStarted(let item, let ms):
            prosody.speechStarted(item: item, audioStartMs: ms)
            speechStartedAt[item] = now
            if !playing.isEmpty { startedOverHerVoice.insert(item) }
            if speechStartedAt.count > 16, let oldest = speechStartedAt.min(by: { $0.value < $1.value }) {
                speechStartedAt[oldest.key] = nil
                startedOverHerVoice.remove(oldest.key)
            }
        case .userSpeechStopped(let item, let ms):
            prosody.speechStopped(item: item, audioEndMs: ms)
        case .userCommitted(let item, _):
            await committed(item, at: now)
        case .userTranscriptDelta(let item, let delta):
            let before = partials[item]?.text ?? ""
            partials[item] = (before + delta, now)
            if partials.count > 16, let oldest = partials.min(by: { $0.value.at < $1.value.at }) {
                partials[oldest.key] = nil
                partialsChecked.remove(oldest.key)
            }
        case .assistantTranscriptDelta(let item, let delta):
            await opening(item, delta)
        case .userTranscript(let item, let text):
            partials[item] = nil
            partialsChecked.insert(item)
            await words(text, item: item)
        case .userTranscriptFailed(let item, _):
            host?.wordsFailed()
            await wordsFailed(item)
        case .responseStarted(let rid, let kind):
            bindResponse(rid, kind: kind)
        case .assistantAudioDone(let item, _), .assistantSentence(let item, _, _):
            if let g = generating, itemChannel[item] == nil {
                itemChannel[item] = g
                channels[g]?.items.insert(item)
                channels[g]?.pending.insert(item)
            }
        case .toolCall(let call):
            if let g = generating {
                channels[g]?.calledTools = true
                let tc = ToolCall(name: call.name, jsonArguments: call.arguments) ?? ToolCall(name: call.name)
                channels[g]?.continuation.yield(.toolCall(tc))
            }
        case .responseDone(let summary):
            await responseDone(summary, at: now)
        case .replyPreempted(let rid):
            // Real speech gets its own reply at its commit. If it turns out to be
            // her echo, the session re-requests by itself with the live DNA: that
            // DNA is replaced by a fresh `retry` one now (§4.1 "Echo rejection").
            // A canned line taken back is not a reply: nothing to re-render.
            if let rid, channels.values.contains(where: { $0.aside && $0.responseIDs.contains(rid) }) { break }
            await armRetryDNA(kind: .retry)
        case .initiativeCancelled:
            await armRetryDNA(kind: .initiative)
        default:
            break
        }
    }

    // MARK: Floor holds (tune 3: CloudVoice pauses her for a barge-in; words decide)

    /// A hold's life. Resumed: their items were a backchannel she went on through —
    /// released, never answered. Ended by the brain's own answer (its reply cut her,
    /// `byVoice` false): the voice no longer emits `.bargeIn` for that, so the brain
    /// tells the host (`bargedIn`: the Cortex senses the barge-in; nothing is stopped,
    /// the brain's reply is the answer). Ended by the voice: the app heard `.bargeIn`.
    private func handleHold(_ e: CloudVoice.HoldEvent) async {
        switch e {
        case .paused:
            break
        case .resumed(let items, _, let why):
            for item in items { await releaseBackchannel(item, why: "resumed-\(why)") }
        case .ended(_, let byVoice):
            guard !byVoice else { return }
            record(.bargeInSensed)
            host?.bargedIn()
        }
    }

    /// A committed item that was (part of) a backchannel the voice went on through:
    /// not a turn. Its unrequested utterance goes; the session is told it is handled.
    private func releaseBackchannel(_ item: String, why: String) async {
        if let u = utterances[item], u.requested { return }   // too late: the brain answered it
        record(.backchannel(why))
        var u = utterances[item] ?? Utterance(item: item, plan: .waitForPartial, committedAt: clock())
        u.backchannel = true
        u.partialDecided = true
        u.held = false
        u.deadline = nil
        utterances[item] = u
        if retryItem == item { retryItem = nil }
        await session.userTurnHandled(itemID: item)
    }

    /// The item is in the voice's current hold (her reply paused for it).
    private func inHold(_ item: String) -> Bool {
        voice.floorHold?.items.contains(item) ?? false
    }

    // MARK: User turns

    private func committed(_ item: String, at now: Date) async {
        guard let host else { return }
        // They went on: a held, unfinished turn is answered together with this one
        // (both are in the conversation; the reply answers the latest commit).
        for (held, u) in utterances where u.held {
            utterances[held] = nil
            await session.userTurnHandled(itemID: held)
        }
        if voice.wasBackchannel(itemID: item) {
            // The voice already went on through it ("mm-hm" over her voice): not a turn.
            record(.backchannelReleased)
            await releaseBackchannel(item, why: "voice")
            return
        }
        lastUserTurnAt = now
        lastCommittedItem = item
        let baseline = host.voiceBaseline
        let read = prosody.read(item: item, text: nil, baseline: baseline)
        let overlapped = !playing.isEmpty || startedOverHerVoice.contains(item) || voice.floorHold != nil
        let since: TimeInterval? = {
            if overlapped { return -1 }
            let start = speechStartedAt[item] ?? now
            return herVoiceEndedAt.map { start.timeIntervalSince($0) }
        }()
        let ctx = TurnPolicy.Context(answersOnCommit: host.answersOnCommit, signals: host.modeSignals(at: now),
                                     prosody: read, previousNotes: lastDNANotes, sinceHerVoice: since)
        let plan = TurnPolicy.onCommit(ctx)
        var u = Utterance(item: item, plan: plan, committedAt: now)
        record(.committed(plan: "\(plan)"))
        switch plan {
        case .respondFast:
            utterances[item] = u
            await requestReply(item: item, mode: .fast, text: nil, prosody: read)
        case .waitForWords:
            u.deadline = now.addingTimeInterval(options.exactWait)
            utterances[item] = u
        case .waitForPartial:
            u.deadline = now.addingTimeInterval(options.overlapWait)
            utterances[item] = u
            // Its words may already be in (a fast delta burst).
            if let p = partials[item], now.timeIntervalSince(p.at) >= options.partialSettle { await provisional(p.text, item: item) }
        case .waitForAddress:
            u.deadline = now.addingTimeInterval(options.addressWait)
            utterances[item] = u
        }
    }

    /// Utterances of a connection that is gone.
    private func forgetPendingTurns() {
        utterances.removeAll()
        speechStartedAt.removeAll()
        startedOverHerVoice.removeAll()
        retryItem = nil
        partials.removeAll()
        partialsChecked.removeAll()
        continuedThrough = nil
    }

    /// Done with an utterance (unless its refused reply waits for a retry).
    private func settle(_ item: String) {
        if retryItem != item { utterances[item] = nil }
    }

    private func words(_ raw: String, item: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            host?.wordsFailed()
            await wordsFailed(item)
            return
        }
        corpus.add(text)
        guard let host else { return }
        let u = utterances[item]
        let measured = prosody.mindProsody(item: item, text: text, baseline: host.voiceBaseline)
        let turn = HeardTurn(source: .voice(itemID: item), text: text, prosody: measured?.0,
                             duration: measured?.1 ?? prosody.duration(item: item) ?? 0, replyRequested: u?.requested ?? false)
        let verdict = await host.heard(turn)
        record(.heard(verdict: verdict.name))
        guard var u = utterances[item] else { return }
        u.heard = true
        u.text = text
        utterances[item] = u
        switch verdict {
        case .answer(let appraisal):
            utterances[item]?.appraisal = appraisal
            if u.backchannel {
                if TurnPolicy.isBackchannel(text) {
                    // "Keep going": she went on (or was asked to carry on); not a turn.
                    if !u.requested { await session.userTurnHandled(itemID: item) }
                    settle(item)
                    return
                }
                // The full words say it was more than a backchannel after all.
                utterances[item]?.backchannel = false
                if u.requested {
                    settle(item)
                    return
                }
            }
            if let unfinished = TurnPolicy.held(text), await holdBack(item, unfinished) { return }
            if u.requested {
                // Fast mode: the reply is out. A late "think hard" re-asks with more
                // effort while nothing of it has been heard yet.
                // An ordinary turn's effort counts as the chat effort (no re-ask for it).
                let answered = u.effort == Self.ordinaryEffort ? ThinkingMode.chatEffort : u.effort
                let (turn, rethink) = thinking.wordsArrived(text, answeredAt: answered)
                if let on = turn.modeChanged { host.thinkingModeChanged(on) }
                if rethink, let id = u.channel, channelUnheard(id) {
                    stopVoice()
                    utterances[item]?.requested = false
                    await requestReply(item: item, mode: .exact, text: text, appraisal: appraisal,
                                       effort: turn.reasoningEffort)
                }
                settle(item)
            } else {
                await requestReply(item: item, mode: .exact, text: text, appraisal: appraisal)
                settle(item)
            }
        case .handled:
            // A command: carried out, never answered (and not holding the session).
            // A fast reply already asked for it is taken back while unheard.
            if u.requested, let id = u.channel, channelUnheard(id) { stopVoice() }
            utterances[item] = nil
            await session.userTurnHandled(itemID: item)
        case .ignored:
            // Not for her (a TV, people talking to each other): a reply already asked
            // for it is taken back while unheard, and it leaves the conversation
            // (and every later seed).
            if u.requested, let id = u.channel, channelUnheard(id) {
                stopVoice()
                utterances[item] = nil
                await session.dropUserItem(itemID: item, resumePreempted: false)
            } else if !u.requested {
                utterances[item] = nil
                await session.dropUserItem(itemID: item)
            } else {
                utterances[item] = nil
            }
            if retryItem == item { retryItem = nil }
        }
    }

    /// An unfinished turn ("Hold on.", "I had pasta, and…"): not answered now. An
    /// unheard reply already asked for it is taken back. "Hold on" is never answered
    /// on its own; a trailing turn is, after `trailingWait` of nothing more. Returns
    /// false when it is too late (she is already answering out loud).
    private func holdBack(_ item: String, _ kind: TurnPolicy.Unfinished) async -> Bool {
        guard let u = utterances[item] else { return false }
        if u.requested {
            guard let id = u.channel, channelUnheard(id) else { return false }
            stopVoice()
        }
        if retryItem == item { retryItem = nil }
        record(.held(kind.rawValue))
        switch kind {
        case .holdOn:
            utterances[item] = nil
            await session.userTurnHandled(itemID: item)
        case .trailing, .riddle:
            utterances[item]?.requested = false
            utterances[item]?.channel = nil
            utterances[item]?.held = true
            utterances[item]?.deadline = clock().addingTimeInterval(kind == .riddle ? options.riddleWait : options.trailingWait)
        }
        return true
    }

    // MARK: Provisional words (transcription deltas, tune 2)

    /// The turn's settled transcription deltas: ~0.2 s before the full transcript
    /// and before her first audio. Used only for floor decisions — a backchannel
    /// over her voice, an unfinished turn whose fast reply must be taken back while
    /// unheard — never for the host (the full transcript still runs `heard`).
    private func provisional(_ text: String, item: String) async {
        partialsChecked.insert(item)
        guard let u = utterances[item], !u.heard else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if u.plan == .waitForPartial, !u.requested, !u.partialDecided {
            utterances[item]?.partialDecided = true
            if TurnPolicy.isBackchannel(clean) {
                utterances[item]?.backchannel = true
                await backchannel(item)
            } else if let kind = TurnPolicy.held(clean) {
                record(.held(kind.rawValue))
                // Held until the full words say more ("hold on" is released then).
                utterances[item]?.held = true
                utterances[item]?.deadline = clock().addingTimeInterval(kind == .riddle ? options.riddleWait : options.trailingWait)
            } else {
                await requestReply(item: item, mode: .fast, text: nil)
            }
            return
        }
        guard u.requested, !u.held, let kind = TurnPolicy.held(clean) else { return }
        // A fast reply is out for a turn that is not finished: taken back while
        // nobody has heard it; the full words confirm (or answer it after all).
        guard let id = u.channel, channelUnheard(id) else { return }
        stopVoice()
        if retryItem == item { retryItem = nil }
        record(.held(kind.rawValue))
        utterances[item]?.requested = false
        utterances[item]?.channel = nil
        utterances[item]?.held = true
        utterances[item]?.deadline = clock().addingTimeInterval(kind == .riddle ? options.riddleWait : options.trailingWait)
    }

    /// A backchannel said over her voice ("keep going", "mm-hm"): never a turn of
    /// its own. If her voice is still going she simply goes on; if it was already
    /// cut (the barge-in heard the sound first) or had ended, she carries on from
    /// where she stopped.
    private func backchannel(_ item: String) async {
        // Paused for it (a held barge-in): she goes on from where she paused.
        let resumed = voice.continueAfterBackchannel()
        if resumed || !playing.isEmpty || voice.graph.player.isBusy {
            record(.backchannel("continued"))
            continuedThrough = (item, clock())
            await session.userTurnHandled(itemID: item)
        } else {
            record(.backchannel("resumed"))
            await carryOn(item)
        }
    }

    /// Asks her to go on after "keep going" (a reply with the carry-on note).
    private func carryOn(_ item: String) async {
        if utterances[item] == nil {
            utterances[item] = Utterance(item: item, plan: .respondFast, committedAt: clock())
            utterances[item]?.backchannel = true
            utterances[item]?.partialDecided = true
        }
        guard utterances[item]?.requested == false else { return }
        await requestReply(item: item, mode: .fast, text: nil, notes: [TurnPolicy.carryOnNote])
        if utterances[item]?.heard == true { settle(item) }
    }

    // MARK: Spoken preambles (tune 2)

    /// Her reply's transcript, as it streams: every sentence start is checked for
    /// meta narration (tune 3; tune 2 checked only the first 7 words and missed "Oh
    /// no, that sounds a bit disappointing. Let me think about how to respond.").
    /// - In the first sentence ("Got it, let me think about how to respond to that."):
    ///   the reply is cut before it is heard and the turn answered again once (with a
    ///   reminder to answer straight away).
    /// - In a later sentence: she stops before that sentence (the transcript runs ahead
    ///   of her audio; `sentenceStarted` stops her if it is reached), keeping what she
    ///   already said as the answer. No retry: she has answered.
    private func opening(_ item: String, _ delta: String) async {
        guard !openingsChecked.contains(item) else { return }
        guard let id = itemChannel[item] ?? generating, let c = channels[id], !c.aside else {
            openingsChecked.insert(item)
            return
        }
        let text = (replyOpenings[item] ?? "") + delta
        replyOpenings[item] = text
        if let k = TurnPolicy.metaSentence(in: text) {
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0 {
                await preambleFound(channel: id)
            } else {
                record(.narrationStop)
                narrationItems.insert(item)
                // Already playing it (unlikely: the words lead the audio): stop now.
                if let now = currentSentence[item], TurnPolicy.isNarration(now) { narrationReached(item) }
            }
        } else if text.count > 4_000 {
            openingsChecked.insert(item)
            replyOpenings[item] = nil
        }
        if openingsChecked.count > 64 { openingsChecked.removeAll() }
        if replyOpenings.count > 16 { replyOpenings.removeAll() }
    }

    /// Her voice reached the narrated sentence of `item`: she stops before it.
    private func narrationReached(_ item: String) {
        narrationItems.remove(item)
        record(.preamble(cut: true))
        stopVoice()
    }

    private func preambleFound(channel id: Int) async {
        guard let c = channels[id], let user = c.item, !preambleRetried.contains(user),
              lastCommittedItem == nil || lastCommittedItem == user, !voice.userIsSpeaking else {
            record(.preamble(cut: false))
            return
        }
        record(.preamble(cut: true))
        preambleRetried.insert(user)
        if preambleRetried.count > 64 { preambleRetried.removeAll() }
        channels[id]?.preambleRetry = user
        stopVoice()
        if c.done { await answerAfterPreamble(channel: id) }
    }

    /// The reply cut for a preamble is over: the turn is answered again (once).
    private func answerAfterPreamble(channel id: Int) async {
        guard let user = channels[id]?.preambleRetry else { return }
        channels[id]?.preambleRetry = nil
        guard lastCommittedItem == nil || lastCommittedItem == user, !voice.userIsSpeaking else { return }
        if utterances[user] == nil { utterances[user] = Utterance(item: user, plan: .respondFast, committedAt: clock()) }
        let u = utterances[user]!
        utterances[user]?.requested = false
        // Most narrated calls were a `recall` (tune 2 eval: 19 of 27): the brain looks
        // it up itself, so the retry has nothing left to look up out loud.
        var notes = [TurnPolicy.answerStraightNote]
        if let looked = await lookUp() { notes.append(looked) }
        await requestReply(item: user, mode: u.text == nil ? .fast : .exact, text: u.text, appraisal: u.appraisal,
                           kind: .retry, notes: notes)
        settle(user)
    }

    /// `recall` run by the brain (when the toolbox has it: memories shared), as a note.
    private func lookUp() async -> String? {
        guard toolbox.realtimeTools.contains(where: { $0.name == "recall" }) else { return nil }
        let call = RealtimeToolCall(callID: "brain_recall", name: "recall", arguments: #"{"query":"everything"}"#,
                                    responseID: "", itemID: "")
        let out = await toolbox.run(call).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, !out.lowercased().hasPrefix("error") else { return nil }
        let flat = out.replacingOccurrences(of: "\n", with: "; ")
        return TurnPolicy.lookedUpNote + String(flat.prefix(TurnPolicy.lookedUpMax))
    }

    private func wordsFailed(_ item: String) async {
        guard let u = utterances[item] else { return }
        if u.held || u.backchannel {
            // Held ("…and"): answered at its deadline from the audio. A backchannel
            // was already handled.
            if u.backchannel, u.requested { settle(item) }
            return
        }
        if u.plan == .waitForWords || u.plan == .waitForPartial, !u.requested {
            // The model hears the audio itself: answer it as heard.
            await requestReply(item: item, mode: .fast, text: nil, prosody: prosody.read(item: item, text: nil, baseline: host?.voiceBaseline ?? .init()))
            settle(item)
        } else if u.plan == .waitForAddress {
            // Nobody can tell it was for her: not answered, and not kept.
            utterances[item] = nil
            await session.dropUserItem(itemID: item)
        } else {
            settle(item)
        }
    }

    /// Asks for the reply to `item`, with a fresh DNA in front of it.
    private func requestReply(item: String, mode: CueMode, text: String?, appraisal: Appraisal? = nil,
                              prosody read: ProsodyRead? = nil, effort override: ReasoningEffort? = nil,
                              kind: TurnContext.Kind = .reply, notes: [String] = []) async {
        guard let host, connected else { utterances[item] = nil; return }
        var effort = override ?? thinking.effortBeforeWords
        if override == nil, let text {
            let t = thinking.turn(for: text)
            effort = t.reasoningEffort
            if let on = t.modeChanged { host.thinkingModeChanged(on) }
        }
        effort = Self.effective(effort)
        let baseline = host.voiceBaseline
        let pr = read ?? prosody.read(item: item, text: text, baseline: baseline)
        let duration = prosody.duration(item: item)
        responseIndex += 1
        let turn = TurnContext(kind: kind, index: responseIndex, mode: mode)
        guard let (render, dna) = await buildDNA(turn: turn, appraisal: TurnAppraisal(prosody: pr, text: appraisal, durationS: duration),
                                                 pickNotes: true, notes: notes) else { utterances[item] = nil; return }
        if dna.relationship.waitBeforeAnswering {
            try? await Task.sleep(for: .seconds(options.waitBeforeAnswering))
            // They went on talking: their next commit is answered (both items).
            if voice.userIsSpeaking { utterances[item] = nil; return }
        }
        let id = openChannel(nil)
        host.brainStartedReply(BrainReply(kind: kind == .retry ? .retry : .voice, events: channelStream(id)))
        channels[id]?.item = item
        utterances[item]?.requested = true
        utterances[item]?.effort = effort
        utterances[item]?.channel = id
        utterances[item]?.mode = mode
        if let text { utterances[item]?.text = text }
        if let appraisal { utterances[item]?.appraisal = appraisal }
        let cap = options.capReplyTokens && !(text.map(TurnPolicy.wantsLongAnswer) ?? false)
            ? TurnPolicy.maxOutputTokens(length: dna.guidance.length, effort: effort) : nil
        let error = await send(render: render, mode: mode, kind: kind, channel: id) {
            try await self.reply(dna: render.text, effort: effort, maxOutputTokens: cap)
        }
        if case .responseInFlight? = error as? RealtimeSessionError, retryItem == nil || retryItem == item,
           utterances[item] != nil {
            // Refused (a response was in flight): try again when it is done.
            utterances[item]?.requested = false
            retryItem = item
        } else if error == nil, retryItem == item {
            retryItem = nil                       // answered after all: no retry
        }
    }

    // MARK: Requests from the app (initiatives, typed text)

    private func serve(_ request: ReplyRequest, channel id: Int) async {
        guard let host, connected else { finish(id); return }
        switch request {
        case .user(let words):
            guard let text = words?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { finish(id); return }
            corpus.add(text)
            let verdict = await host.heard(HeardTurn(source: .typed, text: text))
            guard case .answer(let appraisal) = verdict else { finish(id); return }
            lastUserTurnAt = clock()
            let t = thinking.turn(for: text)
            if let on = t.modeChanged { host.thinkingModeChanged(on) }
            responseIndex += 1
            let turn = TurnContext(kind: .reply, index: responseIndex, mode: .exact)
            guard let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(text: appraisal), pickNotes: true) else {
                finish(id)
                return
            }
            // The words go in as a user item, then the DNA and the request.
            guard let typed = await session.addUserText(text) else { finish(id); return }
            let error = await send(render: render, mode: .exact, kind: .reply, channel: id) {
                try await self.reply(dna: render.text, effort: Self.effective(t.reasoningEffort))
            }
            if error != nil { await session.dropUserItem(itemID: typed, resumePreempted: false) }
        case .initiative(let directive):
            let allowed = TurnPolicy.initiativeAllowed(connected: connected, userSpeaking: voice.userIsSpeaking,
                                                       replyOutstanding: channels.contains { $0.key != id && !$0.value.done },
                                                       awaitingWords: utterances.values.contains { !$0.requested },
                                                       toolRunning: toolsRunning > 0)
            guard allowed else { record(.initiativeRefused("busy")); finish(id); return }
            let clean = directive.trimmingCharacters(in: .whitespacesAndNewlines)
            lastInitiativeDirective = clean.isEmpty ? nil : clean
            responseIndex += 1
            let turn = TurnContext(kind: .initiative, index: responseIndex, initiative: clean.isEmpty ? nil : clean, mode: .fast)
            // A Cortex initiative (empty directive) already issued its aim with it.
            guard let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(), pickNotes: !clean.isEmpty) else {
                finish(id)
                return
            }
            _ = await send(render: render, mode: .fast, kind: .initiative, channel: id, initiative: true) {
                let effort = Self.ordinaryEffort.rawValue
                let o = await self.speakFirst(channel: id, kind: "initiative") { session in
                    await session.initiative(dna: render.text, reasoningEffort: effort)
                }
                if case .refused(let why) = o { throw InitiativeRefused(reason: "\(why)") }
                return .sent
            }
        }
    }

    struct InitiativeRefused: Error { var reason: String }

    /// Sends one request bound to channel `id`; a refusal closes the channel and
    /// comes back as the error.
    @discardableResult
    private func send(render: DNARender, mode: CueMode, kind: TurnContext.Kind, channel id: Int, initiative: Bool = false,
                      _ body: @escaping () async throws -> RequestOutcome) async -> Error? {
        awaiting.append(id)
        do {
            let outcome = try await body()
            lastMode = mode
            record(.dnaSent(index: responseIndex, kind: kind.rawValue, mode: mode.rawValue, estimatedTokens: render.estimatedTokens,
                            sectionBytes: render.sectionBytes, steps: render.steps.map(\.rawValue),
                            guardDrops: render.dropped.count, sha256: render.sha256, queued: outcome == .queued))
            return nil
        } catch {
            awaiting.removeAll { $0 == id }
            record(.requestFailed(initiative ? "initiative: \(error)" : "\(error)"))
            finish(id)
            return error
        }
    }

    // MARK: DNA

    private func buildDNA(turn: TurnContext, appraisal: TurnAppraisal, pickNotes: Bool, notes: [String] = []) async -> (DNARender, DeeDNA)? {
        guard let host else { return nil }
        let now = clock()
        let request = DNARequest(turn: turn, appraisal: appraisal, pickNotes: pickNotes, rings: rings, corpus: corpus,
                                 lastUserTurnAt: lastUserTurnAt, now: now)
        guard let parts = await host.dnaParts(request) else { return nil }
        var dna = DNAAssembler.assemble(parts.inputs)
        if !parts.inputs.shareMemories { Self.keepMemoriesPrivate(&dna) }
        var render = DNAPrompt.render(dna, guard: corpus)
        // The brain's own turn notes ("carry on") go first: they are about this turn.
        let extra = notes + parts.extraNotes
        if !extra.isEmpty { Self.addNotes(extra, to: &render) }
        rings.sample(parts.inputs.mind.code, at: now, force: true)
        lastDNANotes = Set(dna.now.notes.map(\.kind))
        lastVoiceWords = render.text.components(separatedBy: "\n").first { $0.hasPrefix("Voice: ") }
        return (render, dna)
    }

    /// "Share memories" off (docs/DNA.md §1.6): beyond what the assembler drops
    /// (facts, episodes, interests, upcoming), no shared moment reaches the cloud
    /// through the notes — a recall note ("You remember: …") or a running-joke
    /// callback — nor the running-joke hooks of section 6. Follow-ups (a subject)
    /// still come through.
    nonisolated static func keepMemoriesPrivate(_ dna: inout DeeDNA) {
        dna.now.notes.removeAll { $0.kind == .recall || $0.kind == .gagCallback }
        dna.selfModel.gags = []
    }

    /// The host's own notes (the people layer) as "Keep in mind" lines at the end of
    /// section 7 — not in a minimal DNA (V12), and only while the render stays within
    /// the budget's cap (§2.10). Fixed templates and names only.
    nonisolated static func addNotes(_ notes: [String], to render: inout DNARender,
                                     cap: Int = DNABudget.standard.cap) {
        guard !render.steps.contains(.minimal) else { return }
        var notes = notes
        while !notes.isEmpty {
            let text = insert(notes, into: render.text)
            if DNAPrompt.estimate(text) <= cap {
                render.text = text
                render.estimatedTokens = DNAPrompt.estimate(text)
                return
            }
            notes.removeLast()
        }
    }

    /// A note without brackets of any kind (the DNA never has any).
    nonisolated static func plain(_ s: String) -> String {
        s.unicodeScalars.filter { !"()[]{}<>".unicodeScalars.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The host's own notes go into section 7 as "Keep in mind" lines.
    nonisolated static func insert(_ notes: [String], into text: String) -> String {
        let clean = notes.map(Self.plain).filter { !$0.isEmpty }.prefix(2)
        guard !clean.isEmpty, let r = text.range(of: "\n8 THIS TURN") else { return text }
        let lines = clean.map { "Keep in mind: \($0)" }.joined(separator: "\n")
        var out = text
        out.insert(contentsOf: "\n" + lines, at: r.lowerBound)
        return out
    }

    // MARK: Tools

    private func runTool(_ call: RealtimeToolCall) async -> RealtimeToolResult {
        let box = toolbox
        toolsRunning += 1
        let result = await box.run(call)
        toolsRunning -= 1
        // A slow tool (a permission prompt) outlasted the follow-up wait: give the
        // follow-up its time again from now.
        let now = clock()
        for (id, c) in channels where c.toolWaitUntil != nil {
            channels[id]?.toolWaitUntil = now.addingTimeInterval(options.toolFollowUpWait)
        }
        record(.tool(name: call.name, followUp: "\(result.followUp)"))
        if call.name == "forget" {
            // The forgotten fact must not stay in context: a fresh DNA replaces the
            // live one before the follow-up (§4.1).
            let turn = TurnContext(kind: .reply, index: max(1, responseIndex), mode: lastMode)
            if let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(), pickNotes: false) {
                await session.replaceDNA(render.text)
                record(.dnaReplaced(estimatedTokens: render.estimatedTokens, sha256: render.sha256))
            }
        }
        return result
    }

    // MARK: Channels

    private func openChannel(_ continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation?) -> Int {
        nextChannel += 1
        let id = nextChannel
        if let continuation {
            channels[id] = Channel(continuation: continuation)
        } else {
            let (stream, c) = AsyncThrowingStream<ReplyEvent, Error>.makeStream(bufferingPolicy: .unbounded)
            channels[id] = Channel(continuation: c)
            ownStreams[id] = stream
        }
        return id
    }

    private var ownStreams: [Int: AsyncThrowingStream<ReplyEvent, Error>] = [:]

    private func channelStream(_ id: Int) -> AsyncThrowingStream<ReplyEvent, Error> {
        ownStreams.removeValue(forKey: id) ?? AsyncThrowingStream { $0.finish() }
    }

    private func channel(for item: String) -> Int? {
        if let id = itemChannel[item] { return id }
        guard let g = generating ?? lastBound, channels[g] != nil else { return nil }
        itemChannel[item] = g
        channels[g]?.items.insert(item)
        return g
    }

    private func channelUnheard(_ id: Int) -> Bool {
        guard let c = channels[id] else { return false }
        return c.items.allSatisfy { !playing.contains($0) } && c.heard.isEmpty && c.pending.isEmpty
    }

    private func bindResponse(_ rid: String, kind: ResponseKind) {
        let id: Int
        if kind == .toolFollowUp, let t = channels.first(where: { $0.value.toolWaitUntil != nil || ($0.value.calledTools && !$0.value.done) })?.key {
            id = t
            channels[id]?.toolWaitUntil = nil
            channels[id]?.done = false
            channels[id]?.calledTools = false
        } else if !awaiting.isEmpty {
            id = awaiting.removeFirst()
        } else if let last = lastBound, channels[last] != nil, !(channels[last]?.done ?? true) {
            id = last
        } else {
            // The session re-requested by itself (an echo withdrew what preempted it).
            id = openChannel(nil)
            host?.brainStartedReply(BrainReply(kind: .retry, events: channelStream(id)))
        }
        channels[id]?.responseIDs.insert(rid)
        generating = id
        lastBound = id
        record(.responseStarted(kind: kind.rawValue))
    }

    private func responseDone(_ s: ResponseSummary, at now: Date) async {
        var id: Int? = s.responseID.flatMap { rid in channels.first { $0.value.responseIDs.contains(rid) }?.key }
        if id == nil, !awaiting.isEmpty {
            // A request that never started: a queued one replaced by a newer one
            // (`superseded`: the one before the newest), else the oldest waiting.
            if s.reason == "superseded", awaiting.count >= 2 {
                id = awaiting.remove(at: awaiting.count - 2)
            } else {
                id = awaiting.removeFirst()
            }
        }
        if generating == id { generating = nil }
        record(.responseDone(status: s.status, reason: s.reason, audioMs: s.audioMs,
                             inputTokens: s.usage?.inputTokens, cachedTokens: s.usage?.inputTokenDetails?.cachedTokens))
        if s.hitTokenLimit {
            // Playback stops before the unfinished last sentence (never mid-word).
            for item in s.itemIDs {
                if let current = currentSentence[item], playing.contains(item), !TurnPolicy.isCompleteSentence(current) {
                    record(.tokenLimitStop)
                    stopVoice()
                } else {
                    tokenLimited.insert(item)
                }
            }
        }
        if let id, channels[id]?.preambleRetry != nil {
            channels[id]?.done = true
            await answerAfterPreamble(channel: id)
        }
        if let id, channels[id] != nil {
            channels[id]?.done = true
            channels[id]?.doneAt = now
            if s.status == "completed", channels[id]?.calledTools == true, (channels[id]?.toolWaitUntil == nil) {
                channels[id]?.toolWaitUntil = now.addingTimeInterval(options.toolFollowUpWait)
            }
            finishIfComplete(id)
        }
        if let item = retryItem {
            retryItem = nil
            if let u = utterances[item] {
                utterances[item]?.requested = false
                // What it knew when it was refused (exact mode keeps its words).
                await requestReply(item: item, mode: u.mode, text: u.text, appraisal: u.appraisal, kind: .retry)
                settle(item)
            }
        }
    }

    private func finishIfComplete(_ id: Int) {
        guard let c = channels[id], c.done, c.pending.isEmpty, c.toolWaitUntil == nil else { return }
        finish(id)
    }

    private func finish(_ id: Int) {
        guard let c = channels.removeValue(forKey: id) else { return }
        c.continuation.yield(.turnCompleted)
        c.continuation.finish()
        ownStreams[id] = nil
        awaiting.removeAll { $0 == id }
        if lastBound == id { lastBound = nil }
        if generating == id { generating = nil }
        itemChannel = itemChannel.filter { $0.value != id }
    }

    private func housekeeping() async {
        let now = clock()
        // Settled transcription deltas: the turn's provisional words.
        for (item, p) in partials where !partialsChecked.contains(item) && now.timeIntervalSince(p.at) >= options.partialSettle {
            await provisional(p.text, item: item)
        }
        // Over her voice, and no words in time: answer what was heard (fast).
        for (item, u) in utterances where u.plan == .waitForPartial && !u.requested && !u.partialDecided && !u.heard {
            if let d = u.deadline, now >= d {
                // Her reply is paused for it and their words decide (a quick commit can
                // deliver "Mm." on its own while they go on): never answered blind
                // while the hold lasts (the voice ends it, at most `holdLimit`).
                if inHold(item), now.timeIntervalSince(u.committedAt) < options.holdLimit {
                    utterances[item]?.deadline = now.addingTimeInterval(options.tick)
                    continue
                }
                utterances[item]?.partialDecided = true
                utterances[item]?.deadline = nil
                await requestReply(item: item, mode: .fast, text: nil)
            }
        }
        // Exact mode: the words did not come in time; answer what was heard (fast).
        for (item, u) in utterances where u.plan == .waitForWords && !u.requested && !u.heard {
            if let d = u.deadline, now >= d {
                record(.exactTimedOut)
                utterances[item]?.deadline = nil
                await requestReply(item: item, mode: .fast, text: nil)
            }
        }
        // A backchannel she talked on through whose full words never came.
        for (item, u) in utterances where u.backchannel && !u.requested && now.timeIntervalSince(u.committedAt) > options.addressWait {
            utterances[item] = nil
        }
        // A fast reply whose transcript never came: nothing more to decide.
        for (item, u) in utterances where u.requested && now.timeIntervalSince(u.committedAt) > 60 && retryItem != item {
            utterances[item] = nil
        }
        // "Is this for me?" never got its words: give it up (it must not block her).
        for (item, u) in utterances where u.plan == .waitForAddress && !u.heard {
            if let d = u.deadline, now >= d {
                utterances[item] = nil
                await session.dropUserItem(itemID: item)
            }
        }
        // A trailing turn ("…and") nothing followed: answer it now (unless they are
        // talking again — their commit will answer both).
        for (item, u) in utterances where u.held {
            guard let d = u.deadline, now >= d else { continue }
            if voice.userIsSpeaking {
                utterances[item]?.deadline = now.addingTimeInterval(0.5)
                continue
            }
            utterances[item]?.held = false
            utterances[item]?.deadline = nil
            await requestReply(item: item, mode: u.text == nil ? .fast : .exact, text: u.text, appraisal: u.appraisal)
            if utterances[item]?.heard == true { settle(item) }
        }
        // The user started before her initiative or canned line made a sound: it
        // gives way (CloudVoice's own initiative gate, for requests the brain sends).
        if let id = speakFirst {
            if channels[id] == nil || channels[id]?.done == true {
                speakFirst = nil
            } else if voice.userIsSpeaking {
                speakFirst = nil
                record(.yieldedToUser)
                stopVoice()
            }
        }
        for (id, c) in channels {
            if let until = c.toolWaitUntil, now >= until {
                // Never while a tool still runs (its result may still be spoken).
                guard toolsRunning == 0 else { continue }
                channels[id]?.toolWaitUntil = nil
                finishIfComplete(id)
            } else if c.done, let at = c.doneAt {
                let age = now.timeIntervalSince(at)
                let playingNow = !c.items.isDisjoint(with: playing)
                    || (!c.pending.isEmpty && lastPlaybackAt.map { now.timeIntervalSince($0) < 2 } ?? false)
                if age > options.channelMax || (!playingNow && age > options.channelTail) { finish(id) }
            }
        }
    }

    /// The session may re-request the reply (or initiative) that speech just
    /// preempted, if that speech turns out to be her echo, with the live DNA: that
    /// one is replaced by a fresh DNA for the retry now (a reply the brain asks for
    /// later brings its own).
    private func armRetryDNA(kind: TurnContext.Kind) async {
        guard connected, host != nil else { return }
        let turn = TurnContext(kind: kind, index: max(1, responseIndex), initiative: kind == .initiative ? lastInitiativeDirective : nil,
                               mode: lastMode)
        if let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(), pickNotes: false) {
            await session.replaceDNA(render.text)
            record(.dnaReplaced(estimatedTokens: render.estimatedTokens, sha256: render.sha256))
        }
    }

    // MARK: Her voice (requests to the session)

    /// Answers the committed user turn with this DNA (`requestResponse(dna:)`).
    private func reply(dna: String, effort: ReasoningEffort, maxOutputTokens: Int? = nil) async throws -> RequestOutcome {
        // Her previous reply somehow still playing: cut it first (the session is
        // told what was heard), so the new audio never queues behind it.
        if !playing.isEmpty { stopVoice() }
        await waitOutStop()
        voice.timeline.mark(.responseCreateSent, at: voice.graph.now)
        return try await session.requestResponse(dna: dna, maxOutputTokens: maxOutputTokens, reasoningEffort: effort.rawValue)
    }

    /// An initiative or canned line: refused while the user talks or her voice is
    /// still in the room; once sent, the user starting first takes it back.
    private func speakFirst(channel id: Int, kind: String,
                            _ body: @Sendable (RealtimeSession) async -> InitiativeOutcome) async -> InitiativeOutcome {
        guard voice.isConnected else { return .refused(.notConnected) }
        if voice.userIsSpeaking { return .refused(.userSpeaking) }
        let now = clock()
        if !playing.isEmpty || voice.graph.player.isBusy
            || herVoiceEndedAt.map({ now.timeIntervalSince($0) < Self.echoTail }) == true {
            return .refused(.speaking)
        }
        await waitOutStop()
        if voice.userIsSpeaking { return .refused(.userSpeaking) }
        let outcome = await body(session)
        if outcome == .sent {
            voice.timeline.mark(.responseCreateSent, at: voice.graph.now, detail: kind)
            speakFirst = id
        }
        return outcome
    }

    /// Her voice's tail in the room after playback ends (an initiative right after
    /// would hear it as the user).
    static let echoTail: TimeInterval = 0.4

    /// A request never goes out within `stopGuard` of a stop of her voice.
    private func waitOutStop() async {
        guard let at = lastStopAt else { return }
        let left = options.stopGuard - clock().timeIntervalSince(at)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
    }

    private func record(_ t: BrainTrace) {
        trace.append(t)
        if trace.count > 400 { trace.removeFirst(trace.count - 400) }
        onTrace?(t)
    }
}

/// One brain trace entry: decisions and sizes only — never DNA text, transcripts or
/// tool results (docs/DNA.md §5.4: estimate, section sizes, steps, guard drops, SHA-256).
public enum BrainTrace: Sendable, Equatable {
    case committed(plan: String)
    case heard(verdict: String)
    case exactTimedOut
    case dnaSent(index: Int, kind: String, mode: String, estimatedTokens: Int, sectionBytes: [Int], steps: [String],
                 guardDrops: Int, sha256: String, queued: Bool)
    case dnaReplaced(estimatedTokens: Int, sha256: String)
    case requestFailed(String)
    case initiativeRefused(String)
    /// The user started before her initiative or canned line was heard: taken back.
    case yieldedToUser
    /// A turn left unanswered for now (`TurnPolicy.Unfinished` raw value).
    case held(String)
    case responseStarted(kind: String)
    case responseDone(status: String, reason: String?, audioMs: Int, inputTokens: Int?, cachedTokens: Int?)
    case tool(name: String, followUp: String)
    /// Speech over her voice was a backchannel: she went on ("continued") or was
    /// asked to carry on after a cut ("resumed").
    case backchannel(String)
    /// Her reply opened with a meta preamble: cut before it was heard and the turn
    /// answered again (`cut`), or let be (a second time, or the floor moved on).
    case preamble(cut: Bool)
    /// A reply cut by the token limit stopped at its last complete sentence.
    case tokenLimitStop
    /// A later sentence of her reply is meta narration: she stops before it (tune 3).
    case narrationStop
    /// A hold over her voice ended as a barge-in decided by the brain's answer: the
    /// host was told (`BrainHost.bargedIn`, tune 3).
    case bargeInSensed
    /// A committed item the voice already settled as a backchannel it went on
    /// through (`CloudVoice.wasBackchannel`): released, never answered (tune 3).
    case backchannelReleased
}
