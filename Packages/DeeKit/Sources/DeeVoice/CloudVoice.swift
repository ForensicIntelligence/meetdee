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
/// **Tune 4.** A speculative reply (`speculate()` before the request) is held in
/// the player, buffered and never heard, until `releaseSpeculative` (it plays from
/// its first sample) or `discardSpeculative` (dropped with no flush, echo or cut;
/// the server cancels it and truncates it at 0); `speculativeEvents` reports it.
/// The server's empty tail item after the voice's own quick commit is part of
/// that burst (`FloorHold.tails`); an empty transcript never ends a hold.
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
        /// When the latest item's audio was closed: our commit sent, or the
        /// server's commit seen. Their sound after it is in no item yet.
        public var commitAt: Double? {
            didSet { if let c = commitAt, let item = itemID, closedAt[item] == nil { closedAt[item] = c } }
        }
        /// When each item's audio was closed (its commit: ours or the server's).
        var closedAt: [String: Double] = [:]
        /// The latest commit was ours on a short burst (`holdQuickBurst`): its
        /// delta burst is short, so its words settle sooner (`holdSettleQuick`).
        var quickCommit = false
        /// Tune 4: server items that are only the tail of a burst we committed
        /// ourselves (the server's VAD ends "the rest" of it a moment later, with
        /// no words): part of that burst, never a turn of their own. Without words
        /// they decide nothing.
        public private(set) var tails: Set<String> = []
        /// Tune 5: items said in a short burst — the hold-only continuers count
        /// for them ("Keep going" heard as "She's not going.").
        public var shortItems: Set<String> = []
        /// Tune 7: items whose burst was measured short once it was closed (the ear
        /// forgets an item at its transcript; its full words decide a fragment after).
        var shortBursts: Set<String> = []
        /// Tune 9 (T8-1): what each item sounded like (`EarCore.itemSound`, up to its
        /// commit): a one-word fragment the words don't know ("Movie.") is "go on" only
        /// when it sounded like one.
        public internal(set) var sounds: [String: FragmentSound] = [:]
        /// The brain said "go on" while more of the burst was still coming: she
        /// goes on once they are quiet and no item waits for its words.
        var goOn = false

        /// Items still without any words (tails aside).
        var wordless: [String] { items.filter { final[$0] == nil && partial[$0] == nil && !tails.contains($0) } }

        /// The brain's go-on waits: they are still talking, or some item has
        /// "go on" words and a later one has none yet (a split burst).
        func deferGoOn(talking: Bool) -> Bool {
            if talking { return true }
            let pending = wordless
            return !pending.isEmpty && pending.count < items.count
        }
        /// Items whose full transcript came back empty: nothing was said in them.
        var emptyWords: Set<String> = []
        /// Tune 7 (T6-4): a probe (`EarCore.Action.probe`): she is paused while the
        /// ear listens into her silence for an onset her loud echo masks. No items
        /// yet, nothing announced; the user's voice or words confirm it (a hold from
        /// `since`), quiet ends it (she goes on, nothing happened).
        public internal(set) var probe = false

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
            quickCommit = false
        }

        /// Every item before the latest whose words are in said "go on" (or nothing).
        var earlierWordsGoOn: Bool {
            for item in items.dropLast() {
                guard let w = (final[item] ?? partial[item])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !w.isEmpty else { continue }
                if !Backchannel.isBackchannel(w, inHold: shortItems.contains(item), final: final[item] != nil,
                                              sound: sounds[item]) { return false }
            }
            return true
        }

        /// A tail of the burst we committed: one of the hold's items, but the
        /// latest item (its commit, its stop) stays the burst's.
        mutating func addTail(_ item: String) {
            guard !items.contains(item) else { return }
            // The burst's own item stays the latest.
            if items.isEmpty { items.append(item) } else { items.insert(item, at: items.count - 1) }
            tails.insert(item)
        }

        mutating func remove(_ item: String) {
            tails.remove(item)
            emptyWords.remove(item)
            items.removeAll { $0 == item }
            partial[item] = nil
            final[item] = nil
            if itemID == item { itemID = items.last }
        }

        enum Verdict: Equatable { case wait, resume, answer }

        /// What their words say so far. `settled`: partial words count (no new
        /// delta for `holdSettle`); `quiet`: an item still without words decides
        /// nothing (they are quiet and its words are late).
        /// `partialAnswers`: settled partial words that are not "go on" may decide
        /// `.answer` (tune 4: not for a quick-committed short burst until its full
        /// transcript, or `holdFinalWait`: "Go on." came back as "Jeron.").
        func verdict(settled: Bool, quiet: Bool, partialAnswers: Bool = true) -> Verdict {
            var anyBackchannel = false, undecided = false, allEmpty = true, pendingAnswer = false
            for item in items {
                let isFinal = final[item] != nil
                let words = final[item] ?? (settled ? partial[item] : nil)
                guard let words else {
                    // A tail without words is nothing yet; anything else waits for its words.
                    if !tails.contains(item) { undecided = true; allEmpty = false }
                    continue
                }
                let clean = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    // Nothing was said in it. An empty transcript never ends a hold; a
                    // failed one (no transcript) leaves it to the deadlines.
                    if !isFinal || !(emptyWords.contains(item) || tails.contains(item)) { allEmpty = false }
                    continue
                }
                allEmpty = false
                if !Backchannel.isBackchannel(clean, inHold: shortItems.contains(item), final: isFinal, sound: sounds[item]) {
                    if isFinal || partialAnswers { return .answer }
                    pendingAnswer = true                            // its full words decide
                    continue
                }
                anyBackchannel = true
            }
            if pendingAnswer { return .wait }
            if anyBackchannel { return !undecided || quiet ? .resume : .wait }
            // Every item came back empty (noise, a breath, her own echo): she goes on.
            return allEmpty && !undecided && !items.isEmpty && items.contains(where: { emptyWords.contains($0) })
                ? .resume : .wait
        }
    }

    /// Tune 5: a hold-only continuer ("She's not going.") counts in an item with
    /// at most this much of their pitched voice ("Keep going" is ~0.6 s).
    public static let holdOnlyBurst = 1.0

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
    /// Tune 3 (live: "Go on." / "Mm-hm." / "Don't stop, keep going." resumed
    /// 1.4–4.6 s after they paused her — the server's semantic VAD reported the
    /// end of their speech only with its commit, 0.7–2.6 s after the words). In a
    /// hold, a short burst of their voice (at most this long) that ended
    /// `holdCommitSilence` ago is committed at once, without waiting for the
    /// server's `speech_stopped`: the backchannel's words come ~0.15 s later and
    /// she goes on ~0.5 s after they stopped. Longer speech is left to the server
    /// (a commit inside a sentence would split it). Only while every earlier item
    /// of the hold said "go on": a real turn is never cut into pieces.
    public static let holdQuickBurst = 1.0
    /// Settled deltas of a quick commit (a short burst: a few words in one burst).
    public static let holdSettleQuick = 0.1
    /// She goes on only once they have been quiet this long (never over them:
    /// "Don't stop, … keep going." — the first words are in while they talk on).
    public static let holdResumeQuiet = 0.2
    /// Their sound after the latest commit that no server item holds yet: she
    /// waits up to this long after it for the item that will (its words decide).
    public static let holdUncoveredWait = 1.0
    /// An item of a hold with no words this long after its commit decides nothing
    /// (live deltas come ~0.15 s after a commit).
    public static let holdWordsLate = 0.8
    /// How far before the pause their burst may have begun.
    static let holdBurstLookback = 1.5
    /// Tune 4 (live: 3 of 4 backchannel stops). After our own commit of a burst,
    /// the server's VAD still ends "the rest" of it as an item of its own, with an
    /// empty transcript: a server item whose speech ended at most this long after
    /// our commit (and that arrives within `holdTailWindow` of it) is the burst's
    /// tail — part of the hold, or a backchannel if she already went on.
    public static let holdTailMax = 0.5
    public static let holdTailWindow = 1.2
    /// A quick-committed short burst's settled partial words that are not "go on"
    /// end the hold only with its full transcript, or this long after its last
    /// delta (live: "Go on." came back as "Jeron.").
    public static let holdFinalWait = 0.6
    /// Tune 6: an onset over her this soon after she went on from a backchannel
    /// ("Keep going." … "I'm listening.") never pauses her again on its sound: its
    /// words decide. A backchannel is ignored; a real turn pauses her by its words
    /// (`holdForWords`) and the brain answers it.
    public static let resumeGrace = 2.0
    /// Tune 8 (T7-3, live interrupt-echo20): with no echo cancellation, a hold whose
    /// items all began this soon into her stretch and whose words are at most one
    /// word ("Yeah.") is likely her own echo. She goes on from it as from a
    /// backchannel, but it arms no `resumeGrace`: a real onset next pauses her at once.
    /// (Live: real one-word backchannels began ≥ 1.5 s into her stretch.)
    public static let echoOnsetWindow = 1.2

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

    /// A hold's life, for the brain (`holdEvents`).
    public enum HoldEvent: Sendable, Equatable {
        /// Her reply paused for a barge-in (`floorHold` is set); their words decide.
        case paused(itemID: String?)
        /// Their words were a backchannel (`why` "words"), the onset was her echo
        /// ("echo"), or the brain said so (`continueAfterBackchannel`, "brain"):
        /// she goes on from where she paused. `itemIDs`: their items in the hold —
        /// committed turns that need no answer (`wasBackchannel(itemID:)`).
        case resumed(itemIDs: [String], text: String, why: String)
        /// The hold ended as a barge-in: her reply ends where she paused.
        /// `byVoice`: no answer came, the voice ended it (`.bargeIn` was emitted).
        case ended(itemIDs: [String], byVoice: Bool)
    }

    /// A speculative reply (tune 4): requested before the turn is sure, its audio
    /// held in the player until the brain releases or discards it.
    public struct SpeculativeReply: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Armed: no response of it has started yet.
            case armed
            /// A response started; no audio yet.
            case waiting
            /// Audio is held in the player.
            case buffered
        }
        public var phase: Phase = .armed
        /// The latest held response (the reply, or its tool follow-up).
        public var responseID: String? { responseIDs.last }
        /// Every response held by this speculation.
        public var responseIDs: [String] = []
        /// Her items held in the player, in order.
        public var items: [String] = []
        /// Graph clock.
        public var armedAt: Double
        public var firstAudioAt: Double?
        /// Audio held, all items (ms; filled in by `speculative`).
        public var bufferedMs = 0
        /// The latest held response is done: all of its audio is in.
        public var complete = false

        public init(armedAt: Double) { self.armedAt = armedAt }
    }

    /// A speculation's life, for the brain (`speculativeEvents`).
    public enum SpeculativeEvent: Sendable, Equatable {
        /// A held response began.
        case started(responseID: String)
        /// Its first audio is buffered (graph clock).
        case ready(responseID: String, itemID: String, at: Double)
        /// The held response is done (`status` as in `ResponseSummary`).
        case complete(responseID: String, status: String, bufferedMs: Int)
        /// It plays from now.
        case released(responseID: String?, bufferedMs: Int)
        /// Dropped unheard. `byVoice`: the voice did it (`why`: "timeout", "cut",
        /// "disconnected", "rearmed"); otherwise the brain ("brain").
        case discarded(responseID: String?, items: [String], bufferedMs: Int, byVoice: Bool, why: String)
    }

    /// A speculation nobody released or discarded is discarded this long after it
    /// was armed.
    public static let speculativeMax = 8.0

    public let session: RealtimeSession
    public let graph: AudioGraph
    public let clips: ClipCache?
    public let timeline: TurnTimeline
    public let configuration: Configuration

    private let stream: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation
    public let brainEvents: AsyncStream<BrainEvent>
    private let brain: AsyncStream<BrainEvent>.Continuation
    /// Every hold's pause / resume / end, in order (single consumer; the newest
    /// 64 are kept if nobody reads).
    public let holdEvents: AsyncStream<HoldEvent>
    private let holdContinuation: AsyncStream<HoldEvent>.Continuation
    /// Every speculation's start / audio / release / discard, in order (single
    /// consumer; the newest 64 are kept if nobody reads).
    public let speculativeEvents: AsyncStream<SpeculativeEvent>
    private let speculativeContinuation: AsyncStream<SpeculativeEvent>.Continuation
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
        /// A discarded speculation: cancel its response, truncate its items at 0
        /// (no timeline cut marks: nothing of it was ever played).
        case discard([String])
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
        /// Settled deltas of items waiting for their words: words she never said
        /// decide "the user" before the full transcript (~0.2 s sooner).
        var wordsPartial: [String: (text: String, at: Double)] = [:]
        /// User items she went on through (a backchannel in a hold), newest last.
        var backchannelItems: [String] = []
        /// Items of past holds whose short burst let a hold-only continuer count.
        var shortHoldItems: [String] = []
        /// Our latest commit of a hold's burst (graph clock) and whether that hold
        /// already ended: a server tail arriving after the resume is still the burst's.
        var burstCommit: (at: Double, resumed: Bool)?
        /// Tails of our committed bursts (bounded): deleted once their words come back empty.
        var tailItems: [String] = []
        /// The speculation armed or held (`speculate()`).
        var spec: SpeculativeReply?
        /// Tune 6: when she last went on from a backchannel (graph clock).
        var lastResumeAt: Double?
        /// Tune 7 (T6-1): empty tails waiting to be dropped (`flushTailDrops`).
        var tailDrops: [String] = []
        /// When the latest response started / ended (graph clock).
        var lastResponseStartAt: Double?
        var lastResponseDoneAt: Double?
        /// Onsets inside `resumeGrace` left to their words (newest 16).
        var graceItems: [String] = []
        /// Tune 8: items that began early in her stretch with no echo cancellation
        /// (`echoOnsetWindow`; newest 16).
        var echoProneItems: [String] = []
        /// Tune 10 (T9-7): items that began while her voice played with no echo
        /// cancellation (newest 16).
        var echoExposedItems: [String] = []
        /// Tune 11 (T10-3): one-word items over her voice that her echo model says are the
        /// user's (`oneWordIsHerEcho`; newest 16): their masked sound and the her-echo word
        /// test no longer make them a "go on".
        var voiceOverEchoItems: [String] = []
        /// The open response is held by `spec` (its audio is gated in the player).
        var responseGated = false
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
        (holdEvents, holdContinuation) = AsyncStream<HoldEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (speculativeEvents, speculativeContinuation) =
            AsyncStream<SpeculativeEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
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

    /// Tune 5: when the user's voice was last heard (graph clock; `EarCore.lastVoiceTime`):
    /// pitched, theirs, above the room's bed. -inf before any.
    public var lastUserVoiceAt: Double { inner.withLock { $0.core.lastVoiceTime } }

    /// Their voice is in the room right now (`EarCore.voiceActive`: 0.15 s hangover,
    /// never on for a kitchen / TV / fan bed). For the speculative release gate.
    public var userVoiceActive: Bool {
        let t = graph.now
        return inner.withLock { $0.core.voiceActive(at: t) }
    }

    /// Seconds since their voice was last heard (+inf if never).
    public var userQuietFor: Double {
        let t = graph.now
        return inner.withLock { t - $0.core.lastVoiceTime }
    }

    /// Tune 5: `text`, said in `itemID`, is a backchannel: `Backchannel.isBackchannel`,
    /// or — the item was said in a hold (now or one she went on through) in a short
    /// burst — a hold-only continuer ("Keep going" heard as "She's not going.").
    /// The brain uses it in place of `TurnPolicy.isBackchannel` for an item over her voice.
    ///
    /// Tune 9 (T8-1): a one-word fragment the words don't know is one only when the item
    /// sounded like a backchannel (`itemSound`).
    public func isHoldBackchannel(itemID: String, text: String) -> Bool {
        if Backchannel.isBackchannel(text) { return true }
        let t = graph.now
        return inner.withLock { s in
            guard Backchannel.isBackchannel(text, inHold: true, sound: sound(itemID, s, at: t)) else { return false }
            if s.hold?.shortItems.contains(itemID) == true || s.shortHoldItems.contains(itemID)
                || s.hold?.shortBursts.contains(itemID) == true { return true }
            guard s.hold?.items.contains(itemID) == true || s.backchannelItems.contains(itemID) else { return false }
            return isShort(itemID, s, at: t)
        }
    }

    /// Tune 9 (T8-1): what server item `itemID` sounded like (`FragmentSound`: seconds of
    /// their voice, syllables, the pitch's end), up to our commit of it if we made one.
    /// Nil when the ear doesn't know the item (rejected as her echo, or long gone).
    public func itemSound(itemID: String) -> FragmentSound? {
        let t = graph.now
        return inner.withLock { sound(itemID, $0, at: t) }
    }

    /// Tune 9 (T8-1): `text`, said in `itemID` over her voice, is a misheard "go on"
    /// (`Backchannel.isMisheardFragment(_:sound:)` with the item's sound): one word the
    /// words don't know ("Movie." for "Who made you?") only when it *sounded* like a
    /// backchannel — short, at most two syllables, not rising. The brain uses it in place
    /// of the words-only `TurnPolicy.isMisheardFragment` for an item it knows.
    ///
    /// Tune 10 (T9-7, live backchannel-echo20: her echo came back as "Me." 2.6 s into her
    /// stretch, no echo cancellation, and cut her): one word over her playing voice with no
    /// echo cancellation goes on as her echo unless its words (`HerWords`: a word a person
    /// says alone — "Stop.", "No." — or a "?") or its sound (`FragmentSound.questionLike`)
    /// say someone spoke.
    public func isMisheardFragment(itemID: String, text: String) -> Bool {
        let t = graph.now
        return inner.withLock { s in
            let snd = sound(itemID, s, at: t)
            if Backchannel.isMisheardFragment(text, sound: snd) { return true }
            // Tune 11 (T10-3): a voice her echo can't explain said it — the user's, by its words.
            if s.voiceOverEchoItems.contains(itemID) { return false }
            let kept = Backchannel.words(text).filter { !Backchannel.fillers.contains($0) }
            // A word a person says alone ("Enough.", "Pause.", "Nope.") is theirs (review).
            guard s.echoExposedItems.contains(itemID), !text.contains("?"), snd?.questionLike != true,
                  kept.count == 1, !Backchannel.aloneWords.contains(kept[0]) else { return false }
            return s.herWords.isHerEcho(text, at: t)
        }
    }

    private func sound(_ item: String, _ s: Inner, at t: Double) -> FragmentSound? {
        // Tune 11 (T10-3): their voice under her un-cancelled echo is masked; what is left
        // of it ("Stop." as a short, flat burst) says nothing about what kind of word it was.
        if s.voiceOverEchoItems.contains(item) { return nil }
        var until = t
        if let c = s.hold?.closedAt[item] { until = min(until, c) }
        return s.core.itemSound(itemID: item, until: until)
    }

    /// The item's burst was short (`holdOnlyBurst`): up to our commit of it, if we made one.
    private func isShort(_ item: String, _ s: Inner, at t: Double) -> Bool {
        var until = t
        if let c = s.hold?.closedAt[item] { until = min(until, c) }
        guard let v = s.core.voiceSeconds(itemID: item, until: until) else { return false }
        return v <= Self.holdOnlyBurst + 1e-9
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
    public var floorHold: FloorHold? { inner.withLock { $0.hold?.probe == true ? nil : $0.hold } }

    /// Tune 7 (T6-4): she is paused for a probe right now (an onset over her that
    /// her echo masks: the ear listens into her silence). Not a hold yet: the brain
    /// hears `.paused` only if their voice or words confirm it.
    public var isProbing: Bool { inner.withLock { $0.hold?.probe == true } }

    /// The words over her voice were a backchannel: she goes on from where she
    /// paused. No-op without a hold. Returns whether she resumed.
    @discardableResult
    public func continueAfterBackchannel() -> Bool {
        let t = graph.now
        return inner.withLock { s in
            guard let h = s.hold, !h.probe else { return false }
            // Tune 5 (live kitchen15 / echo20 c05): the server split one burst —
            // "Keep going" | "I'm listening." — and the brain's go-on for the first
            // came while the second was still being said. She goes on once all of
            // it is in (`checkHold`: its words decide), never over them.
            if h.deferGoOn(talking: s.core.voiceActive(at: t)) {
                s.hold?.goOn = true
                // Tune 10 (T9-1): the brain heard "go on": no `holdAfterWords` cut
                // for words it already judged (echo10 c05: "Be sneaking," then "going").
                s.hold?.wordsAt = nil
                mark(.note, detail: "go-on deferred \(h.itemID ?? "-")")
                return true
            }
            resumeHold(&s, at: t, why: "brain")
            return true
        }
    }

    /// `itemID` was (part of) a backchannel she went on through: a committed turn
    /// that needs no answer (`session.userTurnHandled`). Remembers the last 32.
    public func wasBackchannel(itemID: String) -> Bool {
        inner.withLock { $0.backchannelItems.contains(itemID) }
    }

    // MARK: Speculative replies (tune 4)

    /// The speculation armed or held right now (nil: none). `bufferedMs` is live.
    public var speculative: SpeculativeReply? {
        inner.withLock { s in
            guard var sp = s.spec else { return nil }
            sp.bufferedMs = sp.items.reduce(0) { $0 + graph.player.bufferedMs(utterance: $1) }
            return sp
        }
    }

    /// Arms the gate: the next reply (or tool follow-up) that starts is held in
    /// the player — buffered, never heard — until `releaseSpeculative` or
    /// `discardSpeculative`. Call it before `requestResponse`. Every such response
    /// that starts while armed is held (a session re-request included). A
    /// speculation already armed or held is discarded first ("rearmed").
    public func speculate() {
        let t = graph.now
        inner.withLock { s in
            if s.spec != nil { discardSpec(&s, at: t, byVoice: true, why: "rearmed") }
            s.spec = SpeculativeReply(armedAt: t)
            s.responseGated = false
            // A request is coming: a stop just before it must not swallow it.
            s.gate.requested()
            mark(.note, detail: "speculate")
        }
    }

    /// The speculation is a real answer: it plays from now (from its first
    /// sample; played time counts exactly as always). nil = the current one; an
    /// id not of it is a no-op. Returns whether something was released.
    @discardableResult
    public func releaseSpeculative(responseID: String? = nil) -> Bool {
        inner.withLock { s in
            guard let sp = s.spec, Self.matches(sp, responseID) else { return false }
            let buffered = sp.items.reduce(0) { $0 + graph.player.bufferedMs(utterance: $1) }
            for item in sp.items { graph.player.release(utterance: item) }
            s.spec = nil
            s.responseGated = false
            mark(.note, detail: "speculative released \(sp.responseID ?? "-") buffered_ms=\(buffered)")
            speculativeContinuation.yield(.released(responseID: sp.responseID, bufferedMs: buffered))
            return true
        }
    }

    /// The speculation is not wanted: dropped unheard, with no side effects on her
    /// voice (no flush, no echo tail, no barge-in); the server cancels it and
    /// keeps none of it. nil = the current one; an id not of it is a no-op.
    @discardableResult
    public func discardSpeculative(responseID: String? = nil) -> Bool {
        let t = graph.now
        return inner.withLock { s in
            guard let sp = s.spec, Self.matches(sp, responseID) else { return false }
            discardSpec(&s, at: t, byVoice: false, why: "brain")
            return true
        }
    }

    private static func matches(_ sp: SpeculativeReply, _ id: String?) -> Bool {
        guard let id else { return true }
        return sp.responseIDs.contains(id)
    }

    /// Something of hers that is not a held speculation is queued or playing.
    private func herVoiceQueued(_ s: Inner) -> Bool {
        guard let sp = s.spec, !sp.items.isEmpty else { return true }
        return s.sessionItems.contains { !sp.items.contains($0) }
    }

    /// Drops the speculation (see `discardSpeculative`).
    private func discardSpec(_ s: inout Inner, at t: Double, byVoice: Bool, why: String) {
        guard let sp = s.spec else { return }
        s.spec = nil
        var buffered = 0
        for item in sp.items { buffered += graph.player.discard(utterance: item) }
        let held = Set(sp.items)
        s.sessionItems.removeAll { held.contains($0) }
        let current = s.responseGated
        s.responseGated = false
        if !sp.items.isEmpty {
            // Late audio of it never plays; the server cancels it and truncates
            // its items at 0.
            if current { s.gate.closeAfterCut() }
            if s.sessionItems.isEmpty, s.sessionPlaying {
                // Nothing of hers is left: she never played (no echo tail to wait out).
                s.sessionPlaying = false
                s.finishDueAt = nil
            }
            if let last = s.lastSessionItem, held.contains(last) { s.lastSessionItem = s.sessionItems.last }
            command(.discard(sp.items))
        } else {
            // No audio yet: a response on its way is cancelled, and its first audio
            // (if already sent) is dropped on arrival (the reply gate's stop guard:
            // a plain request right after this waits it out, or calls `speculate`).
            closeGateBeforeAudio(&s, at: t)
            command(.cancelUnspoken)
        }
        mark(.note, detail: "speculative discarded \(sp.responseID ?? "-") (\(why)) buffered_ms=\(buffered)")
        speculativeContinuation.yield(.discarded(responseID: sp.responseID, items: sp.items, bufferedMs: buffered,
                                                 byVoice: byVoice, why: why))
    }

    /// The speculation went with a cut of her voice (the flush took its audio).
    /// Call before the flush.
    private func specCut(_ s: inout Inner, why: String) {
        guard let sp = s.spec else { return }
        s.spec = nil
        s.responseGated = false
        let buffered = sp.items.reduce(0) { $0 + graph.player.bufferedMs(utterance: $1) }
        mark(.note, detail: "speculative discarded \(sp.responseID ?? "-") (\(why)) buffered_ms=\(buffered)")
        speculativeContinuation.yield(.discarded(responseID: sp.responseID, items: sp.items, bufferedMs: buffered,
                                                 byVoice: true, why: why))
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
        holdContinuation.finish()
        speculativeContinuation.finish()
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
            specCut(&s, why: "cut")
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

    /// Tests: a probe for the undecided onset `item` now (`EarCore.Action.probe`).
    func probeForTesting(_ item: String) {
        let t = graph.now
        inner.withLock { s in apply(s.core.probeNow(item, at: t), &s) }
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
            flushTailDrops(&s, at: t)
            if let sp = s.spec, t - sp.armedAt >= Self.speculativeMax - 1e-9 {
                discardSpec(&s, at: t, byVoice: true, why: "timeout")
            }
            for (item, p) in s.wordsPartial where t - p.at >= Self.holdSettle - 1e-9 {
                // Settled words she never said: the user (her own words wait for
                // the full transcript — more of them may yet come).
                guard let pending = s.wordsPending[item] else { s.wordsPartial[item] = nil; continue }
                guard !isHerEcho(item, p.text, strict: pending.strict, &s, at: t) else { continue }
                mark(.note, detail: "words of \(item): the user (settled)")
                wordsDecided(item, user: true, &s)
                // Tune 6: right after she went on, "I'm…" may be the rest of the
                // backchannel: its full words decide (`userTranscript`), not this.
                if s.graceItems.contains(item), Backchannel.mayBecomeBackchannel(p.text) { continue }
                holdForWords(item, text: p.text, partialAt: p.at, &s)
            }
            for (item, w) in s.wordsPending where t - w.since >= Self.wordsWait {
                mark(.note, detail: "no words for \(item): her echo")
                wordsDecided(item, user: false, &s)
            }
        }
    }

    /// A hold's deadlines and settled words.
    private func checkHold(_ s: inout Inner, at t: Double) {
        guard var h = s.hold, !h.probe else { return }
        // Tune 9 (T8-1): what each item sounded like, up to its commit.
        for item in h.items where !h.tails.contains(item) {
            guard let snd = s.core.itemSound(itemID: item, until: h.closedAt[item] ?? t), h.sounds[item] != snd else { continue }
            h.sounds[item] = snd
            s.hold?.sounds[item] = snd
        }
        for item in h.items where !h.shortBursts.contains(item) && h.closedAt[item] != nil && isShort(item, s, at: t) {
            h.shortBursts.insert(item)
            s.hold?.shortBursts.insert(item)
        }
        // Words that are a continuer only in a hold: count when the burst was short.
        for item in h.items where !h.shortItems.contains(item) {
            guard let w = h.final[item] ?? h.partial[item], !Backchannel.isBackchannel(w),
                  Backchannel.isBackchannel(w, inHold: true, final: h.final[item] != nil, sound: h.sounds[item]),
                  h.shortBursts.contains(item) || isShort(item, s, at: t) else { continue }
            h.shortItems.insert(item)
            s.hold?.shortItems.insert(item)
            s.shortHoldItems.append(item)
            if s.shortHoldItems.count > 16 { s.shortHoldItems.removeFirst(s.shortHoldItems.count - 16) }
            mark(.note, detail: "hold-only continuer \(item) (short)")
        }
        let lastSound = s.core.lastUserSoundTime
        let quiet = t - lastSound >= Self.holdCommitSilence
        if let item = h.itemID, !h.committed, !h.commitSent, h.wordsAt == nil, quiet {
            // The server stopped their speech and they are quiet: their words now,
            // not after the server's end-of-turn hold. Or (tune 3) a short burst of
            // theirs has ended — "Go on.", "Mm-hm." — and the server hasn't said so
            // yet: the same, at once.
            let stopped = h.speechStoppedAt != nil
            let quick = !stopped && h.earlierWordsGoOn
                && (s.core.lastUserBurst(since: h.since - Self.holdBurstLookback, gap: Self.holdCommitSilence).map {
                    $0.end - $0.start <= Self.holdQuickBurst + 1e-9 && $0.end > (h.commitAt ?? -.infinity)
                } ?? false)
            if stopped || quick {
                s.hold?.commitSent = true
                s.hold?.commitAt = t
                s.hold?.quickCommit = quick
                s.burstCommit = (t, false)
                if quick { mark(.note, detail: "quick commit (hold) \(item)") }
                command(.commitSpeech)
            }
        }
        guard let h = s.hold else { return }
        let settle = h.quickCommit ? Self.holdSettleQuick : Self.holdSettle
        let settled = h.lastDeltaAt.map { t - $0 >= settle - 1e-9 } ?? false
        // Never over them; and not while what they said since the latest commit
        // is in no item yet (its words may say more than "go on").
        let quietNow = t - lastSound >= Self.holdResumeQuiet - 1e-9
        let uncovered = h.committed && (h.commitAt.map { lastSound > $0 + 0.05 } ?? false)
            && t - lastSound < Self.holdUncoveredWait
        // An item still without words holds her unless its words are late (its
        // commit long past): the user may have said more than "go on" in it.
        let wordsLate = quiet && h.committed && (h.commitAt.map { t - $0 >= Self.holdWordsLate - 1e-9 } ?? false)
        let partialAnswers = !h.quickCommit || (h.lastDeltaAt.map { t - $0 >= Self.holdFinalWait - 1e-9 } ?? true)
        let verdict = h.verdict(settled: settled, quiet: wordsLate, partialAnswers: partialAnswers)
        if h.goOn, verdict != .answer, quietNow, !uncovered, !h.deferGoOn(talking: s.core.voiceActive(at: t)) {
            resumeHold(&s, at: t, why: "brain")
            return
        }
        switch verdict {
        case .resume:
            guard quietNow, !uncovered else { break }
            resumeHold(&s, at: t, why: "words")
            return
        case .answer:
            // They meant it: the brain answers (`respond` ends her reply where she
            // paused); if nobody does, `holdAfterWords` does — never while the
            // brain's go-on waits (tune 10, T9-1: the other deadlines still hold).
            if h.wordsAt == nil, !h.goOn { s.hold?.wordsAt = t }
        case .wait:
            break
        }
        guard let h = s.hold else { return }
        if t - h.since >= Self.holdMax - 1e-9
                    || ((h.speechStoppedAt ?? (h.committed ? h.commitAt : nil)).map { t - $0 >= Self.holdWordsWait - 1e-9 } ?? false)
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
                case .discard(let items):
                    let o = await session.bargeIn(cuts: items.map { ($0, 0) })
                    let truncated = o.truncations.map(\.itemID).joined(separator: ",")
                    timeline.mark(.note, at: graph.now,
                                  detail: "speculative dropped cancel=\(o.cancelledResponse) truncated_at_0=\(truncated)")
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
                if let sp = s.spec {
                    // Nothing more comes for it, and the server is gone: dropped locally.
                    s.spec = nil
                    s.responseGated = false
                    var buffered = 0
                    for item in sp.items { buffered += graph.player.discard(utterance: item) }
                    let held = Set(sp.items)
                    s.sessionItems.removeAll { held.contains($0) }
                    if s.sessionItems.isEmpty { s.sessionPlaying = false }
                    mark(.note, detail: "speculative discarded \(sp.responseID ?? "-") (disconnected)")
                    speculativeContinuation.yield(.discarded(responseID: sp.responseID, items: sp.items,
                                                             bufferedMs: buffered, byVoice: true, why: "disconnected"))
                }
                if s.hold?.probe == true {
                    graph.player.flush()
                    s.hold = nil
                } else if s.hold != nil {
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
                s.wordsPartial.removeAll()
                s.responseOpen = false
                s.lastDoneCompleted = false
                s.tailDrops.removeAll()                 // the next session never had them
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
                if s.core.onsetEarlyInStretch(itemID: item, within: Self.echoOnsetWindow) {
                    s.echoProneItems.append(item)
                    if s.echoProneItems.count > 16 { s.echoProneItems.removeFirst(s.echoProneItems.count - 16) }
                }
                if s.core.onsetEarlyInStretch(itemID: item, within: .infinity) {
                    s.echoExposedItems.append(item)
                    if s.echoExposedItems.count > 16 { s.echoExposedItems.removeFirst(s.echoExposedItems.count - 16) }
                }
                if s.core.isDeciding(item) {
                    s.heldStarts[item] = e
                    forward = false
                    timeline.mark(.bargeInSpeechStarted, at: onset ?? t, detail: item)
                } else {
                    timeline.mark(.speechStarted, at: onset ?? t, detail: item)
                }
                if forward { brain.yield(.session(e)); forward = false }
                apply(actions, &s)
                if s.hold != nil, s.hold?.probe != true, !s.rejected.contains(item), s.heldStarts[item] == nil {
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
                noteTail(item, end: end, at: t, &s)
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
                noteTail(item, end: nil, at: t, &s)
                // An onset still undecided (an early commit) is decided now.
                if s.core.isDeciding(item) { apply(s.core.serverCommitted(itemID: item, at: t), &s) }
                apply(s.core.serverItemCommitted(itemID: item, at: t), &s)
                if s.hold?.itemID == item {
                    s.hold?.committed = true
                    if s.hold?.commitSent != true { s.hold?.commitAt = t }
                }
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
                    s.wordsPartial[item] = ((s.wordsPartial[item]?.text ?? "") + delta, t)
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
                    let user = !isHerEcho(item, text, strict: pending.strict, &s, at: t)
                    mark(.note, detail: "words of \(item): \(user ? "the user" : "her echo")")
                    wordsDecided(item, user: user, &s)
                    if user { holdForWords(item, text: text, partialAt: nil, &s) }
                }
                if let i = s.graceItems.firstIndex(of: item), s.wordsPending[item] == nil {
                    // Tune 6: an onset she talked on through (`resumeGrace`), decided the user's.
                    s.graceItems.remove(at: i)
                    if !s.rejected.contains(item) {
                        if Backchannel.isBackchannel(text) {
                            if !s.backchannelItems.contains(item) {
                                s.backchannelItems.append(item)
                                if s.backchannelItems.count > 32 { s.backchannelItems.removeFirst(s.backchannelItems.count - 32) }
                            }
                            mark(.note, detail: "after resume: backchannel \(item)")
                            holdContinuation.yield(.resumed(itemIDs: [item], text: text, why: "after-resume"))
                        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            holdForWords(item, text: text, partialAt: nil, &s)
                        }
                    }
                }
                if s.rejected.contains(item) {
                    forward = false
                } else {
                    mark(.transcript, detail: item)
                    apply(s.core.serverTranscript(itemID: item, text: text, at: t), &s)
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if s.hold?.items.contains(item) == true {
                        s.hold?.final[item] = text
                        if empty { s.hold?.emptyWords.insert(item) }
                        checkHold(&s, at: t)
                    }
                    if empty, s.tailItems.contains(item) {
                        // The tail of a burst, with nothing in it: out of the conversation,
                        // and never "words failed" for the brain (that answers it). Tune 7
                        // (T6-1): not while a reply may be on its way unheard — the session
                        // cancels a reply whose turn the dropped item is (it was the latest
                        // commit when the brain asked): "Are you awake?" was never answered.
                        if !s.tailDrops.contains(item) { s.tailDrops.append(item) }
                        flushTailDrops(&s, at: t)
                        forward = false
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
                s.wordsPartial[item] = nil
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
                s.lastResponseStartAt = t
                // Stopped before we saw it start (its events were still in the pump)?
                if s.gate.responseStarted(at: t) { mark(.note, detail: "response \(id) was stopped before it started") }
                s.responseKind = kind
                s.responseHasAudio = false
                s.responseGated = false
                if s.spec != nil, kind == .reply || kind == .toolFollowUp, s.gate.isOpen {
                    s.responseGated = true
                    s.spec?.responseIDs.append(id)
                    s.spec?.complete = false
                    if s.spec?.phase == .armed { s.spec?.phase = .waiting }
                    speculativeContinuation.yield(.started(responseID: id))
                }
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
                s.lastResponseDoneAt = t
                if s.responseGated, let sp = s.spec, let id = summary.responseID, sp.responseIDs.contains(id) {
                    s.spec?.complete = true
                    let buffered = sp.items.reduce(0) { $0 + graph.player.bufferedMs(utterance: $1) }
                    speculativeContinuation.yield(.complete(responseID: id, status: summary.status, bufferedMs: buffered))
                }
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
            flushTailDrops(&s, at: t)          // its first audio is in: the session no longer cancels it
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
        if s.responseGated, s.spec != nil, s.spec?.items.contains(item) == false {
            // Held: buffered, never heard until the brain releases it.
            graph.player.gate(utterance: item)
            s.spec?.items.append(item)
            s.spec?.phase = .buffered
            if s.spec?.firstAudioAt == nil { s.spec?.firstAudioAt = t }
            mark(.note, detail: "speculative held \(item)")
            if let id = s.spec?.responseID { speculativeContinuation.yield(.ready(responseID: id, itemID: item, at: t)) }
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
        var talkOn = false
        for a in actions {
            switch a {
            case .emit(let e):
                // A held barge-in is announced when it is decided (`releaseHold`);
                // one she talks on through (`resumeGrace`) is no barge-in at all.
                if e == .bargeIn, s.hold != nil || talkOn { continue }
                voice(e, &s)
            case .bargeIn(let item?) where configuration.holdOnBargeIn && s.sessionPlaying && s.lastSessionItem != nil
                    && s.hold == nil && herVoiceQueued(s)
                    && s.lastResumeAt.map({ graph.now - $0 <= Self.resumeGrace + 1e-9 }) == true:
                // Tune 6: just after she went on from "Keep going.", the rest of it
                // ("I'm listening.") starts: she talks on; its words decide.
                talkOn = true
                let now = graph.now
                apply(s.core.playbackResumed(at: now), &s)      // not a cut stretch: later onsets are decided afresh
                if s.wordsPending[item] == nil { s.wordsPending[item] = (now, [], false) }
                s.graceItems.append(item)
                if s.graceItems.count > 16 { s.graceItems.removeFirst(s.graceItems.count - 16) }
                mark(.note, detail: "after resume: words decide \(item)")
            case .bargeIn(let item) where s.hold?.probe == true:
                // Their voice in her silence: the probe was them. A hold since the pause.
                confirmProbe(item, &s)
                if let item { accept(item, &s) }
            case .bargeIn(let item):
                if configuration.holdOnBargeIn, s.sessionPlaying, s.lastSessionItem != nil, s.hold == nil, herVoiceQueued(s) {
                    // Silent at once; whether her reply ends here their words decide.
                    graph.player.hold()
                    s.hold = FloorHold(itemID: item, since: graph.now)
                    mark(.note, detail: "hold \(item ?? "-")")
                    holdContinuation.yield(.paused(itemID: item))
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
            case .probe(let item):
                // Tune 7 (T6-4): pause her and listen. Not right after she went on from
                // a backchannel (`resumeGrace`: those onsets are left to their words).
                let now = graph.now
                guard configuration.holdOnBargeIn, s.sessionPlaying, s.lastSessionItem != nil, s.hold == nil,
                      herVoiceQueued(s), s.lastResumeAt.map({ now - $0 <= Self.resumeGrace + 1e-9 }) != true else { break }
                graph.player.hold()
                var h = FloorHold(itemID: nil, since: now)
                h.probe = true
                s.hold = h
                mark(.note, detail: "probe \(item)")
            case .probeEnded:
                guard s.hold?.probe == true else { break }
                // Nobody spoke into her silence: she goes on from exactly there.
                s.hold = nil
                graph.player.resume()
                mark(.note, detail: "probe over")
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

    /// The words of `item`, an item left to its words (`deferToWords`), are only her echo.
    ///
    /// Tune 11 (T10-2b / T10-3): one word over her voice with no echo cancellation is
    /// judged by her echo model, not by which word came back (one word can never reach the
    /// two- or three-new-word bar, and any word can be a mishearing either way): the item's
    /// sound her playback explains is her echo, whatever its word (live echo10 bc01: her
    /// echo came back as "Sorry." and stopped her); a voice in it her echo can't be is the
    /// user's, whatever its word (live echo10 c01: "Stop." came back as "Doc." and was
    /// deleted as her echo while she talked on).
    /// One word a person says alone to stop, call or ask her (not "sorry": T10-2b's echo).
    static let stopsHerAlone: Set<String> = ["stop", "wait", "no", "hey", "hello", "what"]

    private func isHerEcho(_ item: String, _ text: String, strict: Bool, _ s: inout Inner, at t: Double) -> Bool {
        // Tune 11 review: never deleted on sound alone when the word stops her ("Stop.",
        // offline l01 1.5 s in measured "explained"): the words decide it, as at 89d0c0f.
        let one = HerWords.words(text)
        if one.count == 1, s.echoExposedItems.contains(item),
           let explained = s.core.echoExplains(itemID: item, at: t),
           !(explained && Self.stopsHerAlone.contains(one[0])) {
            if !explained, !s.voiceOverEchoItems.contains(item) {
                s.voiceOverEchoItems.append(item)
                if s.voiceOverEchoItems.count > 16 { s.voiceOverEchoItems.removeFirst(s.voiceOverEchoItems.count - 16) }
                mark(.note, detail: "one word of \(item): a voice her echo can't be")
            }
            return explained
        }
        return s.herWords.isHerEcho(text, at: t, strict: strict)
    }

    /// An item's words decided it: the user's (the brain gets everything held
    /// back, in order) or her echo (deleted; the brain never sees it).
    private func wordsDecided(_ item: String, user: Bool, _ s: inout Inner) {
        s.wordsPartial[item] = nil
        guard let pending = s.wordsPending.removeValue(forKey: item) else { return }
        s.core.wordsDecided(itemID: item)
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
        if h.commitSent, s.burstCommit != nil { s.burstCommit?.resumed = true } else { s.burstCommit = nil }
        graph.player.resume()
        apply(s.core.playbackResumed(at: t), &s)
        mark(.note, detail: "resumed \(h.itemID ?? "-") (\(why))")
        if why != "echo" {
            if echoProne(h, s) {
                // Tune 8 (T7-3): likely her own echo ("Yeah." 0.26 s into her reply, AEC
                // off): no grace — the next onset over her pauses her on its sound.
                mark(.note, detail: "no grace: echo-prone \(h.items.joined(separator: ","))")
                s.lastResumeAt = nil
            } else {
                s.lastResumeAt = t
            }
            s.backchannelItems.append(contentsOf: h.items)
            if s.backchannelItems.count > 32 { s.backchannelItems.removeFirst(s.backchannelItems.count - 32) }
        }
        holdContinuation.yield(.resumed(itemIDs: h.items, text: h.text, why: why))
    }

    /// Tune 8 (T7-3): the hold is likely her own echo — every item of it began early
    /// in her stretch with no echo cancellation (`echoOnsetWindow`), and all its words
    /// are at most one word (fillers aside). "Keep going." (two words) never is.
    private func echoProne(_ h: FloorHold, _ s: Inner) -> Bool {
        let items = h.items.filter { !h.tails.contains($0) }
        guard !items.isEmpty, items.allSatisfy(s.echoProneItems.contains) else { return false }
        let text = items.map { h.final[$0] ?? h.partial[$0] ?? "" }.joined(separator: " ")
        return Backchannel.words(text).filter { !Backchannel.fillers.contains($0) }.count <= 1
    }

    /// A server item that is only the tail of the burst we just committed
    /// (`holdTailMax`): it joins the hold (deciding nothing without words), or —
    /// she already went on — it is a backchannel too. Never a turn: the brain
    /// releases it (`inHold` / `wasBackchannel` at its commit).
    private func noteTail(_ item: String, end: Double?, at t: Double, _ s: inout Inner) {
        guard let burst = s.burstCommit, t - burst.at <= Self.holdTailWindow + 1e-9 else { return }
        guard !s.rejected.contains(item), s.wordsPending[item] == nil, s.heldStarts[item] == nil else { return }
        if let h = s.hold {
            guard h.commitSent, h.commitAt == burst.at, !h.items.contains(item) || h.tails.contains(item) else { return }
        } else {
            guard burst.resumed, !s.backchannelItems.contains(item) else { return }
        }
        if s.tailItems.contains(item) { return }
        // Its speech ended right after our commit: the rest of the same burst. No
        // end yet (a commit without a stop): only right after our commit.
        let short = end.map { $0 - burst.at <= Self.holdTailMax + 1e-9 } ?? (t - burst.at <= Self.holdTailMax + 1e-9)
        // Their voice after our commit that this item may hold: a turn's words.
        let spoke = s.core.lastUserSoundTime > burst.at + Self.holdTailMax
        guard short, !spoke else { return }
        s.tailItems.append(item)
        if s.tailItems.count > 16 { s.tailItems.removeFirst(s.tailItems.count - 16) }
        if s.hold != nil {
            s.hold?.addTail(item)
            mark(.note, detail: "tail \(item) (hold)")
        } else {
            s.backchannelItems.append(item)
            if s.backchannelItems.count > 32 { s.backchannelItems.removeFirst(s.backchannelItems.count - 32) }
            mark(.note, detail: "tail \(item) (resumed)")
            holdContinuation.yield(.resumed(itemIDs: [item], text: "", why: "tail"))
        }
        command(.acceptSpeech(item))
    }

    /// Words she never said, over her voice (an item her echo opened): unless
    /// they say "go on", she goes quiet now and the brain answers them (which
    /// ends her reply where she paused).
    private func holdForWords(_ item: String, text: String, partialAt: Double?, _ s: inout Inner) {
        if s.hold?.probe == true, s.sessionPlaying, !Backchannel.isBackchannel(text) {
            // Words she never said, while a probe has her paused: it is a hold since then.
            confirmProbe(item, &s)
            s.core.probeConfirmed()
            if let partialAt {
                s.hold?.partial[item] = text
                s.hold?.lastDeltaAt = partialAt
            }
            return
        }
        guard s.sessionPlaying, herVoiceQueued(s), s.hold == nil, !Backchannel.isBackchannel(text) else { return }
        graph.player.hold()
        var h = FloorHold(itemID: item, since: graph.now)
        if let partialAt {
            h.partial[item] = text
            h.lastDeltaAt = partialAt
        }
        s.hold = h
        mark(.note, detail: "hold \(item) (words)")
        holdContinuation.yield(.paused(itemID: item))
    }

    /// Tune 7 (T6-1): a reply may be on its way with no audio yet — requested (the
    /// brain's `.responseCreateSent` mark, an armed speculation) or started — or a
    /// queued one may start right after the last response ended. Dropping a user
    /// item now could cancel it (`RealtimeSession.dropUserItem`).
    private func replyMayBeComing(_ s: Inner, at t: Double) -> Bool {
        if s.responseOpen, !s.responseHasAudio, s.responseKind != .initiative { return true }
        if s.spec?.phase == .armed { return true }
        if let sent = timeline.lastTime(of: .responseCreateSent), sent > (s.lastResponseStartAt ?? -.infinity),
           t - sent < Self.requestWait { return true }
        if let done = s.lastResponseDoneAt, t - done < Self.doneGuard { return true }
        return false
    }

    /// A request with no response this long after it was refused or lost.
    static let requestWait = 2.0
    /// A queued request is sent when the previous response ends: its response
    /// starts within this.
    static let doneGuard = 0.5

    /// Drops the empty tails once no reply can be cancelled by it.
    private func flushTailDrops(_ s: inout Inner, at t: Double) {
        guard !s.tailDrops.isEmpty, !replyMayBeComing(s, at: t) else { return }
        for item in s.tailDrops {
            mark(.note, detail: "empty tail dropped \(item)")
            command(.run { await $0.dropUserItem(itemID: item, resumePreempted: false) })
        }
        s.tailDrops.removeAll()
    }

    /// Tune 7: the probe was the user (their voice in her silence, or their words):
    /// a hold from when she paused, announced to the brain now.
    private func confirmProbe(_ item: String?, _ s: inout Inner) {
        guard s.hold?.probe == true else { return }
        s.hold?.probe = false
        if let item { s.hold?.add(item) }
        mark(.note, detail: "probe confirmed \(item ?? "-")")
        holdContinuation.yield(.paused(itemID: item))
    }

    /// A hold ended as a real barge-in: marked when she paused (she was silent
    /// from then on); announced (`.bargeIn`) only when `announce`.
    private func releaseHold(_ s: inout Inner, announce: Bool) {
        guard let h = s.hold else { return }
        s.hold = nil
        if h.probe { return }                      // nothing was announced: nothing ends
        timeline.mark(.bargeIn, at: h.since, detail: h.itemID)
        if announce { continuation.yield(.bargeIn) }
        holdContinuation.yield(.ended(itemIDs: h.items, byVoice: announce))
    }

    /// Stops her reply where the listener is: flush, then tell the server exactly
    /// how much of the item was played. Late audio of that response is gated out.
    /// A hold it ends is a barge-in (timeline mark at the pause); `announce`: the
    /// voice ended it on its own (no words came, nobody answered them), so the app
    /// hears `.bargeIn`. When the brain ends it (`respond`, `stopSpeaking`) it is
    /// already acting on their words: no event that would stop its new reply.
    private func cutReply(_ s: inout Inner, announce: Bool = false) {
        s.core.initiativePending = false
        specCut(&s, why: "cut")
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
