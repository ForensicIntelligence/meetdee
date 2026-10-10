import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Synchronization

/// Module namespace for DeeVoice.
public enum DeeVoiceModule {}

/// Dee's voice on the OpenAI realtime API: the one `RealtimeSession` hears, thinks
/// and speaks; this class connects it to Dee's own `AudioGraph` and turns it into
/// the `VoiceEvent`s her face and floor logic understand.
///
/// **Audio.** The microphone (24 kHz PCM16 from `graph.capture`) streams to the
/// session while connected and listening, starting with a pre-roll (2 s on the
/// first connect; exactly the unsent audio after a reconnect or a pause), so the
/// first words are never lost. Her audio (`.assistantAudio`) plays through
/// `graph.player`, the same engine that cancels her echo from the microphone.
///
/// **Who has the floor.** The session reports user speech but never answers or
/// interrupts on its own. `EarCore` decides, with local evidence, whether a
/// server onset during her playback is the user (barge-in: flush the player,
/// `bargeIn(cuts:)` so the server's copy of every item she had playing or queued
/// ends exactly where the listener stopped hearing, then `acceptSpeech`) or her own echo (`rejectEcho`: the item is deleted and the
/// brain never sees it). Audio of a cut response is gated out until the next
/// `.responseStarted`. An interruption (`.playbackCut`) is reported to the
/// server the same way and cancels a reply still on its way. The session hears
/// `playbackFinished` only once her echo tail has passed, so an echo onset
/// right after she stops never preempts a pending reply or initiative. A clip
/// counts as her voice too (`setLocalPlayback`, until its echo tail has passed).
/// **Tune 2.** The uplink is gated (`UplinkGate`): what lies under the room
/// bed's ceiling (a TV across the room, a fan) goes up 30 dB down, so the
/// server never merges a TV with the user. A barge-in over her reply *pauses*
/// her (`FloorHold`): silent at once, nothing cut yet; their words decide — a
/// backchannel (`Backchannel`: "keep going", "mm-hm") and she goes on from
/// exactly there, anything else and the brain's answer (`respond`) ends her
/// reply where she paused (`holdAfterWords` / `holdWordsWait` if nobody does).
/// Her next item never starts while an onset with near-end voice is being
/// decided (`holdAtBoundary`). An item her loud echo opened that the sound
/// can't settle is decided by its words (`HerWords`: her own words → echo).
/// EarCore's local speech onset / end goes to `setLocalSpeech`.
/// The uplink map is kept on the feed stream: each session's timeline starts
/// where `.uplinkOrigin` says, and mic audio the session drops (`.uplinkDropped`,
/// exact frames) is cut out, so server offsets keep mapping onto the right
/// capture audio. Neither event reaches the brain.
///
/// **For the brain** (`brainEvents`, single consumer):
/// - `.session(e)`: every session event except audio deltas, in order, with
///   echo filtered out (`.userSpeechStarted` of an onset over her playback is
///   held until it is known to be the user; nothing of a rejected item gets
///   through, so a `.userCommitted` here is always a real user turn).
/// - `.sentenceStarted` / `.sentenceFinished(heard:)`: her transcript placed on
///   what was actually played (for `deeSaid` and the face).
/// - `.itemPlayed`, `.clipPlayed`, `.connection(VoiceProblem?)`.
///
/// **Asking her to speak**: `respond(cue:instructions:reasoningEffort:)` after `.userCommitted`,
/// `initiative(instructions:)`, `say(_:)`; settings and tools through `session`
/// directly (`updateSession`, `setToolHandler`, `recentTurns`). Never call the
/// session's `bargeIn`, `playbackFinished`, `rejectEcho`, `acceptSpeech`,
/// `setLocalPlayback`, `feedAudio` / `appendAudio` or `connect` / `close`
/// yourself: this class owns them.
///
/// Offline there is no other voice: `.listening(false)`, a `.connection` problem,
/// `.error` text; the eyes, touch, camera and local sound events keep working,
/// and the session is reconnected with back-off (until a key problem, which
/// waits for `reconnect()`).
public final class CloudVoice: VoiceIO, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Seconds of microphone audio sent ahead of the first live chunk on connect.
        public var prerollSeconds = 2.0
        /// With listening off, sustained local voice still reaches the server.
        public var wakeOnVoice = true
        /// Run SoundAnalysis on the microphone (`.sound` events).
        public var classifySounds = true
        /// Emit `.partial` from the server's transcript deltas. They arrive after the
        /// turn was committed (there are no live partials in a speech-to-speech
        /// session), so they are not a "the user is talking" signal; off by default.
        public var partialsFromTranscriptDeltas = false
        /// Back-off between connect attempts (the last value repeats).
        public var connectRetryDelays: [Double] = [1, 2, 4, 8, 15, 30]
        /// Run the 30 Hz housekeeping timer (tests drive `tick()` themselves).
        public var autoTick = true
        /// Attenuate what is only the room's bed (a TV, a fan) before it is sent
        /// (`UplinkGate`): the server's VAD then never merges a TV with the user.
        public var gateUplink = true
        /// A barge-in over her reply pauses her (`FloorHold`) until their words are
        /// known: a backchannel ("keep going", "mm-hm") lets her go on from exactly
        /// there; anything else ends the reply where she paused. Off: every
        /// barge-in cuts her at once (the words never matter).
        public var holdOnBargeIn = true

        public init() {}
    }

    /// Her reply paused for the user (a barge-in whose words aren't known yet).
    /// What they said may arrive as several items (the server splits "Don't
    /// stop. … Keep going."); all of them decide together.
    public struct FloorHold: Sendable, Equatable {
        /// The latest user item of the hold (nil until the server opens one).
        public var itemID: String?
        /// Every user item of the hold, in order.
        public private(set) var items: [String] = []
        /// When her voice paused (graph clock).
        public var since: Double
        /// Their words per item: settled deltas so far, and the final transcripts.
        var partial: [String: String] = [:]
        var final: [String: String] = [:]
        public var lastDeltaAt: Double?
        /// The server's end of the latest item's speech, when it came.
        public var speechStoppedAt: Double?
        /// Their words came and were not "go on": the brain answers them.
        public var wordsAt: Double?
        /// The latest item was committed.
        public var committed = false
        var commitSent = false

        public init(itemID: String?, since: Double) {
            self.since = since
            if let itemID { add(itemID) }
        }

        /// Their words so far, all items.
        public var text: String {
            items.compactMap { final[$0] ?? partial[$0] }.joined(separator: " ")
        }

        mutating func add(_ item: String) {
            guard !items.contains(item) else { return }
            items.append(item)
            itemID = item
            speechStoppedAt = nil
            committed = false
            commitSent = false
        }

        mutating func remove(_ item: String) {
            items.removeAll { $0 == item }
            partial[item] = nil
            final[item] = nil
            if itemID == item { itemID = items.last }
        }

        enum Verdict: Equatable { case wait, resume, answer }

        /// What their words say so far. `settled`: partial words count (no new
        /// delta for `holdSettle`); `quiet`: they aren't talking now.
        func verdict(settled: Bool, quiet: Bool) -> Verdict {
            var anyBackchannel = false, undecided = false
            for item in items {
                let words = final[item] ?? (settled ? partial[item] : nil)
                guard let words else { undecided = true; continue }
                let clean = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty { continue }                       // nothing was said in it
                if !Backchannel.isBackchannel(clean) { return .answer }
                anyBackchannel = true
            }
            return anyBackchannel && (!undecided || quiet) ? .resume : .wait
        }
    }

    /// Settled transcription deltas this old decide a hold (the brain's `partialSettle`).
    public static let holdSettle = 0.15
    /// A hold never lasts longer than this: her reply then ends where she paused.
    public static let holdMax = 6.0
    /// …nor this long after their speech stopped without words that say "go on".
    public static let holdWordsWait = 2.5
    /// A hold with no server item for it ends after this.
    public static let holdNoItem = 2.0
    /// Words that weren't "go on" and nobody answered them: her reply ends this
    /// long after they came.
    public static let holdAfterWords = 1.0
    /// While she is held and the server has stopped their speech but holds the
    /// commit (semantic end of turn: up to ~2 s), their voice heard locally
    /// ending this long ago commits it at once (`commitUserSpeech`): the words
    /// that decide come sooner, so a "go on" pauses her briefly. Never before the
    /// server's `speech_stopped` (a commit mid-speech splits their words). Her
    /// voice is silent in a hold: the local end of speech is clean.
    public static let holdCommitSilence = 0.3

    /// What the brain (RealtimeBrain) consumes.
    public enum BrainEvent: Sendable, Equatable {
        /// A session event (no audio deltas; echo filtered out).
        case session(RealtimeEvent)
        /// Playback reached the start of sentence `index` of her item.
        case sentenceStarted(itemID: String, index: Int, text: String)
        /// Playback passed the end of the sentence (`heard: true`), or the item was
        /// cut inside it (`heard`: its midpoint was played). An item whose response
        /// didn't complete (socket lost, failed, filtered, token limit) counts as
        /// cut where its audio ran out: the transcript may run ahead of the audio.
        case sentenceFinished(itemID: String, index: Int, text: String, heard: Bool)
        /// One of her items stopped playing: all of it, or `cut` after `playedMs`
        /// (flushed, or its response ended before it was complete).
        case itemPlayed(itemID: String, playedMs: Int, cut: Bool)
        /// A clip finished (or was cut). Clips are local: the session only knows
        /// that something of hers is playing (for echo), never what; mention them
        /// in the next cue if they matter.
        case clipPlayed(VoiceClip, cut: Bool)
        /// The cloud voice's health for `VoiceHealth.cloudVoice(_:)` (nil = fine).
        case connection(VoiceProblem?)
    }

    public let session: RealtimeSession
    public let graph: AudioGraph
    public let clips: ClipCache?
    public let timeline: TurnTimeline
    public let configuration: Configuration

    private let stream: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation
    public let brainEvents: AsyncStream<BrainEvent>
    private let brain: AsyncStream<BrainEvent>.Continuation
    private let commands: AsyncStream<Command>.Continuation
    private let commandStream: AsyncStream<Command>

    private let inner = Mutex(Inner())
    private let sounds = SoundClassifier()
    private let control = DispatchQueue(label: "dee.voice.cloud", qos: .userInitiated)
    private var timer: DispatchSourceTimer?        // control-queue confined
    private let tasks = Mutex<[Task<Void, Never>]>([])

    private enum Command: Sendable {
        case bargeIn(cuts: [(itemID: String, playedMs: Int)])
        case playbackFinished
        case rejectEcho(String)
        case acceptSpeech(String)
        case localPlayback(Bool)
        case localSpeech(Bool)
        case commitSpeech
        case cancelUnspoken
        case run(@Sendable (RealtimeSession) async -> Void)
    }

    private struct Inner {
        var core = EarCore()
        var started = false
        var shutDown = false
        var audioUp = false
        var connected = false
        var connectLoopRunning = false
        var needsSetup = false
        var problem: VoiceProblem?

        var map = UplinkMap()
        var uplinkGate = UplinkGate()
        var uplinkOpen = false
        var uplinkGeneration = 0

        /// Assistant audio is accepted (closed after a cut or stop until the next response).
        var gate = ReplyGate()
        var responseKind: ResponseKind?
        var responseHasAudio = false
        /// Her items queued or playing, in order.
        var sessionItems: [String] = []
        var lastSessionItem: String?
        /// The session believes her audio is playing (until `playbackFinished` / `bargeIn`).
        var sessionPlaying = false
        var clips: [String: VoiceClip] = [:]
        var clipCounter = 0
        var laughVariant = 0
        var sentences = SentenceClock()
        var partials: [String: String] = [:]
        /// `.userSpeechStarted` held until the onset is known to be the user.
        var heldStarts: [String: RealtimeEvent] = [:]
        /// User items rejected as echo (their events are dropped); bounded.
        var rejected: Set<String> = []
        var rejectedOrder: [String] = []
        /// Her last item played out: the session hears `playbackFinished` only once
        /// her echo has left the room, so it never takes that echo for the user.
        var finishDueAt: Double?
        /// A response is open (between `.responseStarted` and `.responseDone`).
        var responseOpen = false
        /// Items whose audio the server finished (`assistantAudioDone`).
        var audioDone: Set<String> = []
        /// Items of finished responses: true when the response completed normally.
        var itemCompleted: [String: Bool] = [:]
        var lastDoneCompleted = true
        /// Items that played out before their response's end status was known.
        var playedOut: [(item: String, ms: Int)] = []
        /// The session was told a clip is playing (`setLocalPlayback`); it hears
        /// the end once the clip's echo has left the room (`localOffDueAt`).
        var localOn = false
        var localOffDueAt: Double?

        var slicer = FrameSlicer(frameSize: 1)
        var sliceRate = 0.0

        /// Her reply is paused for a barge-in whose words decide (`FloorHold`).
        var hold: FloorHold?
        /// What she said lately (her echo's words), for items her words decide.
        var herWords = HerWords()
        /// Items whose words decide whether they are hers (`deferToWords`): their
        /// session events, held back from the brain until then, and since when.
        var wordsPending: [String: (since: Double, events: [RealtimeEvent], strict: Bool)] = [:]
    }

    /// An item waiting for its words is given up on (deleted as her echo) after this.
    public static let wordsWait = 5.0

    static let frameSeconds = 0.04

    /// - Parameters:
    ///   - session: configured (voice, instructions, tools) but not connected.
    ///   - graph: Dee's audio graph (`AudioGraph()` from the environment by default).
    ///   - clips: pre-rendered laughs and short lines (nil: no clips).
    public init(session: RealtimeSession, graph: AudioGraph = AudioGraph(), clips: ClipCache? = nil,
                timeline: TurnTimeline = .shared, configuration: Configuration = Configuration()) {
        self.session = session
        self.graph = graph
        self.clips = clips
        self.timeline = timeline
        self.configuration = configuration
        (stream, continuation) = AsyncStream<VoiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (brainEvents, brain) = AsyncStream<BrainEvent>.makeStream(bufferingPolicy: .unbounded)
        (commandStream, commands) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        inner.withLock { $0.core.wakeOnVoice = configuration.wakeOnVoice }
        graph.player.timeline = timeline                 // `.firstAudioPlayed` / `.flushed` land in the same turns
        wire()
    }

    // MARK: VoiceIO

    public var events: AsyncStream<VoiceEvent> { stream }

    public var userIsSpeaking: Bool {
        let t = graph.now
        return inner.withLock { $0.core.userIsSpeaking(at: t) }
    }

    public var listeningEnabled: Bool {
        get { inner.withLock { $0.core.listeningEnabled } }
        set {
            let t = graph.now
            inner.withLock { s in apply(s.core.setListeningEnabled(newValue, at: t), &s) }
        }
    }

    public var pauseScale: Double {
        get { inner.withLock { $0.core.pauseScale } }
        set { inner.withLock { $0.core.pauseScale = newValue } }
    }

    /// Her reply paused for the user right now (nil: not paused). While held she
    /// is silent, nothing is cut yet, and `.bargeIn` hasn't been emitted.
    public var floorHold: FloorHold? { inner.withLock { $0.hold } }

    /// The words over her voice were a backchannel: she goes on from where she
    /// paused. No-op without a hold. Returns whether she resumed.
    @discardableResult
    public func continueAfterBackchannel() -> Bool {
        let t = graph.now
        return inner.withLock { s in
            guard s.hold != nil else { return false }
            resumeHold(&s, at: t, why: "brain")
            return true
        }
    }

    /// The cloud voice's current problem (nil when it works).
    public var problem: VoiceProblem? { inner.withLock { $0.problem } }

    /// The session is connected (and hearing her, when listening).
    public var isConnected: Bool { inner.withLock { $0.connected } }

    /// Asks for the microphone, starts the audio graph (`.ready`), the session
    /// pumps and the connection (`.listening(true)` once connected).
    public func start() async {
        let go = inner.withLock { s -> Bool in
            guard !s.started, !s.shutDown else { return false }
            s.started = true
            return true
        }
        guard go else { return }
        startPumps()

        let injecting = graph.configuration.injection != nil
        var permission = true
        if !graph.isManual && !injecting {
            #if os(iOS)
            let hasKey = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            if !hasKey { emit(.error("Missing NSMicrophoneUsageDescription; Dee can't listen.")) }
            permission = hasKey ? await AVAudioApplication.requestRecordPermission() : false
            #else
            permission = await AVAudioApplication.requestRecordPermission()
            #endif
        }
        let mic = permission || injecting || graph.isManual
        emit(.permission(microphone: mic, speech: true))
        let t0 = graph.now
        inner.withLock { s in apply(s.core.setMicrophone(mic, at: t0), &s) }
        graph.capture.isEnabled = true

        let facts = await graph.start(microphone: permission)
        if let facts {
            applied(facts)
            audioCameUp()
        }
        startConnecting()
    }

    public func shutdown() {
        let first = inner.withLock { s -> Bool in
            guard !s.shutDown else { return false }
            s.shutDown = true
            s.uplinkOpen = false
            s.uplinkGeneration += 1
            return true
        }
        guard first else { return }
        control.sync {
            timer?.cancel()
            timer = nil
        }
        sounds.stop()
        graph.capture.close()
        let session = self.session
        Task { await session.close() }
        graph.shutdown()
        commands.finish()
        continuation.finish()
        brain.finish()
        tasks.withLock { list in list.forEach { $0.cancel() } }
    }

    @discardableResult
    public func play(_ clip: VoiceClip, deferWhileUserSpeaks: Bool) -> Bool {
        guard let pcm = clips?.pcm(clip) else { return false }
        let t = graph.now
        return inner.withLock { s -> Bool in
            guard s.started, !s.shutDown, s.audioUp else { return false }
            // Never over (or queued ahead of) her own reply, nor while an initiative
            // is on its way (its echo would read as the user beating it).
            guard !s.sessionPlaying, s.sessionItems.isEmpty, !s.core.initiativePending else { return false }
            if deferWhileUserSpeaks, s.core.userIsSpeaking(at: t) { return false }
            s.clipCounter += 1
            let id = "clip-\(s.clipCounter)-\(clip.rawValue)"
            s.clips[id] = clip
            // Her own voice for the session's echo logic: an onset over the clip
            // must not preempt a reply being generated (the laugh at a joke).
            s.localOffDueAt = nil
            if !s.localOn {
                s.localOn = true
                command(.localPlayback(true))
            }
            graph.player.enqueue(pcm, utterance: id)
            graph.player.finish(utterance: id)
            return true
        }
    }

    public func laugh(intensity: Double = 0.6, age: Double? = nil, energy: Double = 0.7) {
        let variant = inner.withLock { s -> Int in s.laughVariant &+= 1; return s.laughVariant }
        play(VoiceClip.laugh(intensity: intensity, variant: variant), deferWhileUserSpeaks: false)
    }

    public func stopSpeaking() {
        let t = graph.now
        inner.withLock { s in
            s.core.initiativePending = false
            if s.sessionPlaying {
                cutReply(&s)
            } else {
                // Nothing of a reply has played: cancel one still being generated; if
                // its first audio was already on the way, it is dropped on arrival.
                closeGateBeforeAudio(&s, at: t)
                graph.player.flush()
                command(.cancelUnspoken)
            }
        }
    }

    @discardableResult
    public func stopClip() -> Bool {
        inner.withLock { s in
            // Only clips in the player: a reply playing or queued is left alone.
            guard !s.clips.isEmpty, !s.sessionPlaying, s.sessionItems.isEmpty else { return false }
            graph.player.flush()
            return true
        }
    }

    // MARK: Asking her to speak (for the brain)

    /// Answers the committed user turn (call on `.session(.userCommitted)`). `cue`
    /// goes in first as a system item; `instructions` override the session's for
    /// this response. If her previous reply is somehow still playing it is cut
    /// first (the server is told what was heard), so the new audio never queues
    /// behind it. `reasoningEffort` (`minimal` … `xhigh`) sets `reasoning.effort`
    /// for this response only (nil: the session's). Throws `RealtimeSessionError`.
    @discardableResult
    public func respond(cue: String? = nil, instructions: String? = nil,
                        maxOutputTokens: Int? = nil, reasoningEffort: String? = nil) async throws -> RequestOutcome {
        inner.withLock { s in
            if s.sessionPlaying { cutReply(&s) }
            s.gate.requested()
        }
        let timeline = self.timeline
        let graph = self.graph
        let result: Result<RequestOutcome, Error> = await run { session in
            timeline.mark(.responseCreateSent, at: graph.now)
            do {
                return .success(try await session.requestResponse(cueItem: cue, instructions: instructions,
                                                                  maxOutputTokens: maxOutputTokens,
                                                                  reasoningEffort: reasoningEffort))
            } catch {
                return .failure(error)
            }
        } ?? .failure(RealtimeSessionError.closed)
        return try result.get()
    }

    /// Dee speaks first. Refused locally while the user is talking (local voice or
    /// open server speech) or while anything of hers is playing; cancelled if the
    /// user starts talking before its first audio (locally, ahead of the server).
    /// `reasoningEffort` as for `respond`.
    @discardableResult
    public func initiative(instructions: String, cue: String? = nil,
                           maxOutputTokens: Int? = nil, reasoningEffort: String? = nil) async -> InitiativeOutcome {
        let t = graph.now
        let refusal = inner.withLock { s -> InitiativeOutcome.Refusal? in
            if s.shutDown || !s.connected { return .notConnected }
            if s.core.userIsSpeaking(at: t) { return .userSpeaking }
            // Also while her echo is still in the room: it would read as the user.
            if s.sessionPlaying || graph.player.isBusy || s.core.herVoiceInRoom(at: t) { return .speaking }
            s.core.initiativePending = true
            s.gate.requested()
            return nil
        }
        if let refusal { return .refused(refusal) }
        let timeline = self.timeline
        let graph = self.graph
        let outcome = await run { session in
            let o = await session.initiative(instructions: instructions, cueItem: cue, maxOutputTokens: maxOutputTokens,
                                             reasoningEffort: reasoningEffort)
            if o == .sent { timeline.mark(.responseCreateSent, at: graph.now, detail: "initiative") }
            return o
        } ?? .refused(.notConnected)
        if outcome != .sent { inner.withLock { $0.core.initiativePending = false } }
        return outcome
    }

    /// A line she should say (nearly) word for word, as an initiative: the model
    /// speaks it in her session voice. Same gating as `initiative`.
    @discardableResult
    public func say(_ line: String, cue: String? = nil) async -> InitiativeOutcome {
        let quoted = line.replacingOccurrences(of: "\"", with: "'")
        return await initiative(
            instructions: "Say exactly this, word for word, in your own voice, and nothing else: \"\(quoted)\"",
            cue: cue, maxOutputTokens: 400)
    }

    /// Connect again after a key problem (the key sheet saved a new key) or to
    /// retry at once.
    public func reconnect() {
        inner.withLock { $0.needsSetup = false }
        startConnecting()
    }

    // MARK: Test / harness hooks

    /// What the ear was told about the route (echo cancellation, output latency).
    var earFacts: (aec: Bool, latency: Double) {
        inner.withLock { ($0.core.aecActive, $0.core.outputLatency) }
    }

    /// Tests: the undecided onset `item` is left to its words (`deferToWords`).
    func deferToWordsForTesting(_ item: String) {
        inner.withLock { s in apply(s.core.deferToWordsNow(item), &s) }
    }

    /// Items waiting for their words to decide them (tests, harness).
    var itemsAwaitingWords: Set<String> { inner.withLock { Set($0.wordsPending.keys) } }

    /// The echo path the ear has learned: delay (s) and gain (dB), nil until known.
    public var learnedEcho: (delay: Double?, gainDB: Double?) {
        inner.withLock { ($0.core.echo.delay, $0.core.echo.gainDB) }
    }

    /// The uplink gate: its bar (dBFS; nil = everything sent as is) and the audio
    /// sent attenuated / at full level so far (ms), for the harness or reports.
    public var uplinkGateState: (barDB: Double?, closedMs: Int, openMs: Int) {
        inner.withLock { s in
            (s.uplinkGate.barDB, Int(s.uplinkGate.closedFrames / 24), Int(s.uplinkGate.openFrames / 24))
        }
    }

    /// Housekeeping: speech level at ~30 Hz, decision deadlines, sentence progress.
    /// Driven by a timer unless `configuration.autoTick` is false.
    public func tick() {
        let t = graph.now
        inner.withLock { s in
            apply(s.core.tick(at: t), &s)
            if let due = s.finishDueAt, t >= due {
                s.finishDueAt = nil
                if !s.sessionPlaying, s.sessionItems.isEmpty { command(.playbackFinished) }
            }
            if let due = s.localOffDueAt, t >= due {
                s.localOffDueAt = nil
                if s.localOn, s.clips.isEmpty {
                    s.localOn = false
                    command(.localPlayback(false))
                }
            }
            for item in s.sentences.playingItems {
                let ms = graph.player.playedMs(utterance: item)
                for e in s.sentences.progress(item, playedMs: ms) { brain.yield(Self.brainEvent(e)) }
            }
            checkHold(&s, at: t)
            for (item, w) in s.wordsPending where t - w.since >= Self.wordsWait {
                mark(.note, detail: "no words for \(item): her echo")
                wordsDecided(item, user: false, &s)
            }
        }
    }

    /// A hold's deadlines and settled words.
    private func checkHold(_ s: inout Inner, at t: Double) {
        guard let h = s.hold else { return }
        let quiet = t - s.core.lastUserSoundTime >= Self.holdCommitSilence
        if h.itemID != nil, h.speechStoppedAt != nil, !h.committed, !h.commitSent, h.wordsAt == nil, quiet {
            // The server stopped their speech and they are quiet: their words now,
            // not after the server's end-of-turn hold.
            s.hold?.commitSent = true
            command(.commitSpeech)
        }
        let settled = h.lastDeltaAt.map { t - $0 >= Self.holdSettle - 1e-9 } ?? false
        switch h.verdict(settled: settled, quiet: quiet) {
        case .resume:
            resumeHold(&s, at: t, why: "words")
            return
        case .answer:
            // They meant it: the brain answers (`respond` ends her reply where she
            // paused); if nobody does, `holdAfterWords` does.
            if h.wordsAt == nil { s.hold?.wordsAt = t }
        case .wait:
            break
        }
        guard let h = s.hold else { return }
        if t - h.since >= Self.holdMax - 1e-9
                    || (h.speechStoppedAt.map { t - $0 >= Self.holdWordsWait - 1e-9 } ?? false)
                    || (h.wordsAt.map { t - $0 >= Self.holdAfterWords - 1e-9 } ?? false)
                    || (h.itemID == nil && t - h.since >= Self.holdNoItem - 1e-9) {
            mark(.note, detail: "hold ended by the voice \(h.itemID ?? "-")")
            cutReply(&s, announce: true)
        }
    }

    // MARK: Wiring

    private func wire() {
        graph.addMicConsumer { [weak self] buffer, t in self?.handleInput(buffer, at: t) }
        graph.player.addObserver { [weak self] e in self?.handlePlayer(e) }
        graph.addObserver { [weak self] e in self?.handleGraph(e) }
        sounds.onResult = { [weak self] results, window in
            guard let self else { return }
            let t = self.graph.now
            self.inner.withLock { s in self.apply(s.core.classified(results, window: window, at: t), &s) }
        }
        sounds.onError = { [weak self] message in self?.emit(.error(message)) }
    }

    private func startPumps() {
        let session = self.session
        let events = Task { [weak self] in
            for await e in session.events {
                guard let self else { return }
                self.handleSession(e)
            }
        }
        let timeline = self.timeline
        let graph = self.graph
        let commandsTask = Task { [commandStream] in
            for await c in commandStream {
                switch c {
                case .bargeIn(let cuts):
                    let o = await session.bargeIn(cuts: cuts)
                    if o.cancelledResponse { timeline.mark(.cancelSent, at: graph.now) }
                    for cut in o.truncations {
                        let at = graph.now
                        timeline.mark(.truncateSent, at: at, detail: "\(cut.itemID) audio_end_ms=\(cut.audioEndMs)")
                        // What the server keeps of it (HeardRule; SentenceClock reports the same).
                        timeline.mark(.note, at: at, detail: "heard \(cut.itemID) sentences=\(cut.heardSentences)")
                    }
                case .playbackFinished:
                    await session.playbackFinished()
                case .rejectEcho(let id):
                    await session.rejectEcho(itemID: id)
                case .acceptSpeech(let id):
                    await session.acceptSpeech(itemID: id)
                case .localPlayback(let on):
                    await session.setLocalPlayback(on)
                case .localSpeech(let on):
                    await session.setLocalSpeech(on)
                case .commitSpeech:
                    if await session.commitUserSpeech() { timeline.mark(.note, at: graph.now, detail: "early commit (hold)") }
                case .cancelUnspoken:
                    _ = await session.cancelUnspokenResponse()
                case .run(let body):
                    await body(session)
                }
            }
        }
        // The command pump is not cancelled at shutdown: it drains, so every
        // `run` caller gets its answer.
        _ = commandsTask
        tasks.withLock { $0.append(events) }
        if configuration.autoTick { startTimer() }
    }

    private func startTimer() {
        control.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.control)
            timer.schedule(deadline: .now() + 0.05, repeating: 1.0 / 30, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Runs `body` on the session in command order; nil after shutdown.
    private func run<T: Sendable>(_ body: @escaping @Sendable (RealtimeSession) async -> T) async -> T? {
        let box = Mutex<CheckedContinuation<T?, Never>?>(nil)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            box.withLock { $0 = c }
            let result = commands.yield(.run { session in
                let value = await body(session)
                box.withLock { $0.take() }?.resume(returning: value)
            })
            if case .terminated = result { box.withLock { $0.take() }?.resume(returning: nil) }
        }
    }

    private func command(_ c: Command) { commands.yield(c) }

    // MARK: Connection

    private func startConnecting() {
        let go = inner.withLock { s -> Bool in
            guard s.started, !s.shutDown, !s.connectLoopRunning, !s.needsSetup else { return false }
            s.connectLoopRunning = true
            return true
        }
        guard go else { return }
        let t = Task { [weak self] in
            guard let self else { return }
            await self.connectLoop()
        }
        tasks.withLock { $0.append(t) }
    }

    private func connectLoop() async {
        defer { inner.withLock { $0.connectLoopRunning = false } }
        var attempt = 0
        while !Task.isCancelled {
            guard inner.withLock({ !$0.shutDown && !$0.needsSetup }) else { return }
            var wait: Double?
            do {
                try await session.connect()
                return
            } catch let e as RealtimeSessionError {
                switch e {
                case .noKey:
                    setProblem(.cloudVoiceNeedsSetup("No OpenAI key."), setup: true)
                    return
                case .unauthorized(let m):
                    setProblem(.cloudVoiceNeedsSetup("The OpenAI key was refused\(m.map { ": \($0)" } ?? ".")"), setup: true)
                    return
                case .closed:
                    return
                case .rateLimited(let after):
                    wait = after
                    setProblem(.cloudVoiceUnavailable("Rate limited."), setup: false)
                default:
                    setProblem(.cloudVoiceUnavailable(Self.describe(e)), setup: false)
                }
            } catch {
                setProblem(.cloudVoiceUnavailable("\(error)"), setup: false)
            }
            let delays = configuration.connectRetryDelays.isEmpty ? [5.0] : configuration.connectRetryDelays
            let delay = max(wait ?? 0, delays[min(attempt, delays.count - 1)])
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func setProblem(_ p: VoiceProblem?, setup: Bool?) {
        inner.withLock { s in
            if let setup { s.needsSetup = setup }
            guard s.problem != p else { return }
            s.problem = p
            brain.yield(.connection(p))
            if let p { voice(.error("Cloud voice: \(p.message) (\(Self.detail(p)))"), &s) }
        }
    }

    static func detail(_ p: VoiceProblem) -> String {
        switch p {
        case .cloudVoiceUnavailable(let d), .cloudVoiceNeedsSetup(let d): d
        default: p.message
        }
    }

    static func describe(_ e: RealtimeSessionError) -> String {
        switch e {
        case .notConnected: "not connected"
        case .responseInFlight: "busy"
        case .noKey: "no key"
        case .unauthorized(let m): "unauthorized \(m ?? "")"
        case .rateLimited: "rate limited"
        case .socket(let f): "\(f)"
        case .configRejected(let m): "session rejected: \(m ?? "")"
        case .timeout: "timed out"
        case .closed: "closed"
        }
    }

    // MARK: Session events (the event pump)

    private func handleSession(_ e: RealtimeEvent) {
        let t = graph.now
        inner.withLock { s in
            var forward = true
            // Her words, as they are generated: an item her echo opened is judged by them.
            switch e {
            case .assistantTranscriptDelta(_, let delta): s.herWords.add(delta, at: t)
            default: break
            }
            switch e {
            case .uplinkOrigin(let frame):
                // The new session's clock starts at this point of what was fed
                // (possibly audio fed before this event was handled): rebase.
                s.map.reset(originFeedFrame: Int64(frame))
                forward = false
            case .connected:
                s.connected = true
                if s.problem != nil {
                    s.problem = nil
                    brain.yield(.connection(nil))
                }
                apply(s.core.setConnected(true, at: t), &s)
            case .disconnected:
                s.connected = false
                if s.hold != nil {
                    // Nothing more comes for her reply: it ends where she paused.
                    graph.player.flush()
                    releaseHold(&s, announce: true)
                }
                apply(s.core.setConnected(false, at: t), &s)
                // What was received still plays; nothing more will come. Its
                // response never completed: sentences beyond the audio weren't said.
                for item in s.sessionItems { graph.player.finish(utterance: item) }
                s.sessionPlaying = false
                s.finishDueAt = nil
                s.heldStarts.removeAll()
                s.wordsPending.removeAll()
                s.responseOpen = false
                s.lastDoneCompleted = false
                resolvePlayedOut(&s)
            case .rolledOver:
                break                                // the map was rebased at `.uplinkOrigin`
            case .stateChanged(let state):
                if state == .idle, s.started, !s.shutDown, !s.needsSetup {
                    // The session gave up (or never connected): keep trying.
                    let go = !s.connectLoopRunning
                    if go { control.async { [weak self] in self?.startConnecting() } }
                }

            case .userSpeechStarted(let item, let ms):
                let onset = s.map.captureFrame(serverMs: ms).map { graph.capture.hostTime(ofFrame: $0) }
                let actions = s.core.serverSpeechStarted(itemID: item, onset: onset, at: t)
                if s.core.isDeciding(item) {
                    s.heldStarts[item] = e
                    forward = false
                    timeline.mark(.bargeInSpeechStarted, at: onset ?? t, detail: item)
                } else {
                    timeline.mark(.speechStarted, at: onset ?? t, detail: item)
                }
                if forward { brain.yield(.session(e)); forward = false }
                apply(actions, &s)
                if s.hold != nil, !s.rejected.contains(item), s.heldStarts[item] == nil {
                    // More of what they say over her: it decides the hold too.
                    s.hold?.add(item)
                }
                if s.heldStarts[item] == nil, !s.rejected.contains(item) {
                    // Not held: it is the user (for instance just after a clip she
                    // gave way with, whose echo window is still open). The session
                    // may still count it as possibly her echo: say it is not.
                    command(.acceptSpeech(item))
                }
            case .userSpeechStopped(let item, let ms):
                let end = s.map.captureFrame(serverMs: ms).map { graph.capture.hostTime(ofFrame: $0) }
                apply(s.core.serverSpeechStopped(itemID: item, end: end, at: t), &s)
                if s.hold?.itemID == item { s.hold?.speechStoppedAt = t }
                if s.wordsPending[item] != nil {
                    s.wordsPending[item]?.events.append(e)
                    forward = false
                } else if s.rejected.contains(item) {
                    forward = false
                } else {
                    timeline.beginTurn(.speechStopped, at: end.map { min($0, t) } ?? t, detail: item)
                }
            case .userCommitted(let item, _):
                if s.hold?.itemID == item { s.hold?.committed = true }
                if s.wordsPending[item] != nil {
                    s.wordsPending[item]?.events.append(e)
                    forward = false
                } else if s.rejected.contains(item) { forward = false } else { mark(.committed, detail: item) }
            case .userTranscriptDelta(let item, let delta):
                if s.hold?.items.contains(item) == true {
                    s.hold?.partial[item, default: ""] += delta
                    s.hold?.lastDeltaAt = t
                }
                if s.wordsPending[item] != nil {
                    s.wordsPending[item]?.events.append(e)
                    forward = false
                } else if s.rejected.contains(item) {
                    forward = false
                } else if configuration.partialsFromTranscriptDeltas {
                    let text = (s.partials[item] ?? "") + delta
                    s.partials[item] = text
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { voice(.partial(clean), &s) }
                }
            case .userTranscript(let item, let text):
                s.partials[item] = nil
                if let pending = s.wordsPending[item] {
                    let user = !s.herWords.isHerEcho(text, at: t, strict: pending.strict)
                    mark(.note, detail: "words of \(item): \(user ? "the user" : "her echo")")
                    wordsDecided(item, user: user, &s)
                    if user, s.sessionPlaying, s.hold == nil, !Backchannel.isBackchannel(text) {
                        // They were talking to her under her loud echo: she goes quiet now;
                        // the brain answers them (which ends her reply where she paused).
                        graph.player.hold()
                        s.hold = FloorHold(itemID: item, since: graph.now)
                        mark(.note, detail: "hold \(item) (words)")
                    }
                }
                if s.rejected.contains(item) {
                    forward = false
                } else {
                    mark(.transcript, detail: item)
                    apply(s.core.serverTranscript(itemID: item, text: text, at: t), &s)
                    if s.hold?.items.contains(item) == true {
                        s.hold?.final[item] = text
                        checkHold(&s, at: t)
                    }
                }
            case .userTranscriptFailed(let item, _):
                s.partials[item] = nil
                if s.wordsPending[item] != nil { wordsDecided(item, user: false, &s) }
                if s.rejected.contains(item) { forward = false }
                if s.hold?.items.contains(item) == true {
                    s.hold?.final[item] = ""                     // nothing to go on: the deadlines decide
                }
            case .echoRejected(let item):
                s.wordsPending[item] = nil
                markRejected(item, &s)
                s.core.forget(item)
                s.heldStarts[item] = nil
                if s.hold?.items.contains(item) == true {
                    s.hold?.remove(item)
                    if s.hold?.items.isEmpty == true { resumeHold(&s, at: t, why: "echo") }
                }
                forward = false                      // nothing of a rejected item reaches the brain

            case .responseStarted(let id, let kind):
                s.responseOpen = true
                // Stopped before we saw it start (its events were still in the pump)?
                if s.gate.responseStarted(at: t) { mark(.note, detail: "response \(id) was stopped before it started") }
                s.responseKind = kind
                s.responseHasAudio = false
                mark(.responseCreated, detail: kind.rawValue)
            case .assistantAudio(let item, let pcm):
                forward = false
                receiveAudio(item: item, pcm: pcm, at: t, &s)
            case .assistantAudioDone(let item, _):
                s.audioDone.insert(item)
                graph.player.finish(utterance: item)
            case .assistantSentence(let item, let text, let hint):
                for ev in s.sentences.add(itemID: item, text: text, endMs: hint) { brain.yield(Self.brainEvent(ev)) }
            case .responseDone(let summary):
                // Nothing more comes for this response: play out what arrived.
                for item in s.sessionItems { graph.player.finish(utterance: item) }
                if summary.kind == .initiative { s.core.initiativePending = false }
                // Only a completed response said all of its transcript; a cancelled,
                // failed or cut-short one said what of it was played.
                let completed = summary.status == "completed"
                for id in summary.itemIDs { s.itemCompleted[id] = completed }
                s.lastDoneCompleted = completed
                s.responseOpen = false
                resolvePlayedOut(&s)
                mark(.responseDone, detail: "\(summary.status) \(summary.reason ?? "")")

            case .uplinkDropped(let frames, let feedAt, let at):
                // Audio the map counted as fed never reached the server: cut it
                // out by its exact feed position (later server offsets sit that
                // much earlier). A drop before the current origin is a no-op.
                s.map.dropped(atFeedFrame: Int64(feedAt), frames: Int64(frames))
                mark(.note, detail: "uplink dropped \(frames / 24) ms at \(at.map(String.init) ?? "-")")
                forward = false
            case .fallbackAdvised(let reason):
                if let (p, setup) = Self.problem(for: reason) {
                    if let setup { s.needsSetup = setup }
                    if s.problem != p {
                        s.problem = p
                        brain.yield(.connection(p))
                    }
                }
                voice(.error("Cloud voice: \(Self.describe(reason))"), &s)
            case .error(let issue):
                voice(.error("Cloud voice error (\(issue.kind.rawValue)): \(issue.message ?? issue.code ?? "unknown")"), &s)

            case .recovered, .assistantTranscriptDelta, .assistantTranscript, .assistantTruncated,
                 .toolCall, .initiativeCancelled, .replyPreempted, .rateLimits, .rolloverStarted:
                break
            }
            if forward { brain.yield(.session(e)) }
        }
    }

    private func receiveAudio(item: String, pcm: Data, at t: Double, _ s: inout Inner) {
        switch s.gate.audio() {
        case .play:
            break
        case .drop:
            return                                    // a cut response's late audio
        case .dropAndTellServer:
            // Stopped before any of it reached us: the server doesn't know yet that
            // none of this item was heard.
            command(.bargeIn(cuts: [(item, 0)]))
            return
        }
        if !s.responseHasAudio {
            s.responseHasAudio = true
            mark(.firstAudioDelta, detail: item)
            if s.responseKind == .initiative {
                s.core.initiativePending = false
                if s.core.userIsSpeaking(at: t) {
                    // Second gate, local: never start talking over someone.
                    s.gate.closeAfterCut()
                    command(.bargeIn(cuts: [(item, 0)]))
                    return
                }
            }
        }
        if !s.sessionItems.contains(item) { s.sessionItems.append(item) }
        s.lastSessionItem = item
        s.sessionPlaying = true
        s.finishDueAt = nil                            // the session is playing again anyway
        graph.player.enqueue(pcm, utterance: item)
    }

    static func problem(for reason: FallbackReason) -> (VoiceProblem, Bool?)? {
        switch reason {
        case .noKey: (.cloudVoiceNeedsSetup("No OpenAI key."), true)
        case .unauthorized: (.cloudVoiceNeedsSetup("The OpenAI key was refused."), true)
        case .quotaExceeded: (.cloudVoiceUnavailable("The OpenAI quota or spend limit was reached."), nil)
        case .rateLimited: (.cloudVoiceUnavailable("Rate limited."), nil)
        case .socketLost(_, let d): (.cloudVoiceUnavailable("Connection lost\(d.map { ": \($0)" } ?? ".")"), nil)
        case .connectFailed(let d): (.cloudVoiceUnavailable("Couldn't connect: \(d)"), nil)
        case .serverError(let d): (.cloudVoiceUnavailable("Server error\(d.map { ": \($0)" } ?? ".")"), nil)
        case .noResponse, .congested: nil
        }
    }

    static func describe(_ r: FallbackReason) -> String {
        switch r {
        case .socketLost(let code, let d): "connection lost (\(code)\(d.map { ", \($0)" } ?? ""))"
        case .connectFailed(let d): "couldn't connect (\(d))"
        case .noResponse: "no response in time"
        case .rateLimited(let a): "rate limited\(a.map { ", retry in \(Int($0)) s" } ?? "")"
        case .quotaExceeded: "quota or spend limit reached"
        case .unauthorized: "key refused"
        case .noKey: "no key"
        case .congested: "uplink congested"
        case .serverError(let d): "server error\(d.map { " (\($0))" } ?? "")"
        }
    }

    // MARK: Player and graph events

    private func handlePlayer(_ e: PCMStreamPlayer.Event) {
        let t = graph.now
        inner.withLock { s in
            switch e {
            case .started(let u, _):
                let clip = s.clips[u] != nil
                apply(s.core.playbackStarted(at: t, aside: clip), &s)
                if !clip {
                    for ev in s.sentences.itemStarted(u) { brain.yield(Self.brainEvent(ev)) }
                }
            case .level(let l):
                s.core.playbackLevel(l, at: t)
            case .underrun(let u):
                mark(.note, detail: "underrun \(u)")
            case .finished(let u, let ms, let flushed):
                if let clip = s.clips.removeValue(forKey: u) {
                    brain.yield(.clipPlayed(clip, cut: flushed))
                    if s.clips.isEmpty, s.localOn {
                        s.localOffDueAt = t + s.core.outputLatency + EarCore.echoTail
                    }
                } else if let i = s.sessionItems.firstIndex(of: u) {
                    s.sessionItems.remove(at: i)
                    if flushed {
                        itemEnded(u, playedMs: ms, cut: true, &s)
                    } else if let whole = wholeness(u, s) {
                        itemEnded(u, playedMs: ms, cut: !whole, &s)
                    } else {
                        s.playedOut.append((u, ms))      // decided when its response ends
                    }
                    if !flushed, s.sessionItems.isEmpty, s.sessionPlaying {
                        s.sessionPlaying = false
                        // The session learns she stopped once her echo has left the room.
                        s.finishDueAt = t + s.core.outputLatency + EarCore.echoTail
                    }
                }
                if !graph.player.isBusy { apply(s.core.playbackFinished(at: t), &s) }
            }
        }
    }

    private func handleGraph(_ e: AudioGraph.Event) {
        switch e {
        case .running(let facts):
            applied(facts)
            audioCameUp()
        case .interrupted(let why):
            emit(.error(why))
        case .playbackCut(let u, let ms, _):
            // A phone call / Siri / services reset stopped her output: the server
            // must hear what of her reply was played (not a barge-in: no event),
            // and a reply still on its way must not play when audio comes back.
            let t = graph.now
            inner.withLock { s in
                s.core.initiativePending = false
                if s.sessionPlaying, s.lastSessionItem != nil {
                    s.gate.closeAfterCut()
                    s.sessionPlaying = false
                    s.finishDueAt = nil
                    command(.bargeIn(cuts: cuts(s, reported: u.map { ($0, ms) })))
                } else {
                    closeGateBeforeAudio(&s, at: t)
                    command(.cancelUnspoken)
                }
            }
        case .error(let message):
            emit(.error(message))
        }
    }

    private func applied(_ facts: AudioGraph.Facts) {
        inner.withLock { s in
            s.core.aecActive = facts.aecActive
            s.core.outputLatency = facts.outputLatency
        }
    }

    /// Audio is up for the first time: `.ready`.
    private func audioCameUp() {
        inner.withLock { s in
            guard s.started, !s.audioUp, !s.shutDown else { return }
            s.audioUp = true
            voice(.ready, &s)
        }
    }

    // MARK: Microphone (tap thread)

    private func handleInput(_ buffer: AVAudioPCMBuffer, at t: Double) {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        let samples = buffer.firstChannelSamples()
        // Her output rendered up to now: the echo reference for these frames.
        let reference = graph.player.takeReference(now: graph.now)
        inner.withLock { s in
            guard !s.shutDown else { return }
            s.core.reference(reference)
            if s.sliceRate != rate {
                s.sliceRate = rate
                s.slicer = FrameSlicer(frameSize: max(1, Int(rate * Self.frameSeconds)))
            }
            let frames = s.slicer.push(samples)
            let frameDuration = Double(frames.first?.count ?? 0) / rate
            for (k, f) in frames.enumerated() {
                let ft = t - Double(frames.count - 1 - k) * frameDuration
                apply(s.core.frame(f, sampleRate: rate, at: ft), &s)
            }
            if configuration.gateUplink { s.uplinkGate.barDB = s.core.uplinkBarDB }
        }
        if configuration.classifySounds, inner.withLock({ $0.audioUp }) { sounds.analyze(buffer, hostTime: t) }
    }

    // MARK: Uplink

    private func openUplink(_ s: inout Inner) {
        guard !s.uplinkOpen, !s.shutDown else { return }
        s.uplinkOpen = true
        s.uplinkGeneration += 1
        let generation = s.uplinkGeneration
        let capture = graph.capture
        let from = s.map.captureEnd ?? max(0, capture.capturedFrames - Int64(configuration.prerollSeconds * PCM16Capture.sampleRate))
        let chunks = capture.open(from: from, maxPreroll: configuration.prerollSeconds)
        let t = Task { [weak self] in
            for await chunk in chunks {
                guard let self, self.send(chunk, generation: generation) else { return }
            }
        }
        tasks.withLock { list in
            list.removeAll { $0.isCancelled }
            list.append(t)
        }
    }

    private func closeUplink(_ s: inout Inner) {
        guard s.uplinkOpen else { return }
        s.uplinkOpen = false
        s.uplinkGeneration += 1
        graph.capture.close()
    }

    /// One chunk to the server (in order: under the lock, so a newer uplink can't
    /// overtake an older one's last chunk).
    private func send(_ chunk: PCM16Capture.Chunk, generation: Int) -> Bool {
        inner.withLock { s -> Bool in
            guard s.uplinkOpen, s.uplinkGeneration == generation, !s.shutDown else { return false }
            if let end = s.map.captureEnd, chunk.startFrame < end {
                // Overlap with what was already sent (never expected): send only the new part.
                let skip = Int(end - chunk.startFrame)
                guard skip < chunk.frames else { return true }
                let data = chunk.data.subdata(in: (chunk.data.startIndex + skip * 2)..<chunk.data.endIndex)
                s.map.sent(startFrame: end, frames: chunk.frames - skip)
                session.feedAudio(s.uplinkGate.process(data, startFrame: end))
                return true
            }
            s.map.sent(startFrame: chunk.startFrame, frames: chunk.frames)
            session.feedAudio(s.uplinkGate.process(chunk.data, startFrame: chunk.startFrame))
            return true
        }
    }

    // MARK: Actions

    /// Carries out the core's decisions (under the lock: events and commands keep
    /// their order; player calls never block).
    private func apply(_ actions: [EarCore.Action], _ s: inout Inner) {
        for a in actions {
            switch a {
            case .emit(let e):
                // A held barge-in is announced when it is decided (`releaseHold`).
                if e == .bargeIn, s.hold != nil { continue }
                voice(e, &s)
            case .bargeIn(let item):
                if configuration.holdOnBargeIn, s.sessionPlaying, s.lastSessionItem != nil, s.hold == nil {
                    // Silent at once; whether her reply ends here their words decide.
                    graph.player.hold()
                    s.hold = FloorHold(itemID: item, since: graph.now)
                    mark(.note, detail: "hold \(item ?? "-")")
                } else {
                    cutReply(&s)
                }
                if let item { accept(item, &s) }
            case .yieldAside(let item):
                if s.sessionPlaying || !s.sessionItems.isEmpty {
                    // Her reply was queued behind the aside: the user is talking, it goes too.
                    cutReply(&s)
                } else {
                    graph.player.flush()
                }
                if let item { accept(item, &s) }
            case .acceptOnset(let item):
                accept(item, &s)
            case .rejectEcho(let item):
                markRejected(item, &s)
                s.heldStarts[item] = nil
                command(.rejectEcho(item))
                mark(.note, detail: "echo rejected \(item)")
            case .deferToWords(let item, let strict):
                if s.wordsPending[item] == nil { s.wordsPending[item] = (graph.now, [], strict) }
                mark(.note, detail: "words decide \(item)")
            case .cancelInitiative:
                // Its first audio may already be on the way: dropped on arrival.
                closeGateBeforeAudio(&s, at: graph.now)
                command(.cancelUnspoken)
            case .uplink(let on):
                if on { openUplink(&s) } else { closeUplink(&s) }
            case .localSpeech(let on):
                command(.localSpeech(on))
            }
        }
        // Her next item never starts while an onset over her is being decided: if
        // it is the user, she would begin a new sentence over them.
        let boundary = s.sessionPlaying && s.core.deciding && s.core.pendingMayBeUser(at: graph.now)
        if graph.player.holdAtBoundary != boundary { graph.player.holdAtBoundary = boundary }
    }

    /// An item's words decided it: the user's (the brain gets everything held
    /// back, in order) or her echo (deleted; the brain never sees it).
    private func wordsDecided(_ item: String, user: Bool, _ s: inout Inner) {
        guard let pending = s.wordsPending.removeValue(forKey: item) else { return }
        if user {
            release(item, &s)
            for e in pending.events {
                switch e {
                case .userSpeechStopped: timeline.beginTurn(.speechStopped, at: graph.now, detail: item)
                case .userCommitted: mark(.committed, detail: item)
                default: break
                }
                brain.yield(.session(e))
            }
            command(.acceptSpeech(item))
        } else {
            markRejected(item, &s)
            s.heldStarts[item] = nil
            s.core.forget(item)
            command(.rejectEcho(item))
            mark(.note, detail: "echo rejected \(item)")
        }
    }

    /// The words over her voice said "go on" (or the onset was her echo after
    /// all): she goes on from exactly where she paused.
    private func resumeHold(_ s: inout Inner, at t: Double, why: String) {
        guard let h = s.hold else { return }
        s.hold = nil
        graph.player.resume()
        apply(s.core.playbackResumed(at: t), &s)
        mark(.note, detail: "resumed \(h.itemID ?? "-") (\(why))")
    }

    /// A hold ended as a real barge-in: marked when she paused (she was silent
    /// from then on); announced (`.bargeIn`) only when `announce`.
    private func releaseHold(_ s: inout Inner, announce: Bool) {
        guard let h = s.hold else { return }
        s.hold = nil
        timeline.mark(.bargeIn, at: h.since, detail: h.itemID)
        if announce { continuation.yield(.bargeIn) }
    }

    /// Stops her reply where the listener is: flush, then tell the server exactly
    /// how much of the item was played. Late audio of that response is gated out.
    /// A hold it ends is a barge-in (timeline mark at the pause); `announce`: the
    /// voice ended it on its own (no words came, nobody answered them), so the app
    /// hears `.bargeIn`. When the brain ends it (`respond`, `stopSpeaking`) it is
    /// already acting on their words: no event that would stop its new reply.
    private func cutReply(_ s: inout Inner, announce: Bool = false) {
        s.core.initiativePending = false
        graph.player.flush()
        defer { releaseHold(&s, announce: announce) }
        if s.sessionPlaying, s.lastSessionItem != nil {
            s.gate.closeAfterCut()
            s.sessionPlaying = false
            s.finishDueAt = nil                        // `bargeIn` ends her playback for the session
            command(.bargeIn(cuts: cuts(s)))
        } else {
            closeGateBeforeAudio(&s, at: graph.now)
            command(.cancelUnspoken)
        }
    }

    /// Closes the audio gate for a response that has no played audio yet (see
    /// `ReplyGate`: its `.responseStarted` may still be in the event pump).
    private func closeGateBeforeAudio(_ s: inout Inner, at t: Double) {
        s.gate.closeBeforeAudio(at: t)
    }

    private func markRejected(_ item: String, _ s: inout Inner) {
        guard s.rejected.insert(item).inserted else { return }
        s.rejectedOrder.append(item)
        if s.rejectedOrder.count > 128 { s.rejected.remove(s.rejectedOrder.removeFirst()) }
    }

    /// Whether an item that played out un-flushed was all she meant to say: its
    /// audio finished and its response completed (nil: the response is still open).
    private func wholeness(_ item: String, _ s: Inner) -> Bool? {
        guard s.audioDone.contains(item) else { return false }
        if let c = s.itemCompleted[item] { return c }
        return s.responseOpen ? nil : s.lastDoneCompleted
    }

    /// Items that played out while their response was open, now that it ended.
    private func resolvePlayedOut(_ s: inout Inner) {
        var waiting: [(item: String, ms: Int)] = []
        for p in s.playedOut {
            if let whole = wholeness(p.item, s) {
                itemEnded(p.item, playedMs: p.ms, cut: !whole, &s)
            } else {
                waiting.append(p)
            }
        }
        s.playedOut = waiting
    }

    /// One of her items stopped: place its sentences on what was played, tell the brain.
    /// `cut`: flushed, or the response ended abnormally (the transcript may run
    /// ahead of the audio): sentences count as heard by the midpoint rule.
    private func itemEnded(_ item: String, playedMs ms: Int, cut: Bool, _ s: inout Inner) {
        for ev in s.sentences.itemFinished(item, playedMs: ms, cut: cut) { brain.yield(Self.brainEvent(ev)) }
        brain.yield(.itemPlayed(itemID: item, playedMs: ms, cut: cut))
        s.audioDone.remove(item)
        s.itemCompleted[item] = nil
        // Items that never played (gated out) leave entries behind: keep it small.
        if s.itemCompleted.count > 64 || s.audioDone.count > 64 {
            let live = Set(s.sessionItems + s.playedOut.map(\.item))
            s.itemCompleted = s.itemCompleted.filter { live.contains($0.key) }
            s.audioDone = s.audioDone.filter { live.contains($0) }
        }
    }

    /// What of each of her items was heard, after the player was flushed (or an
    /// interruption stopped it): the one playing at its played ms, each queued
    /// behind it at 0, so the server drops all of it. `reported`: the player's own
    /// figure for the item it cut.
    private func cuts(_ s: Inner, reported: (String, Int)? = nil) -> [(itemID: String, playedMs: Int)] {
        var items = s.sessionItems
        if items.isEmpty, let last = s.lastSessionItem { items = [last] }
        return items.map { item in
            if let reported, reported.0 == item { return (item, reported.1) }
            return (item, graph.player.playedMs(utterance: item))
        }
    }

    /// The onset of `item` is the user: the brain sees it, and the session stops
    /// treating it as possibly her echo.
    private func accept(_ item: String, _ s: inout Inner) {
        release(item, &s)
        command(.acceptSpeech(item))
    }

    /// The onset of `item` is the user: let the brain see it.
    private func release(_ item: String, _ s: inout Inner) {
        if let held = s.heldStarts.removeValue(forKey: item) { brain.yield(.session(held)) }
    }

    private func voice(_ e: VoiceEvent, _ s: inout Inner) {
        switch e {
        case .heard: mark(.heard)
        case .speakingStarted: mark(.speakingStarted)
        case .speakingFinished: mark(.speakingFinished)
        case .bargeIn: mark(.bargeIn)
        default: break
        }
        continuation.yield(e)
    }

    /// A timeline mark on the graph's clock (the clock of every other mark here).
    private func mark(_ stage: TurnTimeline.Stage, detail: String? = nil) {
        timeline.mark(stage, at: graph.now, detail: detail)
    }

    private func emit(_ e: VoiceEvent) {
        inner.withLock { s in voice(e, &s) }
    }

    static func brainEvent(_ e: SentenceClock.Event) -> BrainEvent {
        switch e {
        case .started(let i, let n, let text): .sentenceStarted(itemID: i, index: n, text: text)
        case .finished(let i, let n, let text, let heard): .sentenceFinished(itemID: i, index: n, text: text, heard: heard)
        }
    }
}
