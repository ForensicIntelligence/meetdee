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
        /// Housekeeping period (the speculative gate is checked on it). Tune 9: 0.05 →
        /// 0.02 s (the release waited up to one tick: ~25 ms on average).
        public var tick: TimeInterval = 0.02
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
        /// Speculative reply with gated playback (tune 4): the reply to a voice turn is
        /// still requested at the commit, but CloudVoice holds its audio until the turn
        /// is confirmed over (`confirmWindow` of quiet since their last voiced frame, no
        /// new speech from the server, settled words not unfinished). If they go on
        /// first, the held reply is dropped unheard and the next commit answers it all.
        public var speculative = true
        /// Total quiet since the user's last voiced frame before her held reply plays
        /// (server_vad commits after 0.3 s of it; live tune 3 resumes came 0.4–0.7 s
        /// after the end of the first part). Tune 4 A/B: see `TurnPolicy.confirmWindow`.
        public var confirmWindow: TimeInterval = TurnPolicy.confirmWindow
        /// A held reply plays anyway this long after the commit when only local sound
        /// (not the server) says they might be talking (a TV, a clattering kitchen).
        public var confirmMax: TimeInterval = TurnPolicy.confirmMax
        /// Their own voice (EarCore `voiceActive`) holds her this much past `confirmMax`.
        public var voiceHoldExtra: TimeInterval = TurnPolicy.voiceHoldExtra
        /// The gate must still pass this long after it first passed (tune 5 F3).
        public var releaseRecheck: TimeInterval = TurnPolicy.releaseRecheck
        /// A turn whose held reply was dropped because they went on is answered with
        /// their next commit; if none comes (it was not speech), after this.
        public var resumeWait: TimeInterval = TurnPolicy.resumeWait
        /// She stops before a 4th sentence of an ordinary reply (never mid-word; not
        /// for a story or an explanation, nor in thinking mode). Tune 4.
        public var sentenceCap: Int? = TurnPolicy.sentenceCap
        /// Tune 9 (T8-2): a reply asked for and not started this long after (a server stall)
        /// gets a short thinking sound (`slowClip`, once), if nobody is talking.
        public var slowAfter: TimeInterval = 2.5
        public var slowClip: VoiceClip? = .oneSec
        /// Tune 9 (T8-2): a reply not started this long after it was asked for is asked for
        /// once more (the stalled one is cancelled), if the turn is still theirs to answer.
        public var stallRetryAfter: TimeInterval = 8
        /// Their speech is taken to have ended this long before the commit reached the
        /// brain (the speculative gate's quiet run starts from it, or from a later voiced
        /// frame of theirs): `TurnPolicy.commitLag`.
        public var commitLag: TimeInterval = TurnPolicy.commitLag
        /// Tune 11 (T10-1): a held reply whose turn has no words yet (no delta, no
        /// transcript) waits for them at most this much past when it would have played.
        public var wordsWait: TimeInterval = TurnPolicy.wordsWait
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
        /// Her reply voiced the unfinished-words aim and was taken back (tune 5): the
        /// later answer carries `unfinishedAnswerNote`; a second time, she stays quiet.
        var aimTakenBack = 0
        /// `waitForPartial`: its settled first words were looked at.
        var partialDecided = false
        /// Its words were a backchannel ("keep going"): not a turn of its own.
        var backchannel = false
        /// The commit on the graph clock (the speculative gate measures from it).
        var committedG: Double?
        /// Tune 6 (T5-2): the server's empty tail of a burst the voice committed itself
        /// (a commit with no speech start of its own, right after the burst's commit):
        /// never a turn. It is never answered blind and never answers held turns.
        var tail = false
        /// Tune 9 (T8-3): the item a tail is the rest of.
        var tailOf: String?
        /// Held turns this commit took over (their reply is this one's). If this item
        /// turns out not to be a turn for her (a TV, a backchannel), the newest is
        /// answered after all (tune 6: a hold must never lose a turn).
        var absorbed: [Utterance] = []
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
    /// Her replies heard this conversation (a sentence of it played): the greeting after
    /// time apart stays in the DNA until one was (tune 4, `TurnContext.heardReplies`).
    private var heardReplies = 0
    /// The newest user transcript, and the one before it (a joke announced one turn
    /// before its set-up, tune 4).
    private var lastWords: (item: String, text: String, at: Date)?
    private var previousWordsEntry: (item: String, text: String, at: Date)?
    /// The newest three user transcripts, newest first (a knock-knock punchline is two
    /// turns after "Knock knock", tune 5).
    private var recentWords: [(item: String, text: String, at: Date)] = []

    /// The speculative reply whose audio CloudVoice holds (tune 4). Times are the
    /// graph clock (the microphone's and the voice's).
    private struct Speculation {
        var item: String
        var channel: Int
        /// When the commit reached the brain.
        var commitG: Double
        /// Their speech ended about here (the last voiced frame before the commit).
        var speechEndG: Double
        var responseIDs: [String] = []
        /// Its first audio is held in the player.
        var ready = false
        var readyG: Double?
        /// The release was waited for because of local voice (for the trace).
        var heldForVoice = false
        /// Their full transcript came and is complete (tune 5 F2: the commit and the
        /// final words agree, so nothing but their voice itself holds her now).
        var wordsFinal = false
        /// Since when their side has been quiet without a break — no voice of theirs
        /// now, `confirmWindow` since their last voice, no server speech open (tune 6
        /// T5-1: tracked from the request on, not from when her audio is ready; the F3
        /// re-check needs `releaseRecheck` of it, so a resume caught a frame late still
        /// holds her, and audio arriving later costs nothing).
        var quietSince: Double?
        /// Tune 11 (T10-1): when it would have played but its turn had no words yet.
        var wordsWaitG: Double?
        /// When it was asked for (graph clock). A request long after the commit (exact
        /// words, a retry) measures its caps from here (tune 6 T5-4: every reply is gated).
        var armG: Double
    }
    private var spec: Speculation?

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
        /// Sentences of it that started playing (the sentence cap).
        var sentencesStarted = 0
        /// A story or an explanation was asked for: no sentence cap.
        var longOK = false
        /// Tune 7 (T6-6): the sentences its DNA `Length:` line allows (`TurnPolicy.sentenceBudget`).
        var budget: Int?
        /// One of its sentences was heard (counted in `heardReplies`).
        var heardOnce = false
        /// When the brain asked for it (tune 6: a turn committed before this saw it).
        var requestedAt: Date?
        /// Taken back unheard by the brain: it answers nothing any more.
        var takenBack = false
        /// The note its retry carries when it was cut for its first sentence (a spoken
        /// preamble: `answerStraightNote`; an app or clock referral: `noAppNote`).
        var retryNote: String?
        /// Tune 8 (T7-1): a carry-on after "keep going" (`carryOnNote`): it answers no turn.
        var carryOn = false
        /// Tune 9 (T8-2): its slow start got the thinking sound / was handled as a stall.
        var slowNoted = false
        var stallHandled = false
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
    /// The user item whose server speech is open (`speech_started`, not yet stopped
    /// or committed). Tune 6 T5-4/T5-6: no reply is asked for or released while a newer
    /// item is being said. Any `speech_stopped` closes it (the server's VAD ended
    /// speech, even under a new item id after the voice's own early commit).
    private var openServerSpeech: String?
    /// When (graph clock) the server's open speech last closed.
    private var serverQuietG: Double?
    /// The newest commit (graph clock): a tail commits right after it.
    private var lastCommitG: Double?
    /// Items whose `speech_stopped` came with no `speech_started` of their own.
    private var stoppedUnstarted: [String] = []
    /// The last `retry` DNA armed for a preempted reply, and whether speech started since.
    private var retryArmedAt: Date?
    private var speechSinceRetryArm = false
    /// Tune 9 (T8-3): the newest commit of any kind (a tail's burst), and items that were
    /// backchannels (newest last, at most 16).
    private var lastCommitAny: String?
    private var backchannelItems: [String] = []
    /// Tune 9 (T8-4): the response generating now, the message items of each response,
    /// and second message items of one response (she stops before them).
    private var generatingResponse: String?
    private var responseItems: [String: [String]] = [:]
    private var secondMessages: Set<String> = []
    private var messageItemsSeen: Set<String> = []
    /// Tune 9 (T8-2): user items whose stalled reply was asked for again (once per turn).
    private var stallRetried: Set<String> = []
    /// When the last response ended (a request queued behind it went out about then).
    private var lastResponseDoneAt: Date?

    // Plumbing
    private enum Input {
        case brain(CloudVoice.BrainEvent)
        case hold(CloudVoice.HoldEvent)
        case spec(CloudVoice.SpeculativeEvent)
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
        let specs = voice.speculativeEvents
        pumps.append(Task { for await e in specs { feed.yield(.spec(e)) } })
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
        utterances.values.contains { !$0.requested && !$0.tail && $0.plan != .waitForAddress } || channels.values.contains { !$0.done }
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
        // Tune 6 (T5-2): nothing of hers plays after a stop. Left set until the voice's
        // `itemPlayed` came, a later request "cut" her again — a stop of nothing that
        // closed the reply gate on the answer already on its way.
        playing.removeAll()
    }

    /// A new conversation: counters reset, and the realtime conversation is cleared
    /// (everything but the live DNA and the turn being answered), so the old talk is
    /// neither in context nor in a later rollover's summary or seed.
    public func newConversation(persona: Persona, now: Date) async {
        thinking = ThinkingMode()
        responseIndex = 0
        heardReplies = 0
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
        case .spec(let e): await handleSpeculative(e)
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
            let id = channel(for: item)
            if let id { channels[id]?.sentencesStarted += 1 }
            // Playing: whatever held it has let it go.
            if let id, spec?.channel == id { spec = nil }
            if secondMessages.contains(item) {
                // Tune 9 (T8-4): a second message of one response (a lead-in, then the answer
                // again): she has said her reply; she stops before it.
                secondMessages.remove(item)
                record(.secondMessageStop)
                stopHerself()
            } else if tokenLimited.contains(item), !TurnPolicy.isCompleteSentence(text) {
                // The token limit cut this sentence short: she stops before it.
                record(.tokenLimitStop)
                tokenLimited.remove(item)
                stopHerself()
            } else if narrationItems.contains(item),
                      TurnPolicy.isNarration(text) || TurnPolicy.isUnfinishedAim(text) || TurnPolicy.isAppReferral(text)
                        || TurnPolicy.isSelfReport(text)
                        || TurnPolicy.opensOnHearingThem(text, theirs: channel(for: item).flatMap { theirWords(channel: $0) }) {
                // A narrated sentence after her answer ("Let me think about how to respond."): never heard.
                narrationReached(item)
            } else if let id, let c = channels[id], overSentenceCap(c) {
                // A 4th sentence of an ordinary reply: she stops before it (tune 4).
                record(.sentenceCapStop)
                stopHerself()
            }
            guard let id else { return }
            if speakFirst == id { speakFirst = nil }
            channels[id]?.pending.insert(item)
            channels[id]?.continuation.yield(.content(text + " "))
        case .sentenceFinished(let item, _, let text, let heard):
            lastPlaybackAt = clock()
            guard let id = channel(for: item) else { return }
            if heard, let c = channels[id], !c.aside, !c.heardOnce {
                channels[id]?.heardOnce = true
                heardReplies += 1
            }
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
                // barge-in decided on the sound): she carries on — unless the cut is for
                // a newer turn of theirs (tune 8, T7-3: live interrupt-echo20 q02, the
                // phantom "Yeah." got a carry-on when the answer to "Are you awake?" cut
                // her; refused while that answer ran, its retry re-armed the gate and
                // threw the held answer away: 0.9 s lost).
                continuedThrough = nil
                if playing.isEmpty, !newerTurnPending(than: c) { await carryOn(c.item) }
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
            // Tune 10 (T9-2): a reply already asked for on the new one is kept.
            forgetPendingTurns(keepAsked: true)
        case .userSpeechStarted(let item, let ms):
            prosody.speechStarted(item: item, audioStartMs: ms)
            speechStartedAt[item] = now
            openServerSpeech = item
            speechSinceRetryArm = true
            if !playing.isEmpty { startedOverHerVoice.insert(item) }
            // They go on before her held reply was heard: it never plays (tune 4).
            if let sp = spec, sp.item != item, playing.isEmpty { await speculationResumed(why: "speech") }
            if speechStartedAt.count > 16, let oldest = speechStartedAt.min(by: { $0.value < $1.value }) {
                speechStartedAt[oldest.key] = nil
                startedOverHerVoice.remove(oldest.key)
            }
        case .userSpeechStopped(let item, let ms):
            prosody.speechStopped(item: item, audioEndMs: ms)
            if openServerSpeech != nil { serverQuietG = voice.graph.now }
            openServerSpeech = nil
            if speechStartedAt[item] == nil {
                // The server ended speech it never started under this id: "the rest" of
                // the burst the voice committed early (its tail, tune 6).
                stoppedUnstarted.append(item)
                if stoppedUnstarted.count > 8 { stoppedUnstarted.removeFirst() }
            }
        case .userCommitted(let item, _):
            if openServerSpeech == item {
                openServerSpeech = nil
                serverQuietG = voice.graph.now
            }
            await committed(item, at: now)
        case .userTranscriptDelta(let item, let delta):
            let before = partials[item]?.text ?? ""
            partials[item] = (before + delta, now)
            if partials.count > 16, let oldest = partials.min(by: { $0.value.at < $1.value.at }) {
                partials[oldest.key] = nil
                partialsChecked.remove(oldest.key)
            }
            await earlyWords(item)
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
            // Tune 6: once per preempting speech (live tune 5, the stale-speech preempts
            // re-rendered it for every answer and retry of the same turn).
            if let last = retryArmedAt, now.timeIntervalSince(last) < 1, !speechSinceRetryArm { break }
            retryArmedAt = now
            speechSinceRetryArm = false
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
        noteBackchannel(item)
        var u = utterances[item] ?? Utterance(item: item, plan: .waitForPartial, committedAt: clock())
        u.backchannel = true
        u.partialDecided = true
        u.held = false
        u.deadline = nil
        utterances[item] = u
        if retryItem == item { retryItem = nil }
        await session.userTurnHandled(itemID: item)
    }

    /// A backchannel by its words; over her voice (in a hold, or one she went on
    /// through), also the voice's hold-only continuers (tune 5 F6).
    private func isBackchannel(_ item: String, _ text: String) -> Bool {
        overHerVoice(item) ? voice.isHoldBackchannel(itemID: item, text: text) : TurnPolicy.isBackchannel(text)
    }

    private func overHerVoice(_ item: String) -> Bool {
        inHold(item) || startedOverHerVoice.contains(item) || voice.wasBackchannel(itemID: item)
    }

    /// Tune 7 (T6-3): `item` was said while she talks — over her voice, or her reply is
    /// playing or paused in a hold right now (a tail with no start of its own, said after
    /// she went on through a backchannel).
    private func duringHerSpeech(_ item: String) -> Bool {
        overHerVoice(item) || !playing.isEmpty || voice.floorHold != nil
    }

    /// Words over her voice that only mean "go on": a backchannel, or a misheard short
    /// fragment (the voice's one rule, with the item's sound since tune 9 —
    /// `CloudVoice.isMisheardFragment(itemID:text:)`: "Put going.", "Grand.", "She.",
    /// "Done.", "I'm listen.", never "Too late."; a single word the words don't know,
    /// live "Movie." for "Who made you?", only when it *sounded* like a backchannel).
    /// Tune 7 decision: backchannels continue her.
    private func goOnWords(_ item: String, _ text: String) -> Bool {
        isBackchannel(item, text) || (duringHerSpeech(item) && voice.isMisheardFragment(itemID: item, text: text))
    }

    /// The item is in the voice's current hold (her reply paused for it).
    private func inHold(_ item: String) -> Bool {
        voice.floorHold?.items.contains(item) ?? false
    }

    /// `item` is likely their joke's punchline (tune 5 F7: j01 was explained, k06
    /// "Lettuce in" missed): their turn before it was a riddle's set-up, or the one
    /// before that was "Knock knock".
    private func punchlineExpected(item: String) -> Bool {
        let earlier = recentWords.filter { $0.item != item && clock().timeIntervalSince($0.at) <= TurnPolicy.previousTurnWindow }
        guard let last = earlier.first else { return false }
        let before = earlier.dropFirst().first?.text
        return TurnPolicy.isPunchlineTurn(previous: last.text, beforeThat: before)
    }

    /// Their turn before `item` (its words), if it was recent.
    private func previousWords(before item: String) -> String? {
        let e = lastWords?.item == item ? previousWordsEntry : lastWords
        guard let e, clock().timeIntervalSince(e.at) <= TurnPolicy.previousTurnWindow else { return nil }
        return e.text
    }

    // MARK: Speculative replies (tune 4: asked at the commit, heard once the turn is over)

    /// Whether the reply to `item` is speculative: returns the end of their speech
    /// (graph clock) when its audio must wait for the turn to be confirmed, nil when
    /// it may play at once (already confirmed, or not a fresh voice turn).
    ///
    /// The end is the server's: server_vad commits after its 300 ms of silence, so
    /// speech ended about `commitLag` before the commit reached the brain. (Tune 4: the
    /// brain's own energy VAD was no judge of it — in a kitchen bed every frame was
    /// "loud", in a fan bed most speech was not, and YIN found no pitch in most TTS
    /// frames; EarCore's `userIsSpeaking` is what tells a voice from the room.)
    ///
    /// Tune 6 (T5-4): every reply goes through the gate, a late one too (exact words, a
    /// retry, a turn answered after its hold). Live, "D." was answered in exact mode
    /// 0.56 s after its commit with the gate skipped as "confirmed" (the TTS voice had no
    /// pitch for `voiceActive`) while the server was hearing the rest of their sentence:
    /// she played over them. A gate that already passes costs nothing: her audio comes
    /// ≥ 0.3 s after the request, by when the re-check has long held.
    private func speculationWanted(item: String) -> Double? {
        guard options.speculative else { return nil }
        let c = utterances[item]?.committedG ?? voice.graph.now
        return c - options.commitLag
    }

    /// The speculative reply's gate: released once the turn is confirmed over —
    /// `confirmWindow` since the end of their speech, nobody talking now by the voice's
    /// own ear (`userIsSpeaking`: their voice in the last 0.6 s, or the server's speech
    /// open), and settled words (if any came) that do not say it is unfinished (those
    /// take it back: `provisional`). New speech from the server drops it
    /// (`speculationResumed`). A voice the server never calls speech holds it at most
    /// `confirmMax` after the commit.
    private func gateCheck() async {
        guard let sp = spec else { return }
        guard channels[sp.channel] != nil else {
            // Its reply is over (closed with nothing to play): nothing to hold.
            spec = nil
            voice.releaseSpeculative()
            return
        }
        let g = voice.graph.now
        // Quiet since their voice: the server's end, or a later voiced frame of theirs
        // (EarCore's fast, bed-proof `lastUserVoiceAt`: a resume restarts the window).
        let lastVoice = voice.lastUserVoiceAt
        let quiet = g - max(sp.speechEndG, lastVoice.isFinite ? min(lastVoice, g) : -.infinity)
        // Tune 5 F2/F3: their voice now, by EarCore's 0.15 s `voiceActive` (no 0.6 s
        // latch, never a kitchen / TV / fan bed), not the latched `userIsSpeaking`.
        let voiceNow = voice.userVoiceActive
        let settling = !sp.wordsFinal && (partials[sp.item].map {
            !partialsChecked.contains(sp.item) && clock().timeIntervalSince($0.at) < options.partialSettle } ?? false)
        // The caps count from the commit, or from the request when it went out after the
        // first cap had passed (a late request is still gated: tune 6).
        let base = sp.armG - sp.commitG >= options.confirmMax ? sp.armG : sp.commitG
        let sinceCommit = g - base
        let overdue = sinceCommit >= options.confirmMax
        // Their voice holds her past the cap, but never longer than this.
        let hardOverdue = sinceCommit >= options.confirmMax + options.voiceHoldExtra
        // Tune 6 (T5-6): the server hearing a newer item of theirs holds her too.
        let serverQuiet = openServerSpeech == nil || openServerSpeech == sp.item
        let theirSideQuiet = !voiceNow && serverQuiet && quiet >= options.confirmWindow
        // Tune 6 (T5-1): the quiet run is tracked from the request on, whether or not her
        // audio is in yet (live tune 5 it started only once the audio and the final words
        // were there, and every turn paid the 0.12 s re-check: p50 1.17 → 1.26 s).
        if theirSideQuiet {
            if sp.quietSince == nil {
                // Tune 9 (latency): from when the run actually began — `confirmWindow` after
                // their last voice, and never before the server's speech closed — not from the
                // tick that first saw it (live, the release waited on two 50 ms ticks: held p50
                // 80 ms). The re-check still needs `releaseRecheck` of quiet past the window,
                // judged on the voice's own last voiced frame at release time.
                let began = g - quiet + options.confirmWindow
                spec?.quietSince = min(g, max(began, serverQuietG ?? -.infinity))
            }
        } else {
            spec?.quietSince = nil
        }
        // Tune 11 (T10-1): the words wait is over (`wordsWait` past when it would have played).
        let wordsWaited = sp.wordsWaitG.map { g - $0 >= options.wordsWait - 1e-9 } ?? false
        let pass = hardOverdue || (theirSideQuiet && (!settling || overdue || wordsWaited))
        guard pass else {
            if !theirSideQuiet, quiet >= options.confirmWindow || overdue { spec?.heldForVoice = true }
            return
        }
        // Nothing to let go of yet: released the moment her first audio is in (`.ready`).
        guard sp.ready else { return }
        // F3: their side has been quiet `releaseRecheck` without a break (a resume onset
        // caught a frame late still holds her).
        if !hardOverdue, options.releaseRecheck > 0 {
            guard let since = spec?.quietSince, g - since >= options.releaseRecheck - 1e-9 else { return }
        }
        // Tune 11 (T10-1, live fillers-echo10 t03): no words of theirs yet — her audio was
        // released at quiet 930 ms and the deltas "…call my mom Ann." came 8 ms later
        // (transcription lag 0.70 s): answered early. The words decide whether the turn
        // is over; they are waited for, at most `wordsWait` (then `settling` decides).
        if !overdue, !hardOverdue, !sp.wordsFinal, partials[sp.item] == nil, !partialsChecked.contains(sp.item) {
            if sp.wordsWaitG == nil { spec?.wordsWaitG = g }
            if g - (sp.wordsWaitG ?? g) < options.wordsWait - 1e-9 { return }
        }
        spec = nil
        voice.releaseSpeculative()
        let held = sp.readyG.map { max(0, g - $0) } ?? 0
        record(.speculationReleased(heldMs: Int((held * 1000).rounded()), quietMs: Int((quiet * 1000).rounded()),
                                    overdue: overdue && (voiceNow || settling), ready: sp.ready))
    }

    /// They went on talking before her held reply was heard: it is dropped (never
    /// heard: the voice cancels it and the server keeps none of it) and the turn is
    /// held: their next commit answers all of it (both items are in the conversation).
    private func speculationResumed(why: String) async {
        guard let sp = spec else { return }
        spec = nil
        channels[sp.channel]?.takenBack = true
        voice.discardSpeculative()
        lastStopAt = clock()
        record(.speculationDropped(why))
        if retryItem == sp.item { retryItem = nil }
        var u = utterances[sp.item] ?? Utterance(item: sp.item, plan: .respondFast, committedAt: clock())
        guard u.channel == nil || u.channel == sp.channel else { return }
        u.requested = false
        u.channel = nil
        u.held = true
        u.deadline = clock().addingTimeInterval(options.resumeWait)
        utterances[sp.item] = u
    }

    /// A reply asked for and not heard yet is taken back: a speculative one is
    /// discarded (no cut, nothing to truncate), any other is stopped.
    private func takeBack() {
        // What is taken back answers nothing (`coveringReply`).
        for (id, c) in channels where !c.done && !c.aside && channelUnheard(id) { channels[id]?.takenBack = true }
        if spec != nil {
            spec = nil
            voice.discardSpeculative()
            lastStopAt = clock()
            record(.speculationDropped("taken back"))
        } else {
            stopVoice()
        }
    }

    private func handleSpeculative(_ e: CloudVoice.SpeculativeEvent) async {
        switch e {
        case .started(let rid):
            spec?.responseIDs.append(rid)
        case .ready(_, _, let at):
            guard spec != nil else { return }
            spec?.ready = true
            spec?.readyG = at
            await gateCheck()
        case .complete:
            break
        case .released:
            break
        case .discarded(let rid, _, _, let byVoice, let why):
            // "rearmed": the voice dropped the previous one for the brain's new one.
            guard byVoice, let sp = spec, why != "rearmed" else { return }
            if let rid, !sp.responseIDs.isEmpty, !sp.responseIDs.contains(rid) { return }
            // The voice dropped it (a cut of her voice, a timeout, a lost connection).
            spec = nil
            channels[sp.channel]?.takenBack = true
            record(.speculationDropped("voice-\(why)"))
            if why == "timeout", sp.responseIDs.isEmpty, channels[sp.channel]?.stallHandled == false {
                // Tune 9 (T8-2): its response never started (a server stall); the voice gave
                // it up (and cancelled it): the turn is still owed.
                await stalled(sp.channel, cancelled: true)
            }
        }
    }

    // MARK: User turns

    private func committed(_ item: String, at now: Date) async {
        guard let host else { return }
        let g = voice.graph.now
        let previousCommit = lastCommitAny
        defer {
            lastCommitG = g
            lastCommitAny = item
        }
        if voice.wasBackchannel(itemID: item) {
            // The voice already went on through it ("mm-hm" over her voice): not a turn.
            record(.backchannelReleased)
            await releaseBackchannel(item, why: "voice")
            return
        }
        // Tune 6 (T5-2, all 4 unanswered questions): the server's empty tail of a burst the
        // voice committed early ("Are you awake?" | "") is not a turn: answered blind, it
        // was a second request in the tick of the real answer.
        if isTail(item, at: g) {
            record(.tailIgnored)
            var u = Utterance(item: item, plan: .waitForPartial, committedAt: now)
            u.committedG = g
            u.tail = true
            u.tailOf = previousCommit
            u.partialDecided = true
            u.deadline = now.addingTimeInterval(options.addressWait)
            utterances[item] = u
            return
        }
        // They went on: a held, unfinished turn is answered together with this one
        // (both are in the conversation; the reply answers the latest commit).
        var absorbed: [Utterance] = []
        for (held, u) in utterances where u.held {
            utterances[held] = nil
            absorbed.append(u)
            await session.userTurnHandled(itemID: held)
        }
        absorbed.sort { $0.committedAt < $1.committedAt }
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
        u.committedG = g
        u.absorbed = absorbed
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

    /// Whether the committed `item` is only the server's tail of the burst before it:
    /// the voice says so (its floor hold's `tails`), or it has no speech start of its
    /// own (only a `speech_stopped`) and came within `CloudVoice.holdTailWindow` of the
    /// commit before it (the server's VAD ending "the rest" under a new item id after the
    /// voice's early commit: live tune 5, all four unanswered questions).
    private func isTail(_ item: String, at g: Double) -> Bool {
        if voice.floorHold?.tails.contains(item) == true { return true }
        guard speechStartedAt[item] == nil, stoppedUnstarted.contains(item), let last = lastCommitG else { return false }
        return g - last <= CloudVoice.holdTailWindow + 1e-9
    }

    /// A commit that took over held turns turned out to be no turn for her (not for her,
    /// a backchannel, a tail): the newest of them is answered after all, once quiet.
    private func restoreAbsorbed(from u: Utterance?) {
        guard var last = u?.absorbed.last, utterances[last.item] == nil else { return }
        // Tune 9 (T8-3, live backchannel-echo10 c02): "Don't stop, keep going." came back as
        // "That's like a, you know, stop." (held for the speech after it) and "Keep going."
        // (a carry-on, which took the held words over). Restored, the held words were asked
        // for again, refused while the carry-on ran, then sent after it: the retry cut the
        // carry-on at 840 ms and a second carry-on played. A carry-on asked for after the
        // held words were said is their reply: one carry-on per hold.
        if channels.values.contains(where: { $0.carryOn && !$0.takenBack && ($0.requestedAt.map { $0 >= last.committedAt } ?? false) }) {
            record(.covered)
            return
        }
        last.held = true
        last.requested = false
        last.channel = nil
        last.deadline = clock()
        utterances[last.item] = last
        record(.held("restored"))
    }

    /// Utterances of a connection that is gone.
    ///
    /// Tune 10 (T9-2, solo fallback-rollover-speech q08): "I heard you ask," was taken back
    /// as the rollover switched; its retry went out on the new session (behind its seed and
    /// a fresh DNA), and this discarded it — cancelled 1 ms after it was created, the turn
    /// lost. The session switches only with nothing in flight and reports every response of
    /// the old connection done before `.rolledOver`: a reply still live here was asked for
    /// on the new connection (`keepAsked`), and is kept.
    private func forgetPendingTurns(keepAsked: Bool = false) {
        if let sp = spec, !(keepAsked && channels[sp.channel].map { !$0.done && !$0.takenBack } == true) {
            spec = nil
            voice.discardSpeculative()
        }
        utterances.removeAll()
        speechStartedAt.removeAll()
        startedOverHerVoice.removeAll()
        retryItem = nil
        partials.removeAll()
        partialsChecked.removeAll()
        continuedThrough = nil
        openServerSpeech = nil
        lastCommitG = nil
        stoppedUnstarted.removeAll()
    }

    /// Done with an utterance (unless its refused reply waits for a retry).
    private func settle(_ item: String) {
        // A turn held again (a newer item is being said: tune 6) waits for that commit.
        if retryItem != item, utterances[item]?.held != true { utterances[item] = nil }
    }

    /// A reply in progress that already answers `item`: asked for after its commit (the
    /// model hears it), not taken back, and not over unheard. Tune 6 (T5-2): a turn
    /// gets exactly one answer — a second request for it is never sent.
    private func coveringReply(_ item: String) -> Int? {
        guard let at = utterances[item]?.committedAt else { return nil }
        return channels.first { _, c in
            !c.aside && !c.takenBack && !c.carryOn && c.item != nil && (c.requestedAt.map { $0 >= at } ?? false)
                && (!c.done || !c.items.isEmpty)
        }?.key
    }

    private func words(_ raw: String, item: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            host?.wordsFailed()
            await wordsFailed(item)
            return
        }
        corpus.add(text)
        if lastWords?.item != item { previousWordsEntry = lastWords }
        lastWords = (item, text, clock())
        recentWords.removeAll { $0.item == item }
        recentWords.insert((item, text, clock()), at: 0)
        if recentWords.count > 3 { recentWords.removeLast() }
        // Tune 5 F2: the commit and the final, complete words agree.
        if spec?.item == item, TurnPolicy.held(text, after: previousWords(before: item)) == nil { spec?.wordsFinal = true }
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
        if let id = u.channel, TurnPolicy.wantsLongAnswer(text) { channels[id]?.longOK = true }
        switch verdict {
        case .answer(let appraisal):
            utterances[item]?.appraisal = appraisal
            if !u.requested, tailOfBackchannel(u), TurnPolicy.isNoiseTail(text) || goOnWords(item, text) {
                // Tune 9 (T8-3, live backchannel-fan15 bc02): "Mm-hm." came back as "MMHN." (she
                // went on), and the server's tail of that burst as "10." (fan noise): answered,
                // it cut her at 2665 ms. The rest of a backchannel that is a word at most, a
                // number or noise is no turn: it leaves the conversation.
                record(.backchannel("tail"))
                utterances[item] = nil
                if retryItem == item { retryItem = nil }
                await session.dropUserItem(itemID: item, resumePreempted: false)
                // Tune 10 (T9-1, live backchannel-kitchen15 c02): "Don't stop." (continued, its
                // go-on deferred while they talked) | the tail "Keep going.": dropped without a
                // go-on, the voice waited out its deadline in the kitchen bed and cut her.
                continueHer(item, u.tailOf)
                return
            }
            if u.backchannel {
                if goOnWords(item, text) {
                    // "Keep going": she went on (or was asked to carry on); not a turn.
                    // Tune 10 (T9-1): the full words say "go on" again: a go-on the voice
                    // deferred while they talked is renewed (never left to its deadline).
                    continueHer(item)
                    if !u.requested { await session.userTurnHandled(itemID: item) }
                    settle(item)
                    restoreAbsorbed(from: u)
                    return
                }
                // The full words say it was more than a backchannel after all.
                utterances[item]?.backchannel = false
                // Tune 9 (T8-1): she talked on through it ("continued"); the answer's own cut
                // of her voice is no "cut anyway after keep going" (that asked for a carry-on
                // for this very item, refused while the answer ran, then sent after it: a
                // second reply to one turn).
                if continuedThrough?.item == item { continuedThrough = nil }
                backchannelItems.removeAll { $0 == item }
                if u.requested, let id = u.channel, channels[id]?.carryOn == true {
                    // Tune 8 (T7-1): what was asked for it is a carry-on ("go on from where
                    // you stopped"), no answer: taken back while unheard, and the turn gets
                    // its one answer now (refused while the carry-on runs: right after it).
                    if channelUnheard(id) { takeBack() }
                    channels[id]?.carryOn = false
                    channels[id]?.takenBack = true
                    utterances[item]?.requested = false
                    utterances[item]?.channel = nil
                    u = utterances[item] ?? u
                } else if u.requested {
                    settle(item)
                    return
                }
                u.backchannel = false
            }
            // Tune 5 F6: a continuer said over her ("Sheep going." for "Keep going", a bare
            // "I'm listening.") is never answered: she goes on.
            // Tune 7 (T6-3): a misheard short fragment while she talks ("Grand.", the tail "Done.").
            if !u.requested, !u.backchannel, duringHerSpeech(item), goOnWords(item, text) {
                utterances[item]?.backchannel = true
                await backchannel(item)
                settle(item)
                restoreAbsorbed(from: u)
                return
            }
            if let unfinished = TurnPolicy.held(text, after: previousWords(before: item)), await holdBack(item, unfinished) { return }
            if u.requested {
                // Fast mode: the reply is out. A late "think hard" re-asks with more
                // effort while nothing of it has been heard yet.
                // An ordinary turn's effort counts as the chat effort (no re-ask for it).
                let answered = u.effort == Self.ordinaryEffort ? ThinkingMode.chatEffort : u.effort
                let (turn, rethink) = thinking.wordsArrived(text, answeredAt: answered)
                if let on = turn.modeChanged { host.thinkingModeChanged(on) }
                if rethink, let id = u.channel, channelUnheard(id) {
                    takeBack()
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
            if u.requested, let id = u.channel, channelUnheard(id) { takeBack() }
            utterances[item] = nil
            await session.userTurnHandled(itemID: item)
        case .ignored:
            // Not for her (a TV, people talking to each other): a reply already asked
            // for it is taken back while unheard, and it leaves the conversation
            // (and every later seed).
            if u.requested, let id = u.channel, channelUnheard(id) {
                takeBack()
                utterances[item] = nil
                await session.dropUserItem(itemID: item, resumePreempted: false)
            } else if !u.requested {
                utterances[item] = nil
                await session.dropUserItem(itemID: item)
            } else {
                utterances[item] = nil
            }
            if retryItem == item { retryItem = nil }
            // Held turns it took over are still theirs to be answered, unless her reply
            // to it is already being heard (tune 6).
            if !u.requested || u.channel.map({ channels[$0]?.takenBack == true }) == true { restoreAbsorbed(from: u) }
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
            takeBack()
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
            let wait = heldWait(kind, utterances[item]?.text)
            utterances[item]?.deadline = clock().addingTimeInterval(wait)
        }
        return true
    }

    // MARK: Provisional words (transcription deltas, tune 2)

    /// Tune 6 (T5-3): over her voice, the first words that can no longer become a
    /// backchannel ("Are you…", "What's your…") decide at once — no `partialSettle` wait
    /// (live: the answer was asked for 0.43 s after the commit). Words that may still be
    /// "keep going" / "I'm listening" ("I'm", "Keep"), a hold-only continuer ("She's not…")
    /// or "hold on" wait to settle as before. Partial words always look unfinished ("What's
    /// your"): the settled and full words still take the reply back if they are (and a
    /// command or words not for her), unheard — it is speculative.
    private func earlyWords(_ item: String) async {
        // Tune 11 (T10-4): also a turn begun just after her voice ended (`commandWindow`)
        // while she is silent now: its reply is gated like any (live, 6 such turns waited
        // for settled words: overhead 0.30–0.48 s).
        guard let u = utterances[item], u.plan == .waitForPartial, !u.requested, !u.partialDecided, !u.heard, !u.tail,
              overHerVoice(item) || !duringHerSpeech(item), let p = partials[item] else { return }
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = TurnPolicy.words(text)
        // Tune 7 (T6-3): never on one or two words ("Put going" was "Keep going"): those wait
        // for their settled or full words, where a misheard fragment is a backchannel. Two
        // words that already ask ("Who made", "Are you") still decide at once.
        // Tune 8 (T7-2, live backchannel-echo20 c05): never on words that end the way a
        // continuer does ("Sheupr and going." was "Keep going"; "…I'm listen"): the full
        // words decide those.
        // Tune 10 (T9-1): the voice's sound-aware fragment rule, as everywhere else.
        guard w.count >= 3 || (w.count == 2 && TurnPolicy.startsQuestion(w)), !voice.isMisheardFragment(itemID: item, text: text),
              !TurnPolicy.endsLikeContinuer(text), !Backchannel.mayBecomeBackchannel(text), !Self.mayBecomeHoldContinuer(w),
              !TurnPolicy.isBackchannel(text), TurnPolicy.unfinished(text) != .holdOn,
              // Tune 12 (live fan15 c05): over her voice, the voice's hold rule too — "I'm with
              // some." right after "Keep going." is the rest of it (`isContinuerTail`).
              !(overHerVoice(item) && isBackchannel(item, text)),
              !TurnPolicy.breaksOff(text) else { return }
        // Tune 11 review: just after her voice (not over it) the settled words still decide
        // whether the turn is over — the gate waits for them and they take the reply back
        // (89d0c0f held "…call my mom, and." there; Tune11ReviewBrainTests).
        if overHerVoice(item) { partialsChecked.insert(item) }
        utterances[item]?.partialDecided = true
        record(.earlyWords)
        await requestReply(item: item, mode: .fast, text: nil)
    }

    /// The words so far are the start of a hold-only continuer ("She's not going").
    nonisolated static func mayBecomeHoldContinuer(_ w: [String]) -> Bool {
        Backchannel.holdOnlyContinuers.contains { c in
            let cw = c.split(separator: " ").map(String.init)
            guard w.count <= cw.count else { return false }
            for (i, x) in w.enumerated() {
                if i == w.count - 1 { if !cw[i].hasPrefix(x) { return false } } else if cw[i] != x { return false }
            }
            return true
        }
    }

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
            if goOnWords(item, clean) {
                utterances[item]?.backchannel = true
                await backchannel(item)
            } else if let kind = TurnPolicy.held(clean, after: previousWords(before: item)) {
                record(.held(kind.rawValue))
                // Held until the full words say more ("hold on" is released then).
                utterances[item]?.held = true
                utterances[item]?.deadline = clock().addingTimeInterval(heldWait(kind, clean))
            } else {
                await requestReply(item: item, mode: .fast, text: nil)
            }
            return
        }
        guard u.requested, !u.held, let kind = TurnPolicy.held(clean, after: previousWords(before: item)) else { return }
        // A fast reply is out for a turn that is not finished: taken back while
        // nobody has heard it; the full words confirm (or answer it after all).
        guard let id = u.channel, channelUnheard(id) else { return }
        takeBack()
        if retryItem == item { retryItem = nil }
        record(.held(kind.rawValue))
        utterances[item]?.requested = false
        utterances[item]?.channel = nil
        utterances[item]?.held = true
        utterances[item]?.deadline = clock().addingTimeInterval(heldWait(kind, clean))
    }

    /// How long a held turn waits for more: a riddle's set-up `riddleWait`; a bare call
    /// of her name or a one-letter fragment `TurnPolicy.fragmentWait` (they are starting
    /// a turn: answered soon if nothing follows); anything else trailing `trailingWait`.
    private func heldWait(_ kind: TurnPolicy.Unfinished, _ text: String?) -> TimeInterval {
        if kind == .riddle { return options.riddleWait }
        if kind == .trailing, let text, TurnPolicy.isFragmentOrAddress(text) {
            return min(options.trailingWait, TurnPolicy.fragmentWait)
        }
        return options.trailingWait
    }

    /// Tune 10 (T9-1): every "go on" decision continues her. Paused for any of `items` (a
    /// hold), she goes on now, or once they are quiet (the voice defers it while they talk).
    /// No hold of theirs: nothing to do (she is talking on, or was asked to carry on).
    private func continueHer(_ items: String?...) {
        guard let hold = voice.floorHold, items.contains(where: { $0.map(hold.items.contains) ?? false }) else { return }
        voice.continueAfterBackchannel()
    }

    /// A backchannel said over her voice ("keep going", "mm-hm"): never a turn of
    /// its own. If her voice is still going she simply goes on; if it was already
    /// cut (the barge-in heard the sound first) or had ended, she carries on from
    /// where she stopped.
    private func backchannel(_ item: String) async {
        noteBackchannel(item)
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

    private func noteBackchannel(_ item: String) {
        backchannelItems.removeAll { $0 == item }
        backchannelItems.append(item)
        if backchannelItems.count > 16 { backchannelItems.removeFirst() }
    }

    /// Tune 9 (T8-3): `item` is the tail of a burst that was a backchannel ("MMHN." | "10.").
    private func tailOfBackchannel(_ u: Utterance) -> Bool {
        guard u.tail, let parent = u.tailOf else { return false }
        return backchannelItems.contains(parent) || voice.wasBackchannel(itemID: parent) || utterances[parent]?.backchannel == true
    }

    /// A turn of theirs after the backchannel `c` is being answered or decided (a reply
    /// asked for it, or its words still to come): she does not carry on over it.
    private func newerTurnPending(than c: (item: String, at: Date)) -> Bool {
        // Tune 9 (T8-1): an answer to the backchannel's own item (its full words were a turn)
        // counts too: it is that turn's one answer, never followed by a carry-on.
        channels.values.contains { ch in
            !ch.aside && !ch.carryOn && !ch.takenBack && ch.item != nil
                && (ch.requestedAt.map { $0 >= c.at } ?? false)
        } || utterances.values.contains { $0.item != c.item && !$0.backchannel && !$0.tail && $0.committedAt >= c.at }
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
        if !messageItemsSeen.contains(item), let rid = generatingResponse, generating == id,
           channels[id]?.responseIDs.contains(rid) == true {
            messageItemsSeen.insert(item)
            if messageItemsSeen.count > 64 { messageItemsSeen = [item] }
            // Tune 9 (T8-4): the message items of one response. Live 3 of 354 responses had two
            // (a filler or a hello, then the answer: "I hear you, loud and clear. Now I'm all
            // ears…" + "Yes, I can hear you well…"): she says one, never a second.
            var items = responseItems[rid] ?? []
            if !items.contains(item) {
                if !items.isEmpty {
                    secondMessages.insert(item)
                    record(.secondMessage)
                }
                items.append(item)
                responseItems[rid] = items
                if responseItems.count > 16, let old = responseItems.keys.first(where: { $0 != rid }) { responseItems[old] = nil }
            }
        }
        if secondMessages.count > 16 { secondMessages.removeAll() }
        let text = (replyOpenings[item] ?? "") + delta
        replyOpenings[item] = text
        if let first = completeFirstSentence(text), let theirs = theirWords(channel: id),
           TurnPolicy.echoesTheirWords(first, theirs: theirs) {
            // Tune 8 (T7-4): "Hi Alex, who made you?" — their question said back as her
            // greeting. Unheard: taken back and asked again once, to answer it first.
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            let takenBack = await preambleFound(channel: id, note: TurnPolicy.answerFirstNote)
            record(.echoedQuestion(takenBack: takenBack))
            if takenBack { return }
        } else if let k = TurnPolicy.heardYouSentence(in: text, theirs: theirWords(channel: id)) {
            // Tune 9 (T8-5): "I heard you thinking about a dog…" — telling them she heard them.
            // First sentence, unheard: taken back and asked again once (`noHeardYouNote`);
            // later (or already heard): she stops before it.
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0, await preambleFound(channel: id, note: TurnPolicy.noHeardYouNote) {
                record(.heardYou(takenBack: true))
                return
            }
            record(.heardYou(takenBack: false))
            if k > 0 {
                narrationItems.insert(item)
                if let now = currentSentence[item], TurnPolicy.opensOnHearingThem(now, theirs: theirWords(channel: id)) {
                    narrationReached(item)
                }
            }
        } else if let k = TurnPolicy.unfinishedAimSentence(in: text) {
            // "Want to finish the sentence?" (tune 5 F3): never heard. In her first
            // sentence the reply is taken back and the turn waited out in silence; later,
            // she stops before it (what she said stands).
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0, await unfinishedAimFound(channel: id) { return }
            record(.narrationStop)
            narrationItems.insert(item)
            if let now = currentSentence[item], TurnPolicy.isUnfinishedAim(now) { narrationReached(item) }
        } else if let k = TurnPolicy.appReferralSentence(in: text) {
            // Tune 6 (T5-8): "…you can check a weather app." She has none: never heard. In
            // her first sentence the reply is taken back and asked again once (with
            // `noAppNote`); later, she stops before it.
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0, await preambleFound(channel: id, note: TurnPolicy.noAppNote) {
                record(.appReferral(takenBack: true))
                return
            }
            record(.appReferral(takenBack: false))
            narrationItems.insert(item)
            if let now = currentSentence[item], TurnPolicy.isAppReferral(now) { narrationReached(item) }
        } else if let k = TurnPolicy.selfReportSentence(in: text) {
            // Tune 7 (T6-7): "Tiny robot report: it feels like…" — a status read-out of
            // herself, never heard. First sentence: taken back and asked again once (with
            // `noReportNote`); later: she stops before it.
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0, await preambleFound(channel: id, note: TurnPolicy.noReportNote) {
                record(.selfReport(takenBack: true))
                return
            }
            record(.selfReport(takenBack: false))
            narrationItems.insert(item)
            if let now = currentSentence[item], TurnPolicy.isSelfReport(now) { narrationReached(item) }
        } else if let k = TurnPolicy.metaSentence(in: text) {
            openingsChecked.insert(item)
            replyOpenings[item] = nil
            if k == 0 {
                await preambleFound(channel: id)
            } else if channelUnheard(id), let theirs = theirWords(channel: id), TurnPolicy.asks(theirs),
                      await preambleFound(channel: id, note: TurnPolicy.answerFirstNote) {
                // Tune 9 (T8-4, live fillers-echo30 f03): "Ah, that sounds like a fun bit of
                // stargazing. Let me think this through with you." — their question not
                // answered before she thinks aloud, and nothing of it heard yet: taken back
                // and asked again once, to answer first (stopped before it, she would have
                // said only the lead-in).
                record(.thinkingAloud(takenBack: true))
                return
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

    /// Her reply's first sentence once it is complete (more text after it, or it ends on . ! ? …).
    private func completeFirstSentence(_ text: String) -> String? {
        let all = TurnPolicy.sentences(text)
        guard let first = all.first else { return nil }
        if all.count >= 2 { return first }
        return first.last.map { ".!?…".contains($0) } == true ? first : nil
    }

    /// The words of the turn the reply on channel `id` answers, as far as they are known.
    private func theirWords(channel id: Int) -> String? {
        guard let user = channels[id]?.item else { return nil }
        if let t = utterances[user]?.text { return t }
        if let l = lastWords, l.item == user { return l.text }
        return partials[user]?.text
    }

    /// Her unheard reply opens on the unfinished-words aim: taken back, and their turn
    /// is held as trailing (they may go on: their next commit answers both). Nothing
    /// follows within `trailingWait`: answered with `unfinishedAnswerNote`; if that
    /// answer voices the aim again, she stays quiet. False: too late (heard already).
    private func unfinishedAimFound(channel id: Int) async -> Bool {
        guard let c = channels[id], let user = c.item, channelUnheard(id) else { return false }
        record(.unfinishedAim(takenBack: true))
        takeBack()
        if retryItem == user { retryItem = nil }
        var u = utterances[user] ?? Utterance(item: user, plan: .respondFast, committedAt: clock())
        u.aimTakenBack += 1
        u.requested = false
        u.channel = nil
        if u.aimTakenBack >= 2 {
            // Twice: the turn is let go; she waits for them in silence.
            utterances[user] = nil
            await session.userTurnHandled(itemID: user)
            return true
        }
        u.held = true
        u.deadline = clock().addingTimeInterval(options.trailingWait)
        utterances[user] = u
        return true
    }

    /// Her voice reached the narrated sentence of `item`: she stops before it.
    private func narrationReached(_ item: String) {
        narrationItems.remove(item)
        record(.preamble(cut: true))
        stopHerself()
    }

    /// Tune 13 (T12-2): her own stop (sentence cap, second message, token limit, a
    /// narrated sentence) is no barge-in: the cut it brings is never "cut anyway after
    /// keep going" (live backchannel-echo20 c05: the cap 2.58 s after "Keep going." asked
    /// for a carry-on, "Oh, okay, let's keep going…", and she never stopped talking).
    private func stopHerself() {
        continuedThrough = nil
        stopVoice()
    }

    /// Her unheard reply opens with a sentence that must not be heard (a preamble; an
    /// app referral: `note`): cut, and the turn answered again once with `note` when the
    /// cut reply is over. False: let be (a second time, the floor moved on, or heard).
    @discardableResult
    private func preambleFound(channel id: Int, note: String? = nil) async -> Bool {
        guard let c = channels[id], let user = c.item, !preambleRetried.contains(user),
              lastCommittedItem == nil || lastCommittedItem == user, !voice.userIsSpeaking,
              note == nil || channelUnheard(id) else {
            if note == nil { record(.preamble(cut: false)) }
            return false
        }
        if note == nil { record(.preamble(cut: true)) }
        preambleRetried.insert(user)
        if preambleRetried.count > 64 { preambleRetried.removeAll() }
        channels[id]?.preambleRetry = user
        channels[id]?.retryNote = note
        takeBack()
        if c.done { await answerAfterPreamble(channel: id) }
        return true
    }

    /// The reply cut for a preamble is over: the turn is answered again (once).
    private func answerAfterPreamble(channel id: Int) async {
        guard let user = channels[id]?.preambleRetry else { return }
        let retryNote = channels[id]?.retryNote
        channels[id]?.preambleRetry = nil
        guard lastCommittedItem == nil || lastCommittedItem == user, !voice.userIsSpeaking else { return }
        if utterances[user] == nil { utterances[user] = Utterance(item: user, plan: .respondFast, committedAt: clock()) }
        let u = utterances[user]!
        utterances[user]?.requested = false
        // Most narrated calls were a `recall` (tune 2 eval: 19 of 27): the brain looks
        // it up itself, so the retry has nothing left to look up out loud.
        var notes = [retryNote ?? TurnPolicy.answerStraightNote]
        if retryNote == nil, let looked = await lookUp() { notes.append(looked) }
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
        if u.tail {
            // The tail of a burst, with no words: nothing was said in it.
            utterances[item] = nil
            await session.userTurnHandled(itemID: item)
            return
        }
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
        if kind == .reply, let id = coveringReply(item) {
            // Already answered by a reply asked for after it (tune 6 T5-2).
            record(.covered)
            utterances[item]?.requested = true
            utterances[item]?.channel = id
            utterances[item]?.held = false
            if retryItem == item { retryItem = nil }
            return
        }
        if let open = openServerSpeech, open != item, utterances[item] != nil {
            // Tune 6 (T5-4 / T5-6): they are saying more ("D." | "Guess what…", "I had pasta
            // for dinner." | "And."): never asked for over them. Held; their next commit
            // answers all of it (or, if none comes, this one after `resumeWait`).
            record(.held("speech"))
            utterances[item]?.requested = false
            utterances[item]?.channel = nil
            utterances[item]?.held = true
            utterances[item]?.deadline = clock().addingTimeInterval(options.resumeWait)
            if let text { utterances[item]?.text = text }
            if let appraisal { utterances[item]?.appraisal = appraisal }
            if retryItem == item { retryItem = nil }
            return
        }
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
        var notes = notes
        if kind == .reply, punchlineExpected(item: item) { notes.append(TurnPolicy.punchlineNote) }
        // Tune 8 (T7-6): a question asked over her voice is answered in her first sentence
        // (live: "What did you do today?" → "Ooh, I want to hear what happened with your
        // volcanoes today! As for me, …"; "Who made you?" → "Me? Nah, …").
        // Tune 14: never with their words (the early words are often a cut-off prefix).
        if kind == .reply || kind == .retry, !notes.contains(TurnPolicy.carryOnNote), !notes.contains(TurnPolicy.answerFirstNote),
           overHerVoice(item), TurnPolicy.asks(text ?? utterances[item]?.text ?? partials[item]?.text ?? "") {
            notes.append(TurnPolicy.answerFirstNote)
        }
        responseIndex += 1
        let turn = TurnContext(kind: kind, index: responseIndex, mode: mode, heardReplies: heardReplies)
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
        channels[id]?.requestedAt = clock()
        channels[id]?.carryOn = notes.contains(TurnPolicy.carryOnNote)
        channels[id]?.budget = TurnPolicy.sentenceBudget(length: dna.guidance.length)
        if let t = text ?? utterances[item]?.text, TurnPolicy.wantsLongAnswer(t) { channels[id]?.longOK = true }
        // Speculative (tune 4): the turn may not be over yet; her audio is held until it is.
        let gate = speculationWanted(item: item)
        utterances[item]?.requested = true
        utterances[item]?.effort = effort
        utterances[item]?.channel = id
        utterances[item]?.mode = mode
        if let text { utterances[item]?.text = text }
        if let appraisal { utterances[item]?.appraisal = appraisal }
        let cap = options.capReplyTokens && !(text.map(TurnPolicy.wantsLongAnswer) ?? false)
            ? TurnPolicy.maxOutputTokens(length: dna.guidance.length, effort: effort) : nil
        let error = await send(render: render, mode: mode, kind: kind, channel: id) {
            try await self.reply(dna: render.text, effort: effort, maxOutputTokens: cap, channel: id,
                                 speculate: gate.map { (item, id, $0) })
        }
        if error != nil, let sp = spec, sp.channel == id {
            // Refused: nothing of this request exists. Disarmed without a cancel — a discard
            // would cancel the response that is in flight (tune 6: a refused request never
            // touches the live answer).
            spec = nil
            voice.releaseSpeculative()
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
            let turn = TurnContext(kind: .reply, index: responseIndex, mode: .exact, heardReplies: heardReplies)
            guard let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(text: appraisal), pickNotes: true) else {
                finish(id)
                return
            }
            // The words go in as a user item, then the DNA and the request.
            if TurnPolicy.wantsLongAnswer(text) { channels[id]?.longOK = true }
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
            let turn = TurnContext(kind: .initiative, index: responseIndex, initiative: clean.isEmpty ? nil : clean, mode: .fast,
                                   heardReplies: heardReplies)
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
            let turn = TurnContext(kind: .reply, index: max(1, responseIndex), mode: lastMode, heardReplies: heardReplies)
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

    /// A reply past `sentenceCap` sentences (tune 4): not a canned line, a story or an
    /// explanation, nor in thinking mode.
    private func overSentenceCap(_ c: Channel) -> Bool {
        guard let cap = options.sentenceCap, !c.aside, !c.longOK, !thinking.isOn else { return false }
        // Tune 7 (T6-6): the turn's own budget, never more than the cap.
        return c.sentencesStarted > min(cap, c.budget ?? cap)
    }

    private func channelUnheard(_ id: Int) -> Bool {
        guard let c = channels[id] else { return false }
        // Held by the speculative gate: nothing of it has played (tune 4).
        if spec?.channel == id { return true }
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
        generatingResponse = rid
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
        lastResponseDoneAt = now
        record(.responseDone(status: s.status, reason: s.reason, audioMs: s.audioMs,
                             inputTokens: s.usage?.inputTokens, cachedTokens: s.usage?.inputTokenDetails?.cachedTokens))
        if s.hitTokenLimit {
            // Playback stops before the unfinished last sentence (never mid-word).
            for item in s.itemIDs {
                if let current = currentSentence[item], playing.contains(item), !TurnPolicy.isCompleteSentence(current) {
                    record(.tokenLimitStop)
                    stopHerself()
                } else {
                    tokenLimited.insert(item)
                }
            }
        }
        if let id, let sp = spec, sp.channel == id, s.status != "completed", !sp.ready {
            // Cancelled or failed before any audio (the session preempted it for
            // speech, a lost connection): nothing to hold any more.
            spec = nil
            voice.releaseSpeculative()
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
            if let u = utterances[item], coveringReply(item) != nil || u.tail {
                // The reply that was in flight was asked for after it: it answered it
                // (tune 6 T5-2: one answer per turn, never a second one).
                record(.covered)
                settle(item)
            } else if let u = utterances[item] {
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
        // Settled transcription deltas: the turn's provisional words. Tune 11 (T10-1):
        // before the gate — in the tick its words settle, an unfinished turn's held reply
        // is taken back, never released first (it would be heard, and kept).
        for (item, p) in partials where !partialsChecked.contains(item) && now.timeIntervalSince(p.at) >= options.partialSettle {
            await provisional(p.text, item: item)
        }
        await gateCheck()
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
        // A burst's tail whose (empty) words never reached the brain: let go, unanswered.
        for (item, u) in utterances where u.tail && !u.requested {
            if let d = u.deadline, now >= d {
                utterances[item] = nil
                await session.userTurnHandled(itemID: item)
            }
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
            await requestReply(item: item, mode: u.text == nil ? .fast : .exact, text: u.text, appraisal: u.appraisal,
                               notes: u.aimTakenBack > 0 ? [TurnPolicy.unfinishedAnswerNote] : [])
            if utterances[item]?.heard == true { settle(item) }
        }
        await slowResponses(now)
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
                               mode: lastMode, heardReplies: heardReplies)
        if let (render, _) = await buildDNA(turn: turn, appraisal: TurnAppraisal(), pickNotes: false) {
            await session.replaceDNA(render.text)
            record(.dnaReplaced(estimatedTokens: render.estimatedTokens, sha256: render.sha256))
        }
    }

    // MARK: Server stalls (tune 9, T8-2)

    /// When the request on channel `c` went out, as near as the brain knows: asked for, or
    /// (queued behind a response) when that response ended.
    private func sentAt(_ c: Channel) -> Date? {
        guard let asked = c.requestedAt else { return nil }
        return max(asked, lastResponseDoneAt ?? asked)
    }

    /// Whether `item` is still the turn to answer: nothing newer of theirs was committed
    /// (a backchannel or a tail aside) or asked for since `since`, and nobody is talking.
    private func stillCurrent(_ item: String, since: Date, channel id: Int) -> Bool {
        !voice.userIsSpeaking && openServerSpeech == nil && stillCurrentIgnoringSpeech(item, since: since, channel: id)
    }

    /// Live tune 8: the server stalled 3.56 s and 9.59 s before `response.created`; the
    /// session gave the request up at 2.5 s and cancelled the late answer the moment it
    /// started (fillers-echo10 f01, interrupt-clean q01: two turns lost). The session now
    /// waits (`responseTimeout` 10 s). Here: past `slowAfter` a short thinking sound (once,
    /// nobody talking, nothing of hers playing); past `stallRetryAfter` with nothing
    /// started, the stalled request is cancelled and the turn asked for once more.
    private func slowResponses(_ now: Date) async {
        for (id, c) in channels where !c.aside && !c.done && !c.takenBack && c.item != nil && c.responseIDs.isEmpty {
            // Queued behind a response still generating: not stalled.
            if let g = generating, g != id { continue }
            guard let at = sentAt(c) else { continue }
            let age = now.timeIntervalSince(at)
            if age >= options.stallRetryAfter, !c.stallHandled {
                await stalled(id, cancelled: false)
            } else if age >= options.slowAfter, !c.slowNoted {
                channels[id]?.slowNoted = true
                var clip = false
                if let sound = options.slowClip, !c.carryOn, let item = c.item, stillCurrent(item, since: c.requestedAt ?? at, channel: id),
                   playing.isEmpty, !voice.graph.player.isBusy {
                    clip = voice.play(sound, deferWhileUserSpeaks: true)
                }
                record(.slowResponse(clip: clip))
            }
        }
    }

    /// The reply on channel `id` never started: it is cancelled (unless the voice did) and,
    /// if its turn is still current and was not retried before, asked for once more when
    /// the cancel is through (`retryItem`).
    private func stalled(_ id: Int, cancelled: Bool) async {
        guard let c = channels[id], let item = c.item else { return }
        channels[id]?.stallHandled = true
        if !cancelled {
            if spec?.channel == id {
                spec = nil
                voice.discardSpeculative()
            } else {
                await session.cancelUnspokenResponse()
            }
        }
        channels[id]?.takenBack = true
        let since = c.requestedAt ?? clock()
        guard !c.carryOn, !stallRetried.contains(item), retryItem == nil || retryItem == item,
              stillCurrent(item, since: since, channel: id) else {
            record(.stalled(retried: false))
            return
        }
        stallRetried.insert(item)
        if stallRetried.count > 64 { stallRetried.removeAll() }
        var u = utterances[item] ?? Utterance(item: item, plan: .respondFast, committedAt: since)
        if u.text == nil, let w = lastWords, w.item == item { u.text = w.text }
        if u.text != nil { u.mode = .exact }
        u.requested = false
        u.channel = nil
        u.held = false
        u.deadline = nil
        utterances[item] = u
        retryItem = item
        record(.stalled(retried: true))
    }

    /// `stillCurrent` without the "nobody is talking" part.
    private func stillCurrentIgnoringSpeech(_ item: String, since: Date, channel id: Int) -> Bool {
        if utterances.values.contains(where: { $0.item != item && !$0.backchannel && !$0.tail && $0.committedAt > since }) {
            return false
        }
        return !channels.contains { k, c in
            k != id && !c.aside && !c.takenBack && c.item != nil && c.item != item && (c.requestedAt.map { $0 > since } ?? false)
        }
    }

    // MARK: Her voice (requests to the session)

    /// Answers the committed user turn with this DNA (`requestResponse(dna:)`).
    private func reply(dna: String, effort: ReasoningEffort, maxOutputTokens: Int? = nil, channel: Int? = nil,
                       speculate: (item: String, channel: Int, speechEndG: Double)? = nil) async throws -> RequestOutcome {
        // Another response is in flight: the session refuses (or queues) this one. Tune 6
        // (T5-2): then nothing here may touch her voice — live, the refused duplicate's
        // "cut" of a reply already stopped closed the reply gate on the answer in flight.
        let mine = channel ?? speculate?.channel
        let othersInFlight = (generating.map { $0 != mine } ?? false) || awaiting.contains { $0 != mine }
        let speculating = speculate.map { channels[$0.channel] != nil } == true && !othersInFlight
        // Her previous reply somehow still playing: cut it first (the session is
        // told what was heard), so the new audio never queues behind it.
        var cutPlaying = false
        if !playing.isEmpty, !othersInFlight {
            cutPlaying = await session.state == .speaking
            stopVoice()
        }
        if speculating && cutPlaying {
            // Tune 6 (T5-3): a cut of her playing reply needs no 0.3 s guard before a
            // speculative request (`speculate` tells the reply gate a request follows);
            // only the cut must reach the session first, or it would cancel the new
            // response: wait for that, not for a fixed time (live: 0.28 s of every answer
            // to a question asked over her).
            await waitForCut()
        } else {
            await waitOutStop()
        }
        if speculating, let sp = speculate, channels[sp.channel] != nil {
            // Armed last thing before the request: a stop above must not take it.
            // Never while another response is in flight (the session refuses or
            // queues this one; arming would drop that one).
            voice.speculate()
            let g = voice.graph.now
            spec = Speculation(item: sp.item, channel: sp.channel, commitG: utterances[sp.item]?.committedG ?? g,
                               speechEndG: sp.speechEndG, armG: g)
            record(.speculated)
            // The quiet run starts now if their side is quiet already (tune 6 T5-1).
            await gateCheck()
        } else if speculate != nil {
            record(.speculationSkipped(late: false, busy: true))
        }
        if spec == nil, voice.speculative != nil {
            // Nothing of the brain's is held: the voice must not hold this one.
            voice.releaseSpeculative()
        }
        voice.timeline.mark(.responseCreateSent, at: voice.graph.now)
        // Tune 7 (T6-1): the reply answers the turn the brain asked it for, by name — never
        // whatever the server committed last. Live (interrupt-clean q02, fan15 q08) the
        // answer to "Are you awake?" went out just after the server committed an empty tail
        // of the same burst; keyed to that tail, it was cancelled when the tail was dropped.
        let answering = (channel ?? speculate?.channel).flatMap { channels[$0]?.item }
        return try await session.requestResponse(dna: dna, maxOutputTokens: maxOutputTokens, reasoningEffort: effort.rawValue,
                                                 answering: answering)
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

    /// After a cut of her playing reply: until the session has taken the cut (it is no
    /// longer `speaking` or `cancelling`), at most `stopGuard`.
    private func waitForCut() async {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(options.stopGuard) {
            let s = await session.state
            if s != .speaking && s != .cancelling { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

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
    /// A reply asked for speculatively: its audio is held until the turn is over (tune 4).
    case speculated
    /// Not speculative: confirmed already (`late`: past `confirmMax`; else the window
    /// passed with nobody talking), or another response was in flight (`busy`).
    case speculationSkipped(late: Bool, busy: Bool = false)
    /// The held reply plays: how long its first audio waited, the quiet since their last
    /// voiced frame, whether only `confirmMax` let it go, whether audio had arrived.
    case speculationReleased(heldMs: Int, quietMs: Int, overdue: Bool, ready: Bool)
    /// The held reply was dropped unheard ("speech": they went on; "taken back":
    /// unfinished words, a command, not for her; "voice-…": the voice dropped it).
    case speculationDropped(String)
    /// Her reply voiced the unfinished-words aim ("Want to finish the sentence?"):
    /// taken back unheard (tune 5).
    case unfinishedAim(takenBack: Bool)
    /// She stopped before a sentence past the cap (tune 4).
    case sentenceCapStop
    /// A committed item that is only the empty tail of the burst before it: no turn,
    /// never answered blind (tune 6).
    case tailIgnored
    /// No request for a turn that a reply already asked for after it answers (tune 6:
    /// exactly one answer per turn).
    case covered
    /// Her reply sends them to an app, a clock, a forecast or a calendar (tune 6): taken
    /// back unheard in its first sentence (`takenBack`), else she stops before it.
    case appReferral(takenBack: Bool)
    /// Over her voice, the first words that cannot become a backchannel decided the turn
    /// before they settled (tune 6).
    case earlyWords
    /// Her reply frames itself as a robot's report or status ("Tiny robot report: …",
    /// tune 7): taken back unheard in its first sentence (`takenBack`), else she stops before it.
    case selfReport(takenBack: Bool)
    /// Her first sentence only says their question back ("Hi Alex, who made you?", tune 8
    /// T7-4): taken back unheard and asked again once with `answerFirstNote` (`takenBack`).
    case echoedQuestion(takenBack: Bool)
    /// Her sentence tells them she heard them ("I heard you thinking about…", tune 9 T8-5):
    /// taken back unheard in her first sentence (`takenBack`), else she stops before it.
    case heardYou(takenBack: Bool)
    /// Thinking aloud before her answer to their question, unheard (tune 9 T8-4): taken back
    /// and asked again once.
    case thinkingAloud(takenBack: Bool)
    /// A second message item in one response (tune 9 T8-4); she stops before it plays.
    case secondMessage
    case secondMessageStop
    /// Her reply had not started `slowAfter` after it was asked for (a server stall): the
    /// thinking sound played (`clip`) or not (tune 9 T8-2).
    case slowResponse(clip: Bool)
    /// Her reply had not started `stallRetryAfter` after it was asked for: cancelled and
    /// asked for once more (tune 9 T8-2), or (`retried` false) let go — a newer turn of
    /// theirs, or retried once already.
    case stalled(retried: Bool)
}
