import AVFAudio
import DeeCore
import DeeRealtime
import DeeWake
import Foundation
import Synchronization

/// Module namespace for DeeVoice.
public enum DeeVoiceModule {}

/// Dee's voice on the OpenAI realtime API: the one `RealtimeSession` hears, thinks
/// and speaks; this class connects it to Dee's own `AudioGraph` and turns it into
/// the `VoiceEvent`s Dee's face and floor logic understand.
///
/// **Audio.** The microphone (24 kHz PCM16 from `graph.capture`) streams to the
/// session while connected and listening, starting with a pre-roll (2 s on the
/// first connect; exactly the unsent audio after a reconnect or a pause), so the
/// first words are never lost. Dee's audio (`.assistantAudio`) plays through
/// `graph.player`, the same engine that cancels Dee's echo from the microphone.
///
/// **Who has the floor.** The session reports user speech but never answers or
/// interrupts on its own. `EarCore` decides, with local evidence, whether a
/// server onset during Dee's playback is the user (barge-in: flush the player,
/// `bargeIn(cuts:)` so the server's copy of every item Dee had playing or queued
/// ends exactly where the listener stopped hearing, then `acceptSpeech`) or Dee's own echo (`rejectEcho`: the item is deleted and the
/// brain never sees it). Audio of a cut response is gated out until the next
/// `.responseStarted`. An interruption (`.playbackCut`) is reported to the
/// server the same way and cancels a reply still on its way. The session hears
/// `playbackFinished` only once Dee's echo tail has passed, so an echo onset
/// right after Dee stops never preempts a pending reply or initiative. A clip
/// counts as Dee's voice too (`setLocalPlayback`, until its echo tail has passed).
/// **Tune 2.** The uplink is gated (`UplinkGate`): what lies under the room
/// bed's ceiling (a TV across the room, a fan) goes up 30 dB down, so the
/// server never merges a TV with the user. A barge-in over Dee's reply *pauses*
/// Dee (`FloorHold`): silent at once, nothing cut yet; their words decide — a
/// backchannel (`Backchannel`: "keep going", "mm-hm") and Dee goes on from
/// exactly there, anything else and the brain's answer (`respond`) ends Dee's
/// reply where Dee paused (`holdAfterWords` / `holdWordsWait` if nobody does).
/// Dee's next item never starts while an onset with near-end voice is being
/// decided (`holdAtBoundary`). An item Dee's loud echo opened that the sound
/// can't settle is decided by its words (`HerWords`: Dee's own words → echo).
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
///   echo filtered out (`.userSpeechStarted` of an onset over Dee's playback is
///   held until it is known to be the user; nothing of a rejected item gets
///   through, so a `.userCommitted` here is always a real user turn).
/// - `.sentenceStarted` / `.sentenceFinished(heard:)`: Dee's transcript placed on
///   what was actually played (for `deeSaid` and the face).
/// - `.itemPlayed`, `.clipPlayed`, `.connection(VoiceProblem?)`.
///
/// **Asking Dee to speak**: `respond(cue:instructions:reasoningEffort:)` after `.userCommitted`,
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
        /// A barge-in over Dee's reply pauses Dee (`FloorHold`) until their words are
        /// known: a backchannel ("keep going", "mm-hm") lets Dee go on from exactly
        /// there; anything else ends the reply where Dee paused. Off: every
        /// barge-in cuts Dee at once (the words never matter).
        public var holdOnBargeIn = true
        /// Calm (spec "calm", mode 1): onset evidence over Dee's reply *ducks* Dee
        /// (−12 dB; −6 dB in a TV room) instead of pausing Dee; Dee pauses only for
        /// sustained voice, a stop / command word, words that aren't "go on", or the
        /// brain's reply (`FloorHold.Phase`). nil (the default): on for the OpenAI
        /// provider (mode 1), off for a LAN one (modes 2 / 3), unless
        /// `DEE_DUCK_ON_ONSET=0|1` (`CalmTuning.duckOverride`) says otherwise. An explicit
        /// value wins. Needs `holdOnBargeIn`. Off: the 0.6.0 behaviour, byte for byte.
        public var duckOnOnset: Bool?
        /// `duckOnOnset` as it applies (see there).
        public var ducksOnOnset: Bool {
            holdOnBargeIn && (duckOnOnset ?? CalmTuning.duckOverride() ?? provider.isOpenAI)
        }
        /// v0.6 (contract §4): start DORMANT — no socket, no uplink, no key mint,
        /// no clip rendering — until `wake(onsetFrame:)`. The app: true. Off (the
        /// harness's "conversation always open"): connects at `start()` exactly as v0.5.
        public var startsDormant = false
        /// A wake's uplink starts this long before the phrase's onset.
        public var wakePrerollSeconds = 0.3
        /// Who problems name (OpenAI, or a LAN server by host).
        public var provider: ProviderLabel = .openAI
        /// Where each uplinked frame's local voice verdict goes (mode 3's turn detector).
        public var uplinkActivity: UplinkActivity?
        /// Render missing clips once per window, after it connected (the app: true).
        /// Never while DORMANT (`ClipCache.renderAllowed`).
        public var prepareClipsOnWake = false
        /// A held reply nobody released is dropped this long after it was armed
        /// (`TimingProfile.speculativeMax`: longer for a LAN model's slow first token).
        public var speculativeMax = CloudVoice.speculativeMax

        public init() {}
    }

    /// DORMANT ⇄ awake (contract §4), for the window and the eyes.
    public enum AwakeState: Sendable, Equatable {
        /// No socket, nothing sent. Only the phone's own wake ear listens.
        case dormant
        /// Woken: connecting. Yielded before any network call is made.
        case waking
        /// Connected; the uplink is open (from the wake onset − 0.3 s).
        case awake
        /// The connection failed while waking or awake (the window decides what's next).
        case failed(VoiceProblem)
    }

    /// A short local sound for the listening window (no network, never rendered).
    public enum ListeningCue: String, Sendable, CaseIterable {
        /// Dee heard Dee's wake phrase (rising two notes).
        case wake
        /// Dee stopped listening (falling two notes).
        case listeningOff
    }

    /// 16 kHz mono Int16 microphone audio (the wake ear's format) and the 24 kHz
    /// capture-timeline frame of its first sample.
    public typealias MicSink = @Sendable (_ pcm16k: [Int16], _ captureFrame24k: Int64) -> Void

    /// Dee's reply paused for the user (a barge-in whose words aren't known yet).
    /// What they said may arrive as several items (the server splits "Don't
    /// stop. … Keep going."); all of them decide together.
    public struct FloorHold: Sendable, Equatable {
        /// The latest user item of the hold (nil until the server opens one).
        public var itemID: String?
        /// Every user item of the hold, in order.
        public private(set) var items: [String] = []
        /// When Dee's voice paused (graph clock).
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
        /// The brain said "go on" while more of the burst was still coming: Dee
        /// goes on once they are quiet and no item waits for its words.
        var goOn = false
        /// Round 3 review: the items the brain's go-on was for (those with words when it said so).
        var goOnItems: Set<String> = []
        /// Round 3 review (regress F1): items our own quick commit closed (the user may talk on in
        /// the next item: one utterance).
        var ownSplit: Set<String> = []
        /// Round 3 review (regress F2): the sustain test fired while a go-on was known and was
        /// ignored; the ear's sustain test is armed again once something new is being said.
        var sustainIgnored = false
        /// Tune 12: when each item's speech began and ended (graph clock: the server's
        /// times mapped to ours, or when it said so).
        var starts: [String: Double] = [:]
        var ends: [String: Double] = [:]

        /// Tune 12 (live fan15 c05): `item` began at most `Backchannel.continuerTailGap`
        /// after the end of the hold's item before it, whose words are a recognised
        /// continuer ("Keep going." | "I'm with some."). Its own words and sound decide the
        /// rest (`continuerTail`).
        public func followsContinuer(_ item: String) -> Bool {
            guard let i = items.firstIndex(of: item), !tails.contains(item), let start = starts[item],
                  let prev = items[..<i].last(where: { !tails.contains($0) }),
                  let end = ends[prev] ?? closedAt[prev],
                  let w = (final[prev] ?? partial[prev])?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
                  Backchannel.isBackchannel(w, inHold: shortItems.contains(prev), final: false) else { return false }
            return start - end <= Backchannel.continuerTailGap + 1e-9
        }

        /// Tune 12: `words`, said in `item`, are the split-off rest of the continuer before
        /// it (`followsContinuer` + `Backchannel.isContinuerTail`).
        func continuerTail(_ item: String, _ words: String, sound: FragmentSound?) -> Bool {
            followsContinuer(item) && Backchannel.isContinuerTail(words, sound: sound)
        }

        /// Round 3: `item` is still being said — the server has neither ended nor committed it,
        /// and neither did we (tails aside).
        func isOpen(_ item: String) -> Bool {
            !tails.contains(item) && ends[item] == nil && closedAt[item] == nil && !(item == itemID && committed)
        }
        /// Round 3: an item of the hold is still being said.
        var hasOpenItem: Bool { items.contains(where: isOpen) }
        /// Round 3 (TV room, live calm-ask-tv15 q03): an item of the hold is still being said, or
        /// was closed less than `late` ago and has no words yet — the utterance is not all in.
        func tvPending(at t: Double, late: Double) -> Bool {
            items.contains { item in
                if tails.contains(item) { return false }
                if isOpen(item) { return true }
                guard final[item] == nil, partial[item] == nil else { return false }
                return t - (closedAt[item] ?? ends[item] ?? t) < late - 1e-9
            }
        }
        /// Round 3 (live t2-backchannel-echo20 c02): their words already said "go on" — the brain
        /// did (`goOn`), or every item's full words so far do: Dee's sustain test never pauses
        /// Dee over them ("Don't stop." … more of it still being said).
        ///
        /// Round 3 review (regress F2 / correct F1: «Okay.» or «Keep going.», then at once a 2 s
        /// question in a new item — no pause, then `unduck (duckMax)` filed the question as a
        /// backchannel): the go-on covers only what was said so far. An item without words yet,
        /// one still being said whose words so far are not "go on", or one the brain's go-on never
        /// saw (`goOnItems`) is something new: the sustain pause stands for it.
        var goOnKnown: Bool {
            for item in items where !tails.contains(item) {
                guard let raw = final[item] ?? partial[item] else { return false }     // no words yet
                let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let unseen = goOn && !goOnItems.contains(item)
                if w.isEmpty {
                    if isOpen(item) { return false }
                    continue
                }
                let goesOn = wordsGoOn(item, w, final: final[item] != nil) || continuerTail(item, w, sound: sounds[item])
                if !goesOn, isOpen(item) || unseen { return false }
            }
            if goOn { return true }
            guard items.contains(where: { final[$0].map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false })
            else { return false }
            return verdict(settled: true, quiet: true) == .resume
        }

        /// Round 3 review (correct F1): an item the brain's go-on never saw has words that are
        /// not "go on" (a question after «Keep going.»): they decide by their words, the
        /// brain's go-on does not cover them.
        var answerAfterGoOn: Bool {
            guard goOn else { return false }
            return items.contains { item in
                guard !tails.contains(item), !goOnItems.contains(item),
                      let w = final[item]?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty else { return false }
                return !wordsGoOn(item, w, final: true) && !continuerTail(item, w, sound: sounds[item])
            }
        }

        /// Round 3 review (regress F1): the hold's items grouped into utterances. An item joins
        /// the one before it only when our own quick commit closed that one (`ownSplit`) and it
        /// began within `CalmTuning.splitJoinGap` of that commit: one utterance we split (live
        /// calm-ask-tv15 q03, «What?» | «time is it?»). Items the server split itself (its VAD
        /// heard a pause: the TV talking on, phrase after phrase) stay apart.
        var utterances: [[String]] {
            var out: [[String]] = []
            var prev: String?
            for item in items where !tails.contains(item) {
                if let p = prev, ownSplit.contains(p), var last = out.popLast() {
                    let close = closedAt[p] ?? ends[p]
                    if let start = starts[item], let close, start - close > CalmTuning.splitJoinGap + 1e-9 {
                        out.append(last)
                        out.append([item])
                    } else {
                        last.append(item)
                        out.append(last)
                    }
                } else {
                    out.append([item])
                }
                prev = item
            }
            return out
        }

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
        /// Tune 7 (T6-4): a probe (`EarCore.Action.probe`): Dee is paused while the
        /// ear listens into Dee's silence for an onset Dee's loud echo masks. No items
        /// yet, nothing announced; the user's voice or words confirm it (a hold from
        /// `since`), quiet ends it (Dee goes on, nothing happened).
        public internal(set) var probe = false

        /// Calm: how Dee gives way. `.ducked`: Dee keeps talking, quieter, while the sound
        /// is judged — no deadline cuts the reply; it ends by escalation (`.paused`) or by
        /// an unduck. `.paused`: Dee is silent (the 0.6.0 hold; its deadlines count from
        /// `since`, the escalation).
        public enum Phase: Sendable, Equatable { case ducked, paused }
        public internal(set) var phase: Phase = .paused
        /// Calm: when the duck began (graph clock).
        public internal(set) var duckSince: Double?
        /// Calm: the sustain test fired for this hold (`EarCore.Action.sustained`).
        public internal(set) var sustained = false
        /// Calm: why Dee paused ("sustained", "stopword", "answer", "brain", "localOnly",
        /// "legacy"); nil while ducked.
        public internal(set) var why: String?
        /// Calm: the duck began in a TV room (`EarCore.tvRoom`).
        public internal(set) var tvRoom = false
        /// Calm round 2 review (correct F3): a stop word in this item, rejected as Dee's echo,
        /// paused Dee (`rejectedCommand`); its full words, when they say more than the stop
        /// ("Wait, what did you say about the moon?"), go to the brain as a turn
        /// (`HoldEvent.rescued`). `rescued`: they did — the hold waits for the brain's answer.
        public internal(set) var rescueItem: String?
        public internal(set) var rescued = false
        /// Calm: items said in a short burst (`CalmTuning.tokenBurstMax`): laugh tokens,
        /// sound tags and fillers count as "go on" for them (`Backchannel.isHoldSoundToken`).
        public internal(set) var tokenItems: Set<String> = []

        /// `words`, said in `item`, mean "go on" here (the hold's words rule).
        func wordsGoOn(_ item: String, _ words: String, final: Bool) -> Bool {
            Backchannel.isBackchannel(words, inHold: shortItems.contains(item), final: final, sound: sounds[item])
                || (tokenItems.contains(item) && Backchannel.isHoldSoundToken(words, sound: sounds[item]))
        }

        /// Calm: the items whose words so far hold a stop or command word or Dee's name
        /// (`CalmTuning.hasCommandWord`). Round 2: the transcript deltas count as they come —
        /// the first delta with "Stop" / "Wait" decides, never the settled or full words.
        func commandItems(names: [String]) -> [String] {
            items.filter { item in
                if let w = final[item] { return CalmTuning.hasCommandWord(w, names: names) }
                guard let w = partial[item] else { return false }
                return CalmTuning.hasCommandWord(w, names: names, partial: true)
            }
        }

        /// Calm: no item has any words yet (none came, or empty / failed transcripts).
        var noWords: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
                if !wordsGoOn(item, w, final: final[item] != nil) { return false }
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
                if !wordsGoOn(item, clean, final: isFinal), !continuerTail(item, clean, sound: sounds[item]) {
                    if isFinal || partialAnswers { return .answer }
                    pendingAnswer = true                            // its full words decide
                    continue
                }
                anyBackchannel = true
            }
            if pendingAnswer { return .wait }
            if anyBackchannel { return !undecided || quiet ? .resume : .wait }
            // Every item came back empty (noise, a breath, Dee's own echo): Dee goes on.
            return allEmpty && !undecided && !items.isEmpty && items.contains(where: { emptyWords.contains($0) })
                ? .resume : .wait
        }
    }

    /// Tune 5: a hold-only continuer ("She's not going.") counts in an item with
    /// at most this much of their pitched voice ("Keep going" is ~0.6 s).
    public static let holdOnlyBurst = 1.0

    /// Settled transcription deltas this old decide a hold (the brain's `partialSettle`).
    public static let holdSettle = 0.15
    /// A hold never lasts longer than this: Dee's reply then ends where Dee paused.
    public static let holdMax = 6.0
    /// …nor this long after their speech stopped without words that say "go on".
    public static let holdWordsWait = 2.5
    /// A hold with no server item for it ends after this.
    public static let holdNoItem = 2.0
    /// Words that weren't "go on" and nobody answered them: Dee's reply ends this
    /// long after they came.
    public static let holdAfterWords = 1.0
    /// While Dee is held and the server has stopped their speech but holds the
    /// commit (semantic end of turn: up to ~2 s), their voice heard locally
    /// ending this long ago commits it at once (`commitUserSpeech`): the words
    /// that decide come sooner, so a "go on" pauses Dee briefly. Never before the
    /// server's `speech_stopped` (a commit mid-speech splits their words). Dee's
    /// voice is silent in a hold: the local end of speech is clean.
    public static let holdCommitSilence = 0.3
    /// Tune 3 (live: "Go on." / "Mm-hm." / "Don't stop, keep going." resumed
    /// 1.4–4.6 s after they paused Dee — the server's semantic VAD reported the
    /// end of their speech only with its commit, 0.7–2.6 s after the words). In a
    /// hold, a short burst of their voice (at most this long) that ended
    /// `holdCommitSilence` ago is committed at once, without waiting for the
    /// server's `speech_stopped`: the backchannel's words come ~0.15 s later and
    /// Dee goes on ~0.5 s after they stopped. Longer speech is left to the server
    /// (a commit inside a sentence would split it). Only while every earlier item
    /// of the hold said "go on": a real turn is never cut into pieces.
    public static let holdQuickBurst = 1.0
    /// Settled deltas of a quick commit (a short burst: a few words in one burst).
    public static let holdSettleQuick = 0.1
    /// Dee goes on only once they have been quiet this long (never over them:
    /// "Don't stop, … keep going." — the first words are in while they talk on).
    public static let holdResumeQuiet = 0.2
    /// Their sound after the latest commit that no server item holds yet: Dee
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
    /// tail — part of the hold, or a backchannel if Dee already went on.
    public static let holdTailMax = 0.5
    public static let holdTailWindow = 1.2
    /// A quick-committed short burst's settled partial words that are not "go on"
    /// end the hold only with its full transcript, or this long after its last
    /// delta (live: "Go on." came back as "Jeron.").
    public static let holdFinalWait = 0.6
    /// Tune 6: an onset over Dee this soon after Dee went on from a backchannel
    /// ("Keep going." … "I'm listening.") never pauses Dee again on its sound: its
    /// words decide. A backchannel is ignored; a real turn pauses Dee by its words
    /// (`holdForWords`) and the brain answers it.
    public static let resumeGrace = 2.0
    /// Tune 8 (T7-3, live interrupt-echo20): with no echo cancellation, a hold whose
    /// items all began this soon into Dee's stretch and whose words are at most one
    /// word ("Yeah.") is likely Dee's own echo. Dee goes on from it as from a
    /// backchannel, but it arms no `resumeGrace`: a real onset next pauses Dee at once.
    /// (Live: real one-word backchannels began ≥ 1.5 s into Dee's stretch.)
    public static let echoOnsetWindow = 1.2

    /// What the brain (RealtimeBrain) consumes.
    public enum BrainEvent: Sendable, Equatable {
        /// A session event (no audio deltas; echo filtered out).
        case session(RealtimeEvent)
        /// Playback reached the start of sentence `index` of Dee's item.
        case sentenceStarted(itemID: String, index: Int, text: String)
        /// Playback passed the end of the sentence (`heard: true`), or the item was
        /// cut inside it (`heard`: its midpoint was played). An item whose response
        /// didn't complete (socket lost, failed, filtered, token limit) counts as
        /// cut where its audio ran out: the transcript may run ahead of the audio.
        case sentenceFinished(itemID: String, index: Int, text: String, heard: Bool)
        /// One of Dee's items stopped playing: all of it, or `cut` after `playedMs`
        /// (flushed, or its response ended before it was complete).
        case itemPlayed(itemID: String, playedMs: Int, cut: Bool)
        /// A clip finished (or was cut). Clips are local: the session only knows
        /// that something of Dee's is playing (for echo), never what; mention them
        /// in the next cue if they matter.
        case clipPlayed(VoiceClip, cut: Bool)
        /// The cloud voice's health for `VoiceHealth.cloudVoice(_:)` (nil = fine).
        case connection(VoiceProblem?)
    }

    /// A hold's life, for the brain (`holdEvents`).
    public enum HoldEvent: Sendable, Equatable {
        /// Dee's reply paused for a barge-in (`floorHold` is set); their words decide.
        case paused(itemID: String?)
        /// Their words were a backchannel (`why` "words"), the onset was Dee's echo
        /// ("echo"), or the brain said so (`continueAfterBackchannel`, "brain"):
        /// Dee goes on from where Dee paused. `itemIDs`: their items in the hold —
        /// committed turns that need no answer (`wasBackchannel(itemID:)`).
        case resumed(itemIDs: [String], text: String, why: String)
        /// The hold ended as a barge-in: Dee's reply ends where Dee paused.
        /// `byVoice`: no answer came, the voice ended it (`.bargeIn` was emitted).
        case ended(itemIDs: [String], byVoice: Bool)
        /// Calm round 2 review (correct F3): the words of `itemID` — rejected as Dee's echo
        /// (deleted from the conversation), whose stop word paused Dee — say more than the
        /// stop: a turn of the user's. The brain answers `text` (Dee is paused for it).
        case rescued(itemID: String, text: String)
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
        /// Dee's items held in the player, in order.
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
    /// Calm is on for this voice (`Configuration.ducksOnOnset`, resolved once).
    public let duckOnOnset: Bool

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
    /// DORMANT / waking / awake / failed, in order (single consumer; newest 32 kept).
    public let awakeStates: AsyncStream<AwakeState>
    private let awakeContinuation: AsyncStream<AwakeState>.Continuation
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
        /// Dee's items queued or playing, in order.
        var sessionItems: [String] = []
        var lastSessionItem: String?
        /// The session believes Dee's audio is playing (until `playbackFinished` / `bargeIn`).
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
        /// Dee's last item played out: the session hears `playbackFinished` only once
        /// Dee's echo has left the room, so it never takes that echo for the user.
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

        /// Dee's reply is paused for a barge-in whose words decide (`FloorHold`).
        var hold: FloorHold?
        /// What Dee said lately (Dee's echo's words), for items Dee's words decide.
        var herWords = HerWords()
        /// Items whose words decide whether they are Dee's (`deferToWords`): their
        /// session events, held back from the brain until then, and since when.
        var wordsPending: [String: (since: Double, events: [RealtimeEvent], strict: Bool)] = [:]
        /// Settled deltas of items waiting for their words: words Dee never said
        /// decide "the user" before the full transcript (~0.2 s sooner).
        var wordsPartial: [String: (text: String, at: Double)] = [:]
        /// User items Dee went on through (a backchannel in a hold), newest last.
        var backchannelItems: [String] = []
        /// Items of past holds whose short burst let a hold-only continuer count.
        var shortHoldItems: [String] = []
        /// Tune 12: items of past holds that followed a continuer (`FloorHold.followsContinuer`).
        var continuerTailItems: [String] = []
        /// Our latest commit of a hold's burst (graph clock) and whether that hold
        /// already ended: a server tail arriving after the resume is still the burst's.
        var burstCommit: (at: Double, resumed: Bool)?
        /// Tails of our committed bursts (bounded): deleted once their words come back empty.
        var tailItems: [String] = []
        /// The speculation armed or held (`speculate()`).
        var spec: SpeculativeReply?
        /// Tune 6: when Dee last went on from a backchannel (graph clock).
        var lastResumeAt: Double?
        /// Tune 7 (T6-1): empty tails waiting to be dropped (`flushTailDrops`).
        var tailDrops: [String] = []
        /// When the latest response started / ended (graph clock).
        var lastResponseStartAt: Double?
        var lastResponseDoneAt: Double?
        /// Onsets inside `resumeGrace` left to their words (newest 16).
        var graceItems: [String] = []
        /// Tune 8: items that began early in Dee's stretch with no echo cancellation
        /// (`echoOnsetWindow`; newest 16).
        var echoProneItems: [String] = []
        /// Tune 10 (T9-7): items that began while Dee's voice played with no echo
        /// cancellation (newest 16).
        var echoExposedItems: [String] = []
        /// Tune 11 (T10-3): one-word items over Dee's voice that Dee's echo model says are the
        /// user's (`oneWordIsHerEcho`; newest 16): their masked sound and the Dee-echo word
        /// test no longer make them a "go on".
        var voiceOverEchoItems: [String] = []
        /// The open response is held by `spec` (its audio is gated in the player).
        var responseGated = false
        /// Calm: items of holds resolved by a resume or an unduck (graph clock; `holdClaims`),
        /// and whether that hold had no words at all (their late words then go through
        /// `holdForWords`: a late "Stop." still stops Dee).
        var recentlyResolved: [String: (at: Double, wordless: Bool, tv: Bool)] = [:]
        /// Calm round 2: items of a duck that was on when Dee ended the reply on Dee's own (a
        /// sentence / token cap): never a barge-in; an empty transcript or a body sound there is
        /// not answered (`holdClaims`). `empty`: their transcript came back empty. `failed`: their
        /// transcription failed — a turn the brain answers from the audio, labelled or not.
        var ownEndItems: [String: (at: Double, empty: Bool, sound: Bool, failed: Bool)] = [:]
        /// Calm round 2: rejected items' transcript deltas so far (a stop word in them).
        var rejectedPartial: [String: String] = [:]
        /// Calm round 2: Dee's names the user may call Dee by (besides "Dee"): the persona's.
        var names: [String] = []
        /// Calm: items of ducks whose reply played out under them (`duckPlayedOut`).
        var playedOutDucks: [String: Double] = [:]
        /// Calm: items dropped as the TV (`ambient`; newest 32).
        var ambientItems: [String] = []

        /// v0.6: not DORMANT (waking or awake). Connecting, reconnecting and the
        /// uplink only happen while true.
        var awake = true
        /// Connected since the last wake (`.awake` was yielded).
        var awakeAnnounced = false
        /// Bumped by every `wake` / `sleep`: a connect loop of an older one stops.
        var linkGeneration = 0
        /// The next uplink starts here (capture frame), not where the last one ended.
        var wakeFrom: Int64?
        /// `connect(resume:)` for this window.
        var wakeResume = false
        /// Clips were prepared in this window.
        var clipsPrepared = false
        /// Cues in the player (utterance ids).
        var cues: Set<String> = []
        var cueCounter = 0
    }

    /// An item waiting for its words is given up on (deleted as Dee's echo) after this.
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
        let calm = configuration.ducksOnOnset
        self.duckOnOnset = calm
        (stream, continuation) = AsyncStream<VoiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (brainEvents, brain) = AsyncStream<BrainEvent>.makeStream(bufferingPolicy: .unbounded)
        (holdEvents, holdContinuation) = AsyncStream<HoldEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (speculativeEvents, speculativeContinuation) =
            AsyncStream<SpeculativeEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (awakeStates, awakeContinuation) = AsyncStream<AwakeState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        (commandStream, commands) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        let dormant = configuration.startsDormant
        inner.withLock { s in
            s.awake = !dormant
            // DORMANT: sustained local voice never opens an uplink (there is no socket).
            s.core.wakeOnVoice = dormant ? false : configuration.wakeOnVoice
            s.core.duckOnOnset = calm
        }
        if dormant { clips?.renderAllowed = false }
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
    /// or — the item was said in a hold (now or one Dee went on through) in a short
    /// burst — a hold-only continuer ("Keep going" heard as "She's not going.").
    /// The brain uses it in place of `TurnPolicy.isBackchannel` for an item over Dee's voice.
    ///
    /// Tune 9 (T8-1): a one-word fragment the words don't know is one only when the item
    /// sounded like a backchannel (`itemSound`).
    ///
    /// Tune 12 (live fan15 c05): also the split-off rest of a continuer in the same hold
    /// (`FloorHold.followsContinuer` + `Backchannel.isContinuerTail`), as the hold decides.
    public func isHoldBackchannel(itemID: String, text: String) -> Bool {
        if Backchannel.isBackchannel(text) { return true }
        let t = graph.now
        return inner.withLock { s in
            // Tune 12: the split-off rest of a continuer — the hold's own rule.
            if s.hold?.followsContinuer(itemID) == true || s.continuerTailItems.contains(itemID),
               Backchannel.isContinuerTail(text, sound: s.hold?.sounds[itemID] ?? sound(itemID, s, at: t)) { return true }
            // Calm (spec §4.1): a laugh, a sound tag or a filler, in a hold (either phase, or one
            // Dee went on through), said in a short burst.
            if duckOnOnset, s.hold?.items.contains(itemID) == true || s.backchannelItems.contains(itemID)
                || s.recentlyResolved[itemID] != nil || s.ownEndItems[itemID] != nil {
                let snd = s.hold?.sounds[itemID] ?? sound(itemID, s, at: t)
                if (snd?.voiced ?? 0) <= CalmTuning.tokenBurstMax + 1e-9, Backchannel.isHoldSoundToken(text, sound: snd) {
                    return true
                }
            }
            guard Backchannel.isBackchannel(text, inHold: true, sound: sound(itemID, s, at: t)) else { return false }
            if s.hold?.shortItems.contains(itemID) == true || s.shortHoldItems.contains(itemID)
                || s.hold?.shortBursts.contains(itemID) == true { return true }
            guard s.hold?.items.contains(itemID) == true || s.backchannelItems.contains(itemID) else { return false }
            return isShort(itemID, s, at: t)
        }
    }

    /// Tune 9 (T8-1): what server item `itemID` sounded like (`FragmentSound`: seconds of
    /// their voice, syllables, the pitch's end), up to our commit of it if we made one.
    /// Nil when the ear doesn't know the item (rejected as Dee's echo, or long gone).
    public func itemSound(itemID: String) -> FragmentSound? {
        let t = graph.now
        return inner.withLock { sound(itemID, $0, at: t) }
    }

    /// Tune 9 (T8-1): `text`, said in `itemID` over Dee's voice, is a misheard "go on"
    /// (`Backchannel.isMisheardFragment(_:sound:)` with the item's sound): one word the
    /// words don't know ("Movie." for "Who made you?") only when it *sounded* like a
    /// backchannel — short, at most two syllables, not rising. The brain uses it in place
    /// of the words-only `TurnPolicy.isMisheardFragment` for an item it knows.
    ///
    /// Tune 10 (T9-7, live backchannel-echo20: Dee's echo came back as "Me." 2.6 s into Dee's
    /// stretch, no echo cancellation, and cut Dee): one word over Dee's playing voice with no
    /// echo cancellation goes on as Dee's echo unless its words (`HerWords`: a word a person
    /// says alone — "Stop.", "No." — or a "?") or its sound (`FragmentSound.questionLike`)
    /// say someone spoke.
    public func isMisheardFragment(itemID: String, text: String) -> Bool {
        let t = graph.now
        return inner.withLock { s in
            let snd = sound(itemID, s, at: t)
            if Backchannel.isMisheardFragment(text, sound: snd) { return true }
            // Tune 11 (T10-3): a voice Dee's echo can't explain said it — the user's, by its words.
            if s.voiceOverEchoItems.contains(itemID) { return false }
            let kept = Backchannel.words(text).filter { !Backchannel.fillers.contains($0) }
            // A word a person says alone ("Enough.", "Pause.", "Nope.") is theirs (review).
            guard s.echoExposedItems.contains(itemID), !text.contains("?"), snd?.questionLike != true,
                  kept.count == 1, !Backchannel.aloneWords.contains(kept[0]) else { return false }
            return s.herWords.isHerEcho(text, at: t)
        }
    }

    private func sound(_ item: String, _ s: Inner, at t: Double) -> FragmentSound? {
        // Tune 11 (T10-3): their voice under Dee's un-cancelled echo is masked; what is left
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

    /// Dee's reply paused for the user right now (nil: not paused). While held Dee
    /// is silent, nothing is cut yet, and `.bargeIn` hasn't been emitted. Calm: also a
    /// ducked hold (`phase == .ducked`: Dee still talks, quieter, while their sound is judged).
    public var floorHold: FloorHold? { inner.withLock { $0.hold?.probe == true ? nil : $0.hold } }

    /// Calm (spec §4.2, the `wordsFailed` race): `itemID` belongs to the current hold (a duck,
    /// or a pause for a labelled sustained sound: `claimsNoWords`), or to one the voice
    /// resolved by a resume or an unduck within `CalmTuning.recentlyResolvedTTL`: the voice
    /// decides it — the brain never answers it for failed or empty words. Read synchronously,
    /// so the outcome is the same whichever pump runs first. Always false with calm off.
    public func holdClaims(itemID: String) -> Bool {
        guard duckOnOnset else { return false }
        let t = graph.now
        return inner.withLock { s in
            if let h = s.hold, !h.probe, h.items.contains(itemID) { return claimsNoWords(h, s, at: t) }
            if let r = s.recentlyResolved[itemID], t - r.at <= CalmTuning.recentlyResolvedTTL + 1e-9 { return true }
            // Round 2: Dee ended the reply on Dee's own over their sound — a laugh's empty words
            // (live calm-sounds-clean ns09: answered with a 5.9 s reply) or a labelled sound is
            // not a turn; failed words still are (the brain answers the audio, as in 0.6.0) —
            // also with a cough or laugh label in the burst (round 2 review, regress F3: a cough,
            // then "What time is it?" with failed words went unanswered). Until the words come,
            // a labelled sound keeps the brain waiting for them.
            if let o = s.ownEndItems[itemID], t - o.at <= CalmTuning.recentlyResolvedTTL + 1e-9 {
                return o.empty || (o.sound && !o.failed)
            }
            // (A reply that played out under the duck leaves an ordinary turn: never claimed,
            // so failed words are answered from the audio as in 0.6.0 — review F2.)
            return false
        }
    }

    /// Calm: a hold whose words never come is the voice's to end as Dee going on — a ducked
    /// one (a short sound), or a pause for a sustained sound labelled a laugh / cough / sneeze /
    /// breath (R5). Any other pause with no words ends as in 0.6.0: the brain answers the
    /// audio (review F3: a sustained question whose transcription failed).
    private func claimsNoWords(_ h: FloorHold, _ s: Inner, at t: Double) -> Bool {
        if h.phase == .ducked { return true }
        return h.why == "sustained" && soundLike(h, s, at: t)
    }

    /// Calm R5: the sustained burst of `h` had a body-sound label over it.
    private func soundLike(_ h: FloorHold, _ s: Inner, at t: Double) -> Bool {
        s.core.bodySound(from: (h.duckSince ?? h.since) - CalmTuning.sustainLookback, to: t)
    }

    /// Calm (spec §3.3): `itemID`, said in a ducked hold in a TV room, is the TV: its words
    /// (`text`, so far) hold no stop or command word, the user's voice was never sustained,
    /// and no item of the hold has a voice of its own at the TV bar
    /// (`CalmTuning.itemSustain`, `itemSustainShare`) — or the voice already dropped it as
    /// ambient. The brain never asks for a reply to it. Always false with calm off.
    public func isAmbient(itemID: String, text: String) -> Bool {
        guard duckOnOnset else { return false }
        let t = graph.now
        return inner.withLock { s in
            if s.ambientItems.contains(itemID) { return true }
            guard let h = s.hold, !h.probe, h.phase == .ducked, h.items.contains(itemID) else { return false }
            // (A stop word or Dee's name counts only with the item's own voice over the TV.)
            if CalmTuning.hasCommandWord(text, names: s.names), commandVoiced(itemID, h, s, at: t) { return false }
            return ambientHold(h, s, at: t)
        }
    }

    /// Calm: Dee's reply played out while `itemID`'s duck was on (within
    /// `CalmTuning.recentlyResolvedTTL`): a "go on" for it needs no carry-on (Dee finished).
    public func duckPlayedOut(itemID: String) -> Bool {
        guard duckOnOnset else { return false }
        let t = graph.now
        return inner.withLock { s in
            s.playedOutDucks[itemID].map { t - $0 <= CalmTuning.recentlyResolvedTTL + 1e-9 } ?? false
        }
    }

    /// Calm round 2 (D2): the names the user may call Dee by besides "Dee" (the persona's,
    /// "Mira"): said over a ducked Dee, they pause Dee like a stop word.
    public func setAddressNames(_ names: [String]) {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "dee" }
        inner.withLock { $0.names = clean }
    }

    /// Tune 7 (T6-4): Dee is paused for a probe right now (an onset over Dee that
    /// Dee's echo masks: the ear listens into Dee's silence). Not a hold yet: the brain
    /// hears `.paused` only if their voice or words confirm it.
    public var isProbing: Bool { inner.withLock { $0.hold?.probe == true } }

    /// The words over Dee's voice were a backchannel: Dee goes on from where Dee
    /// paused. No-op without a hold. Returns whether Dee resumed.
    @discardableResult
    public func continueAfterBackchannel() -> Bool {
        let t = graph.now
        return inner.withLock { s in
            guard let h = s.hold, !h.probe else { return false }
            // Tune 5 (live kitchen15 / echo20 c05): the server split one burst —
            // "Keep going" | "I'm listening." — and the brain's go-on for the first
            // came while the second was still being said. Dee goes on once all of
            // it is in (`checkHold`: its words decide), never over them.
            if h.deferGoOn(talking: s.core.voiceActive(at: t)) {
                s.hold?.goOn = true
                // Round 3 review (correct F1): the go-on is for the words the brain heard — not for
                // an item still without words (they may be asking something new in it).
                s.hold?.goOnItems.formUnion(h.items.filter { h.final[$0] != nil || h.partial[$0] != nil })
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

    /// `itemID` was (part of) a backchannel Dee went on through: a committed turn
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

    /// The speculation is not wanted: dropped unheard, with no side effects on Dee's
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

    /// Something of Dee's that is not a held speculation is queued or playing.
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
                // Nothing of Dee's is left: Dee never played (no echo tail to wait out).
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

    /// The speculation went with a cut of Dee's voice (the flush took its audio).
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

    /// The session is connected (and hearing Dee, when listening).
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
        if inner.withLock({ $0.awake }) {
            startConnecting()
        } else {
            awakeContinuation.yield(.dormant)
        }
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
        awakeContinuation.finish()
        tasks.withLock { list in list.forEach { $0.cancel() } }
    }

    @discardableResult
    public func play(_ clip: VoiceClip, deferWhileUserSpeaks: Bool) -> Bool {
        guard let pcm = clips?.pcm(clip) else { return false }
        let t = graph.now
        return inner.withLock { s -> Bool in
            guard s.started, !s.shutDown, s.audioUp else { return false }
            // Never over (or queued ahead of) Dee's own reply, nor while an initiative
            // is on its way (its echo would read as the user beating it).
            guard !s.sessionPlaying, s.sessionItems.isEmpty, !s.core.initiativePending else { return false }
            if deferWhileUserSpeaks, s.core.userIsSpeaking(at: t) { return false }
            s.clipCounter += 1
            let id = "clip-\(s.clipCounter)-\(clip.rawValue)"
            s.clips[id] = clip
            // Dee's own voice for the session's echo logic: an onset over the clip
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

    public func stopSpeaking() { stopSpeaking(ownEnd: false) }

    /// `ownEnd`: Dee ends the reply on Dee's own (the brain's sentence or token cap), not
    /// for the user. Calm round 2: a duck on then is released, not escalated — their sound
    /// never cut Dee (no barge-in), and its empty or sound-only words are no turn
    /// (`holdClaims`; live calm-sounds-clean ns09: a laugh answered with a 5.9 s reply).
    public func stopSpeaking(ownEnd: Bool) {
        let t = graph.now
        inner.withLock { s in
            if ownEnd, duckOnOnset, let h = s.hold, !h.probe, h.phase == .ducked {
                s.hold = nil
                graph.player.unduck()
                s.core.unducked(at: t)
                let sound = soundLike(h, s, at: t)
                for item in h.items {
                    s.ownEndItems[item] = (t, h.emptyWords.contains(item), sound, false)
                    s.playedOutDucks[item] = t
                }
                mark(.note, detail: "unduck \(h.itemID ?? "-") (stopped)")
            }
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

    // MARK: Asking Dee to speak (for the brain)

    /// Answers the committed user turn (call on `.session(.userCommitted)`). `cue`
    /// goes in first as a system item; `instructions` override the session's for
    /// this response. If Dee's previous reply is somehow still playing it is cut
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
    /// open server speech) or while anything of Dee's is playing; cancelled if the
    /// user starts talking before its first audio (locally, ahead of the server).
    /// `reasoningEffort` as for `respond`.
    @discardableResult
    public func initiative(instructions: String, cue: String? = nil,
                           maxOutputTokens: Int? = nil, reasoningEffort: String? = nil) async -> InitiativeOutcome {
        let t = graph.now
        let refusal = inner.withLock { s -> InitiativeOutcome.Refusal? in
            if s.shutDown || !s.connected { return .notConnected }
            if s.core.userIsSpeaking(at: t) { return .userSpeaking }
            // Also while Dee's echo is still in the room: it would read as the user.
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

    /// A line Dee should say (nearly) word for word, as an initiative: the model
    /// speaks it in Dee's session voice. Same gating as `initiative`.
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
        // DORMANT: a saved key or endpoint is used at the next wake (W2: nothing now).
        let awake = inner.withLock { s -> Bool in
            s.needsSetup = false
            return s.awake
        }
        if awake { startConnecting() }
    }

    // MARK: DORMANT ⇄ awake (v0.6)

    /// Not DORMANT: waking (connecting) or awake (connected).
    public var isAwake: Bool { inner.withLock { $0.awake } }

    /// The capture timeline's "now" (24 kHz frames): what a tap-to-wake passes.
    public var captureFrame: Int64 { graph.capture.capturedFrames }

    /// Wakes Dee (the local wake phrase, a tap, a due greeting): yields `.waking`
    /// before anything touches the network, then connects (`connect(resume:)`).
    /// Once connected the uplink opens `wakePrerollSeconds` before `onsetFrame`
    /// (a capture-timeline frame; nil = now), so "Hey Dee, what time is it?" said
    /// in one breath reaches the server whole. Already awake: the uplink is left
    /// alone (a phrase heard in an open window changes nothing here).
    public func wake(onsetFrame: Int64?, resume: Bool = true) {
        let pre = Int64((configuration.wakePrerollSeconds * PCM16Capture.sampleRate).rounded())
        wake(from: onsetFrame.map { $0 - pre }, resume: resume)
    }

    /// `wake(onsetFrame:)` for a caller that already subtracted the pre-roll
    /// (`ConversationWindow.Action.openUplink(fromFrame:)`): the uplink starts at
    /// exactly `uplinkFromFrame` (nil = now − `wakePrerollSeconds`).
    public func wake(uplinkFromFrame: Int64?, resume: Bool = true) {
        wake(from: uplinkFromFrame, resume: resume)
    }

    private func wake(from frame: Int64?, resume: Bool) {
        let now = graph.capture.capturedFrames
        let pre = Int64((configuration.wakePrerollSeconds * PCM16Capture.sampleRate).rounded())
        let ring = Int64(PCM16Capture.ringSeconds * PCM16Capture.sampleRate)
        let go = inner.withLock { s -> Bool in
            guard s.started, !s.shutDown, !s.awake else { return false }
            s.awake = true
            s.awakeAnnounced = false
            s.linkGeneration += 1
            s.clipsPrepared = false
            s.wakeFrom = max(0, now - ring, min(frame ?? (now - pre), now))
            s.wakeResume = resume
            s.core.wakeOnVoice = configuration.wakeOnVoice
            return true
        }
        guard go else { return }
        mark(.note, detail: "wake")
        awakeContinuation.yield(.waking)
        clips?.renderAllowed = true
        startConnecting()
    }

    /// DORMANT again (the window closed, the app went to the background, the
    /// provider changed): the uplink closes, the session closes (no reconnect, no
    /// rollover, no key mint), sustained voice no longer opens anything, clips are
    /// not rendered. The conversation's words stay for the next `wake` (seed).
    public func sleep() {
        let generation = inner.withLock { s -> Int? in
            guard !s.shutDown, s.awake else { return nil }
            s.awake = false
            s.awakeAnnounced = false
            s.linkGeneration += 1
            s.wakeFrom = nil
            s.core.wakeOnVoice = false
            closeUplink(&s)
            return s.linkGeneration
        }
        guard let generation else { return }
        clips?.renderAllowed = false
        mark(.note, detail: "sleep")
        command(.run { [weak self] session in
            await session.close()
            // A `wake` that came while this close was queued (sleep then wake while
            // still connecting): its link may just have been closed — connect again.
            guard let self, self.inner.withLock({ $0.awake && $0.linkGeneration != generation }) else { return }
            self.startConnecting()
        })
        awakeContinuation.yield(.dormant)
    }

    /// Adds a consumer of the microphone at 16 kHz (the wake ear): fed from the same
    /// tap (VPIO on) in every state, DORMANT included, on the tap thread, in order.
    /// Downsampled by `DeeWake.Downsampler24to16`, whose frame tracking keeps the
    /// 24 kHz capture frame of each chunk's first sample exact.
    public func addMicSink(_ sink: @escaping MicSink) {
        let down = Mutex(Downsampler24to16())
        graph.capture.addSink { chunk in
            let (samples, first) = down.withLock { $0.process(PCM16.samples(chunk.data), firstFrame24k: chunk.startFrame) }
            guard let first, !samples.isEmpty else { return }
            sink(samples, first)
        }
    }

    /// The wake ear hears the microphone from now on (every state; it decides
    /// what it listens for). It never sends anything anywhere.
    public func attach(wakeEar: any WakeEar) {
        addMicSink { pcm, frame in wakeEar.consume(pcm, captureFrame24k: frame) }
    }

    /// Plays a listening cue through Dee's player (echo-cancelled like Dee's voice).
    @discardableResult
    public func playCue(_ cue: ListeningCue) -> Bool {
        let pcm = Self.cuePCM(cue)
        return inner.withLock { s -> Bool in
            guard s.started, !s.shutDown, s.audioUp, !s.sessionPlaying, s.sessionItems.isEmpty else { return false }
            s.cueCounter += 1
            let id = "cue-\(s.cueCounter)-\(cue.rawValue)"
            s.cues.insert(id)
            graph.player.enqueue(pcm, utterance: id)
            graph.player.finish(utterance: id)
            return true
        }
    }

    /// Two soft sine notes (~−28 dBFS, 5 ms fades): up for `.wake`, down for `.listeningOff`.
    static func cuePCM(_ cue: ListeningCue) -> Data {
        let rate = PCM16Capture.sampleRate
        let notes: [Double] = cue == .wake ? [660, 880] : [660, 494]
        let noteFrames = Int(rate * 0.07)
        let fade = Int(rate * 0.005)
        var out: [Int16] = []
        out.reserveCapacity(noteFrames * notes.count)
        for f in notes {
            for i in 0..<noteFrames {
                let env = min(1, Double(min(i, noteFrames - 1 - i)) / Double(fade))
                out.append(Int16(1300 * env * sin(2 * .pi * f * Double(i) / rate)))
            }
        }
        return out.withUnsafeBytes { Data($0) }
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

    /// Tests (calm): a duck for `item` now, as the ear's onset evidence would start one.
    func duckForTesting(_ item: String?) {
        let t = graph.now
        inner.withLock { s in apply(s.core.duckNow(item, at: t), &s) }
    }

    /// Tests (calm): the duck released now (`why` in its note), as a deadline would.
    func unduckForTesting(why: String) {
        let t = graph.now
        inner.withLock { s in unduck(&s, at: t, why: why) }
    }

    /// Tests (calm): our quick commit of the hold's open item now, as `checkHold` sends it after
    /// a short burst (in a TV rig the bed keeps the ear from hearing the user quiet).
    func quickCommitForTesting() {
        let t = graph.now
        inner.withLock { s in
            guard let h = s.hold, let item = h.itemID, !h.committed, !h.commitSent else { return }
            s.hold?.commitSent = true
            s.hold?.commitAt = t
            s.hold?.quickCommit = true
            s.hold?.ownSplit.insert(item)
            s.burstCommit = (t, false)
            mark(.note, detail: "quick commit (hold) \(item)")
            command(.commitSpeech)
        }
    }

    /// Tests (calm): the ear's room bed.
    var earBed: RoomBed { inner.withLock { $0.core.bed } }

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
            if duckOnOnset, !s.recentlyResolved.isEmpty || !s.playedOutDucks.isEmpty || !s.ownEndItems.isEmpty {
                let ttl = CalmTuning.recentlyResolvedTTL * 2
                s.recentlyResolved = s.recentlyResolved.filter { t - $0.value.at <= ttl }
                s.playedOutDucks = s.playedOutDucks.filter { t - $0.value <= ttl }
                s.ownEndItems = s.ownEndItems.filter { t - $0.value.at <= ttl }
            }
            if let sp = s.spec, t - sp.armedAt >= configuration.speculativeMax - 1e-9 {
                discardSpec(&s, at: t, byVoice: true, why: "timeout")
            }
            for (item, p) in s.wordsPartial where t - p.at >= Self.holdSettle - 1e-9 {
                // Settled words Dee never said: the user (Dee's own words wait for
                // the full transcript — more of them may yet come).
                guard let pending = s.wordsPending[item] else { s.wordsPartial[item] = nil; continue }
                guard !isHerEcho(item, p.text, strict: pending.strict, &s, at: t) else { continue }
                mark(.note, detail: "words of \(item): the user (settled)")
                wordsDecided(item, user: true, &s)
                // Tune 6: right after Dee went on, "I'm…" may be the rest of the
                // backchannel: its full words decide (`userTranscript`), not this.
                if s.graceItems.contains(item), Backchannel.mayBecomeBackchannel(p.text) { continue }
                holdForWords(item, text: p.text, partialAt: p.at, &s)
            }
            for (item, w) in s.wordsPending where t - w.since >= Self.wordsWait {
                mark(.note, detail: "no words for \(item): Dee's echo")
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
        // Tune 12: items that followed a continuer stay known after the hold (their full words).
        for item in h.items where !s.continuerTailItems.contains(item) && h.followsContinuer(item) {
            s.continuerTailItems.append(item)
            if s.continuerTailItems.count > 16 { s.continuerTailItems.removeFirst(s.continuerTailItems.count - 16) }
        }
        // Calm (§4.1): laugh tokens, sound tags and fillers count for items said in a short burst.
        if duckOnOnset {
            let tokens = Set(h.items.filter { !h.tails.contains($0) && (h.sounds[$0]?.voiced ?? 0) <= CalmTuning.tokenBurstMax + 1e-9 })
            if tokens != h.tokenItems {
                h.tokenItems = tokens
                s.hold?.tokenItems = tokens
            }
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
        if h.sustainIgnored, h.phase == .ducked, !h.goOnKnown {
            // Round 3 review (regress F2): the go-on no longer covers what they say (a new item,
            // words not "go on"): the ear's sustain test may pause Dee for it after all.
            h.sustainIgnored = false
            s.hold?.sustainIgnored = false
            s.core.rearmSustain()
            mark(.note, detail: "sustain re-armed \(h.itemID ?? "-")")
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
                && (s.core.lastUserBurst(since: min(h.since, h.duckSince ?? h.since) - Self.holdBurstLookback,
                                         gap: Self.holdCommitSilence).map {
                    $0.end - $0.start <= Self.holdQuickBurst + 1e-9 && $0.end > (h.commitAt ?? -.infinity)
                } ?? false)
            if stopped || quick {
                s.hold?.commitSent = true
                s.hold?.commitAt = t
                s.hold?.quickCommit = quick
                if quick { s.hold?.ownSplit.insert(item) }
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
        // An item still without words holds Dee unless its words are late (its
        // commit long past): the user may have said more than "go on" in it.
        let wordsLate = quiet && h.committed && (h.commitAt.map { t - $0 >= Self.holdWordsLate - 1e-9 } ?? false)
        let partialAnswers = !h.quickCommit || (h.lastDeltaAt.map { t - $0 >= Self.holdFinalWait - 1e-9 } ?? true)
        let verdict = h.verdict(settled: settled, quiet: wordsLate, partialAnswers: partialAnswers)
        if h.phase == .ducked {
            checkDuck(&s, h, verdict: verdict, settled: settled, quietNow: quietNow, uncovered: uncovered, at: t)
            return
        }
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
            // They meant it: the brain answers (`respond` ends Dee's reply where Dee
            // paused); if nobody does, `holdAfterWords` does — never while the
            // brain's go-on waits (tune 10, T9-1: the other deadlines still hold).
            if h.wordsAt == nil, !h.goOn || (duckOnOnset && h.answerAfterGoOn) { s.hold?.wordsAt = t }
        case .wait:
            break
        }
        guard let h = s.hold else { return }
        let wordsWaitHit = (h.speechStoppedAt ?? (h.committed ? h.commitAt : nil)).map { t - $0 >= Self.holdWordsWait - 1e-9 } ?? false
        let noItemHit = h.itemID == nil && !h.rescued && t - h.since >= Self.holdNoItem - 1e-9
        let afterWordsHit = h.wordsAt.map { t - $0 >= Self.holdAfterWords - 1e-9 } ?? false
        if t - h.since >= Self.holdMax - 1e-9 || wordsWaitHit || afterWordsHit || noItemHit {
            if duckOnOnset, h.why == "sustained", h.noWords, wordsWaitHit || noItemHit, !afterWordsHit, soundLike(h, s, at: t) {
                // Calm R5: paused for a sustained sound that never became words and was labelled
                // a laugh / cough (a long laugh, a coughing fit): Dee goes on instead of ending
                // the reply. Unlabelled, it may be a question whose words failed (review F3).
                resumeHold(&s, at: t, why: "nowords")
                return
            }
            mark(.note, detail: "hold ended by the voice \(h.itemID ?? "-")")
            cutReply(&s, announce: true)
        }
    }

    /// Calm: a ducked hold's escalations, releases and deadlines (spec R3 / R4). None of
    /// them cuts Dee's reply: it pauses Dee (`escalate`) or lets Dee go on (`unduck`).
    private func checkDuck(_ s: inout Inner, _ h: FloorHold, verdict: FloorHold.Verdict, settled: Bool,
                           quietNow: Bool, uncovered: Bool, at t: Double) {
        // (b) a stop or command word ("Wait,", "hold on", "Dee"), at its first delta — in a TV
        // room only with the item's own voice over the TV (the TV says "Wait!" too).
        if heardCommands(h, s, at: t).contains(where: { commandVoiced($0, h, s, at: t) }) {
            escalate(&s, why: "stopword")
            // Their words decide now, as in a pause (the reply ends no later than in 0.6.0).
            if verdict == .answer, !h.goOn, s.hold?.wordsAt == nil { s.hold?.wordsAt = t }
            return
        }
        if h.goOn, verdict != .answer, quietNow, !uncovered, !h.deferGoOn(talking: s.core.voiceActive(at: t)) {
            unduck(&s, at: t, why: "resume", event: "brain")
            return
        }
        switch verdict {
        case .resume:
            if quietNow, !uncovered {
                unduck(&s, at: t, why: "resume", event: "words")
                return
            }
        case .answer:
            // (c) words that are not "go on" — unless it is only the TV talking (§3.3).
            if ambientHold(h, s, at: t) {
                // Round 3 (live calm-ask-tv15 q03: «What?» | «time is it?» split by the quick
                // commit, all dropped as the TV while the rest was still being said): what looks
                // like the TV so far is judged once the utterance is all in — no item still being
                // said or waiting for its words — up to `duckMax`; Dee stays ducked meanwhile.
                if t - (h.duckSince ?? h.since) < CalmTuning.duckMax - 1e-9, h.tvPending(at: t, late: Self.holdWordsLate) { break }
                dropAmbient(&s, at: t)
                return
            }
            // Round 2: partial words that may still become a continuer ("I'm still" of "I'm still
            // listening.") wait for the full words while ducked — Dee keeps talking, ducked.
            let mayGoOn = h.items.contains { item in
                guard h.final[item] == nil, let p = h.partial[item]?.trimmingCharacters(in: .whitespaces), !p.isEmpty,
                      let end = p.last, !".!?".contains(end) else { return false }
                return Backchannel.mayBecomeBackchannel(p) && !Backchannel.isBackchannel(p)
            }
            // Round 3 review (correct F1): the brain's go-on covers only the items it saw; words
            // that are not "go on" in a later item escalate as without it.
            if !h.goOn || h.answerAfterGoOn, !mayGoOn {
                escalate(&s, why: "answer")
                if s.hold?.wordsAt == nil { s.hold?.wordsAt = t }
                return
            }
        case .wait:
            break
        }
        let since = h.duckSince ?? h.since
        if t - since >= CalmTuning.duckMax - 1e-9 {
            unduck(&s, at: t, why: "duckMax")
            return
        }
        if h.itemID == nil, t - since >= CalmTuning.duckNoItem - 1e-9 {
            unduck(&s, at: t, why: "noItem")
            return
        }
        // (Never while they talk on after it: what they say now is in no item yet.)
        if h.noWords, !h.sustained, quietNow, !uncovered, let c = h.speechStoppedAt ?? h.commitAt,
           t - c >= CalmTuning.duckWordsWait - 1e-9 {
            unduck(&s, at: t, why: "wordsWait")
            return
        }
        // A cough / sneeze / laugh / breath label over the burst, with two words at most.
        // Only once they are quiet (review F1): a cough or a laugh may start a real question.
        // Round 3 (live t2-backchannel-echo20 c03: released in the comma pause of "Wait, stop
        // talking for a second." — the stop word then came to no hold): never while the server
        // still has an item of the hold open (they are still saying it).
        if quietNow, !uncovered, !s.core.voiceActive(at: t), !h.hasOpenItem, s.core.serverOpen == nil,
           Backchannel.words(h.text).count <= CalmTuning.labelMaxTokens,
           s.core.bodySound(from: since - CalmTuning.sustainLookback, to: t) {
            unduck(&s, at: t, why: "label")
        }
    }

    /// Calm (§3.3): a ducked hold in a TV room that is only the TV: no sustained voice, no
    /// stop or command word, and no item with a voice of its own at the TV bar.
    private func ambientHold(_ h: FloorHold, _ s: Inner, at t: Double) -> Bool {
        guard h.phase == .ducked, h.tvRoom, !h.sustained,
              !heardCommands(h, s, at: t).contains(where: { commandVoiced($0, h, s, at: t) }) else { return false }
        for utterance in h.utterances {
            var voice = 0.0, span = 0.0, near = false
            for item in utterance {
                let until = min(t, h.closedAt[item] ?? t)
                if ownVoice(item, s, until: until) { return false }
                guard let v = s.core.itemSustain(itemID: item, until: until) else { continue }
                // Round 3: a question with near-field evidence is theirs (a false answer to the TV
                // rather than their question dropped).
                if (h.final[item] ?? h.partial[item])?.contains("?") == true, Self.nearField(v) { return false }
                if Self.nearField(v) { near = true }
                voice += v.voice
                span += v.span
            }
            // Round 3 (live calm-ask-tv15 q03, "What?" | "time is it?"): the items of one utterance
            // the quick commit split, together, with a voice of their own over the TV. Round 3
            // review (regress F1): only the items of one utterance we split (the TV's phrases the
            // server split, q01 | q07 at +2 dB, summed to 0.28 s and cut Dee), and only with
            // near-field evidence in it: summed voice alone does not tell a soft user from the TV
            // (q03 at its own level and the TV's q03 as loud as its loud parts, split the same way,
            // both pass the TV bar together).
            if utterance.count > 1, near, voice >= CalmTuning.itemSustain - 1e-9,
               voice >= CalmTuning.itemSustainShare * span - 1e-9 { return false }
        }
        return true
    }

    /// Round 3: near-field evidence in an item over the TV (`CalmTuning.commandPeakDB`): its
    /// loudest near-end frame far over the bed's ceiling, with some voice at the TV bar.
    static func nearField(_ v: (voice: Double, span: Double, peak: Double)) -> Bool {
        v.peak >= CalmTuning.commandPeakDB - 1e-9 && v.voice >= CalmTuning.commandPeakVoice - 1e-9
    }

    /// Calm (TV room): `item` has a voice of its own over the TV — at the TV bar, at least
    /// `CalmTuning.itemSustain` and `itemSustainShare` of its speech span.
    private func ownVoice(_ item: String, _ s: Inner, until t: Double) -> Bool {
        guard let v = s.core.itemSustain(itemID: item, until: t) else { return false }
        return v.voice >= CalmTuning.itemSustain - 1e-9 && v.voice >= CalmTuning.itemSustainShare * v.span - 1e-9
    }

    /// Calm round 2 review (correct F2): the hold's items whose stop / command words are the
    /// user's. With no echo cancellation the server often puts Dee's echo and the user's sound
    /// in one item (live t2 echo10 c02: «That sounds like a classic. Don't stop.»): a command
    /// word whose clause is only Dee's own recent words (`HerWords.isHerEcho`: Dee's "Wait till
    /// you hear how it ends", then their "Mm-hm.") counts for nothing — as for an item left to
    /// its words (`commandAtFirstDelta`) or a rejected one (`rejectedCommand`). With echo
    /// cancellation the item is the user's sound (the ear's near-end evidence ducked Dee).
    private func heardCommands(_ h: FloorHold, _ s: Inner, at t: Double) -> [String] {
        let items = h.commandItems(names: s.names)
        guard !s.core.aecActive, !items.isEmpty else { return items }
        return items.filter { item in
            let final = h.final[item] != nil
            let text = h.final[item] ?? h.partial[item] ?? ""
            let open = !final && !(text.last.map { ",.!?;:…—".contains($0) } ?? true)
            let clauses = text.split(whereSeparator: { ",.!?;:…—".contains($0) }).map(String.init)
            let commanding = clauses.indices.filter { i in
                CalmTuning.hasCommandWord(clauses[i], names: s.names, partial: open && i == clauses.count - 1)
            }
            guard !commanding.isEmpty else { return true }
            return commanding.contains { !s.herWords.isHerEcho(clauses[$0], at: t, strict: false, asks: false) }
        }
    }

    /// Calm round 2: a stop / command word in `item` counts — always outside a TV room; in
    /// one, only with `CalmTuning.commandVoice` of the item's own voice at the TV bar.
    private func commandVoiced(_ item: String, _ h: FloorHold, _ s: Inner, at t: Double) -> Bool {
        guard h.tvRoom else { return true }
        guard let v = s.core.itemSustain(itemID: item, until: min(t, h.closedAt[item] ?? t)) else { return false }
        // Round 3 (live calm-ask-tv15 c03): or near-field evidence — the user's short "Wait."
        // the quick commit split off has 0.16 s at the TV bar, its peak far over the TV's.
        return v.voice >= CalmTuning.commandVoice - 1e-9 || Self.nearField(v)
    }

    /// Calm round 2 (TV room): `text`, said in `item`, has no voice of its own over the TV —
    /// a stop word / Dee's name without `CalmTuning.commandVoice` at the TV bar, other words
    /// without `ownVoice`.
    private func tvWords(_ item: String, _ text: String, _ s: Inner, at t: Double) -> Bool {
        let v = s.core.itemSustain(itemID: item, until: t)
        let command = CalmTuning.hasCommandWord(text, names: s.names)
        // Round 3: a stop word, a name or a question with near-field evidence is theirs.
        if command || text.contains("?"), let v, Self.nearField(v) { return false }
        if command { return (v?.voice ?? 0) < CalmTuning.commandVoice - 1e-9 }
        return !ownVoice(item, s, until: t)
    }

    /// Calm round 2: one item is the TV (no hold): out of the conversation, never answered.
    private func dropAmbient(_ item: String, _ s: inout Inner, at t: Double) {
        mark(.note, detail: "ambient \(item) reason=tvItemSustain")
        if !s.ambientItems.contains(item) { s.ambientItems.append(item) }
        if s.ambientItems.count > 32 { s.ambientItems.removeFirst(s.ambientItems.count - 32) }
        if !s.tailDrops.contains(item) { s.tailDrops.append(item) }
        flushTailDrops(&s, at: t)
    }

    /// Calm: the hold's items are the TV: out of the conversation (dropped once no reply
    /// can be cancelled by it, as empty tails are), never answered; Dee goes on.
    private func dropAmbient(_ s: inout Inner, at t: Double) {
        guard let h = s.hold else { return }
        for item in h.items {
            mark(.note, detail: "ambient \(item) reason=tvItemSustain")
            if !s.ambientItems.contains(item) { s.ambientItems.append(item) }
            if !s.tailDrops.contains(item) { s.tailDrops.append(item) }
        }
        if s.ambientItems.count > 32 { s.ambientItems.removeFirst(s.ambientItems.count - 32) }
        unduck(&s, at: t, why: "ambient")
        flushTailDrops(&s, at: t)
    }

    /// Calm: a ducked hold becomes a pause (spec R3): Dee is silent now (5 ms fade from the
    /// duck gain), the deadlines of a pause count from now, and the ear knows the user cut
    /// this stretch. Every side effect of a 0.6.0 pause.
    private func escalate(_ s: inout Inner, why: String) {
        guard let h = s.hold, !h.probe, h.phase == .ducked else { return }
        graph.player.hold()
        s.hold?.phase = .paused
        s.hold?.since = graph.now
        s.hold?.why = why
        if why == "sustained" { s.hold?.sustained = true }
        s.core.escalated()
        mark(.note, detail: "hold \(h.itemID ?? "-") why=\(why)")
        holdContinuation.yield(.paused(itemID: h.itemID))
    }

    /// Calm: Dee back to full level (spec R4): the duck's sound decided nothing that stops
    /// Dee. `resumeHold`'s shared tail, with its echo-prone check, but no `resumeGrace`
    /// (that stays tied to a resume from a pause). `why`: resume, wordsWait, noItem,
    /// duckMax, ambient, label. `event`: the `HoldEvent.resumed` reason for the brain (as a
    /// resume's: "words", "brain", "echo"; "duck-<why>" when only the duck decided).
    private func unduck(_ s: inout Inner, at t: Double, why: String, event: String? = nil) {
        guard let h = s.hold, !h.probe, h.phase == .ducked else { return }
        s.hold = nil
        if h.commitSent, s.burstCommit != nil { s.burstCommit?.resumed = true } else { s.burstCommit = nil }
        graph.player.unduck()
        s.core.unducked(at: t)
        mark(.note, detail: "unduck \(h.itemID ?? "-") (\(why))")
        if why != "ambient" {
            if echoProne(h, s) {
                mark(.note, detail: "no grace: echo-prone \(h.items.joined(separator: ","))")
                s.lastResumeAt = nil
            }
            s.backchannelItems.append(contentsOf: h.items)
            if s.backchannelItems.count > 32 { s.backchannelItems.removeFirst(s.backchannelItems.count - 32) }
        }
        resolved(h, wordless: why != "ambient" && h.noWords, &s, at: t)
        holdContinuation.yield(.resumed(itemIDs: h.items, text: h.text, why: event ?? "duck-\(why)"))
    }

    /// Calm: the hold's items are decided (`holdClaims`).
    private func resolved(_ h: FloorHold, wordless: Bool, _ s: inout Inner, at t: Double) {
        guard duckOnOnset else { return }
        for item in h.items { s.recentlyResolved[item] = (t, wordless, h.tvRoom) }
    }

    /// Calm round 2: an item left to its words over Dee (`deferToWords`) whose first deltas
    /// hold a stop word or Dee's name that Dee's own words don't explain is the user's now —
    /// Dee pauses at once (`holdForWords`), without waiting for the words to settle.
    private func commandAtFirstDelta(_ item: String, _ s: inout Inner, at t: Double) {
        guard let pending = s.wordsPending[item], let p = s.wordsPartial[item],
              CalmTuning.hasCommandWord(p.text, names: s.names, partial: true),
              !isHerEcho(item, p.text, strict: pending.strict, &s, at: t) else { return }
        mark(.note, detail: "words of \(item): the user (stop word)")
        wordsDecided(item, user: true, &s)
        holdForWords(item, text: p.text, partialAt: p.at, why: "stopword", &s)
    }

    /// Calm round 2 (live t2-backchannel-echo10 c03): a stop word in the deltas of an item
    /// already rejected as Dee's echo — the echo model or the words judged it before the
    /// stop word came — still pauses Dee when Dee's own recent words don't hold that word,
    /// and it is a strong stop (`CalmTuning.isStrongStop`: "Stop talking…", "Wait.") or the
    /// user's own voice was heard over Dee just now (`rejectedStopVoice` in the last
    /// `rejectedStopWindow`). In a TV room, never (the TV says "Stop!" too).
    private func rejectedCommand(_ item: String, delta: String, _ s: inout Inner, at t: Double) {
        let text = (s.rejectedPartial[item] ?? "") + delta
        s.rejectedPartial[item] = text
        if s.rejectedPartial.count > 16, let old = s.rejectedPartial.keys.first(where: { $0 != item }) { s.rejectedPartial[old] = nil }
        guard s.sessionPlaying, herVoiceQueued(s), !s.core.tvRoom, s.hold?.phase != .paused,
              CalmTuning.hasCommandWord(text, names: s.names, partial: true),
              !s.herWords.isHerEcho(text, at: t, strict: false, asks: false),
              CalmTuning.isStrongStop(text, names: s.names)
                || s.core.recentNearVoice(within: CalmTuning.rejectedStopWindow, at: t) >= CalmTuning.rejectedStopVoice - 1e-9
        else { return }
        s.rejectedPartial[item] = nil
        mark(.note, detail: "stop word in rejected \(item)")
        if s.hold?.phase == .ducked, s.hold?.probe != true {
            escalate(&s, why: "stopword")
            s.hold?.rescueItem = item
        } else if s.hold == nil {
            graph.player.hold()
            var h = FloorHold(itemID: nil, since: graph.now)
            h.why = "stopword"
            h.rescueItem = item
            s.hold = h
            mark(.note, detail: "hold - why=stopword")
            holdContinuation.yield(.paused(itemID: nil))
        }
    }

    /// Calm round 2 review (correct F3): the full words of a rejected item whose stop word
    /// paused Dee (`rejectedCommand`). Only a stop ("Stop talking for a second.") leaves the
    /// hold to end the reply (`holdNoItem`), as before; words that say more ("Wait, what did
    /// you say about the moon?") are the user's turn — the item itself is out of the
    /// conversation, so the brain answers the words (`HoldEvent.rescued`), and the hold waits
    /// for that answer like any hold whose words answer (`holdAfterWords`).
    private func rescue(_ item: String, _ text: String, _ s: inout Inner, at t: Double) {
        guard let h = s.hold, !h.probe, h.rescueItem == item, !h.rescued, h.phase == .paused else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !CalmTuning.isOnlyCommand(clean, names: s.names), !Backchannel.isBackchannel(clean) else { return }
        s.hold?.rescued = true
        if s.hold?.wordsAt == nil { s.hold?.wordsAt = t }
        mark(.note, detail: "rescued words of \(item)")
        holdContinuation.yield(.rescued(itemID: item, text: clean))
    }

    // MARK: Wiring

    /// Tests: a classifier result now, as the sound analyser would report it.
    func classifiedForTesting(_ results: [(identifier: String, confidence: Double)], window: ClosedRange<Double>?) {
        let t = graph.now
        inner.withLock { s in apply(s.core.classified(results, window: window, at: t), &s) }
    }

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
            guard s.started, !s.shutDown, !s.connectLoopRunning, !s.needsSetup, s.awake else { return false }
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
        var stale = false
        defer {
            let again = inner.withLock { s -> Bool in
                s.connectLoopRunning = false
                return stale && s.awake && !s.needsSetup && !s.shutDown
            }
            // A wake that came while this loop (of an older window) was unwinding.
            if again { startConnecting() }
        }
        var attempt = 0
        var closedRetried = false
        while !Task.isCancelled {
            let (go, resume, generation) = inner.withLock { s in
                (!s.shutDown && !s.needsSetup && s.awake, s.wakeResume, s.linkGeneration)
            }
            guard go else { return }
            var wait: Double?
            do {
                if generation > 0 {
                    // A window opened by `wake`: resumed (seeded) per `wakeResume`.
                    try await session.connect(resume: resume)
                } else {
                    try await session.connect()
                }
                if inner.withLock({ $0.linkGeneration != generation }) { stale = true }
                return
            } catch let e as RealtimeSessionError {
                if inner.withLock({ $0.linkGeneration != generation }) { stale = true; return }
                switch e {
                case .noKey:
                    setProblem(.cloudVoiceNeedsSetup(configuration.provider.isOpenAI
                        ? "No OpenAI key." : "No key for \(configuration.provider.spokenName)."), setup: true)
                    return
                case .unauthorized(let m):
                    setProblem(.cloudVoiceNeedsSetup(Self.refusedKey(configuration.provider, m)), setup: true)
                    return
                case .closed:
                    // An older window's `sleep` closed the session while this window's
                    // link was opening (sleep then wake while connecting): once, again.
                    if !closedRetried, inner.withLock({ $0.awake && !$0.shutDown }) {
                        closedRetried = true
                        continue
                    }
                    return
                case .rateLimited(let after):
                    wait = after
                    setProblem(.cloudVoiceUnavailable("Rate limited."), setup: false)
                default:
                    setProblem(.cloudVoiceUnavailable(Self.unreachable(configuration.provider, Self.describe(e))), setup: false)
                }
            } catch {
                if inner.withLock({ $0.linkGeneration != generation }) { stale = true; return }
                setProblem(.cloudVoiceUnavailable(Self.unreachable(configuration.provider, "\(error)")), setup: false)
            }
            let delays = configuration.connectRetryDelays.isEmpty ? [5.0] : configuration.connectRetryDelays
            let delay = max(wait ?? 0, delays[min(attempt, delays.count - 1)])
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// "The OpenAI key was refused…" / "The AI server at HOST refused the key…".
    static func refusedKey(_ p: ProviderLabel, _ m: String?) -> String {
        let tail = m.map { ": \($0)" } ?? "."
        return p.isOpenAI ? "The OpenAI key was refused\(tail)" : "\(p.spokenName.prefix(1).uppercased() + p.spokenName.dropFirst()) refused the key\(tail)"
    }

    /// Mode 1 keeps v0.5's detail text; a LAN server is named ("I can't reach the AI server at HOST").
    static func unreachable(_ p: ProviderLabel, _ detail: String) -> String {
        p.isOpenAI ? detail : "Can't reach \(p.spokenName): \(detail)"
    }

    private func setProblem(_ p: VoiceProblem?, setup: Bool?) {
        inner.withLock { s in
            if let setup { s.needsSetup = setup }
            guard s.problem != p else { return }
            s.problem = p
            brain.yield(.connection(p))
            if let p, s.awake, s.linkGeneration > 0 { awakeContinuation.yield(.failed(p)) }
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
            // Dee's words, as they are generated: an item Dee's echo opened is judged by them.
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
                if s.linkGeneration > 0, s.awake, !s.awakeAnnounced {
                    s.awakeAnnounced = true
                    awakeContinuation.yield(.awake)
                    if configuration.prepareClipsOnWake, !s.clipsPrepared, let clips {
                        s.clipsPrepared = true
                        Task { await clips.prepare() }
                    }
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
                } else if let h = s.hold, h.phase == .ducked {
                    // Calm: what was received still plays (full level); nothing to end.
                    s.hold = nil
                    graph.player.unduck()
                    mark(.note, detail: "unduck \(h.itemID ?? "-") (resume)")
                } else if s.hold != nil {
                    // Nothing more comes for Dee's reply: it ends where Dee paused.
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
                if state == .idle, s.started, !s.shutDown, !s.needsSetup, s.awake {
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
                    // More of what they say over Dee: it decides the hold too.
                    s.hold?.add(item)
                    s.hold?.starts[item] = onset ?? t
                }
                if s.heldStarts[item] == nil, !s.rejected.contains(item) {
                    // Not held: it is the user (for instance just after a clip Dee
                    // gave way with, whose echo window is still open). The session
                    // may still count it as possibly Dee's echo: say it is not.
                    command(.acceptSpeech(item))
                }
            case .userSpeechStopped(let item, let ms):
                let end = s.map.captureFrame(serverMs: ms).map { graph.capture.hostTime(ofFrame: $0) }
                noteTail(item, end: end, at: t, &s)
                apply(s.core.serverSpeechStopped(itemID: item, end: end, at: t), &s)
                if s.hold?.itemID == item { s.hold?.speechStoppedAt = t }
                if s.hold?.items.contains(item) == true { s.hold?.ends[item] = end ?? t }
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
                    // Calm round 2: a stop word or Dee's name pauses a ducked Dee at its first
                    // delta (live "Stop." / "Wait." went silent only at +1.16–1.26 s, settled).
                    if duckOnOnset, s.hold?.phase == .ducked,
                       CalmTuning.hasCommandWord(s.hold?.partial[item] ?? "", names: s.names, partial: true) { checkHold(&s, at: t) }
                }
                if s.wordsPending[item] != nil {
                    s.wordsPending[item]?.events.append(e)
                    s.wordsPartial[item] = ((s.wordsPartial[item]?.text ?? "") + delta, t)
                    forward = false
                    if duckOnOnset { commandAtFirstDelta(item, &s, at: t) }
                } else if s.rejected.contains(item) {
                    forward = false
                    if duckOnOnset { rejectedCommand(item, delta: delta, &s, at: t) }
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
                    mark(.note, detail: "words of \(item): \(user ? "the user" : "Dee's echo")")
                    wordsDecided(item, user: user, &s)
                    if user { holdForWords(item, text: text, partialAt: nil, &s) }
                }
                if duckOnOnset, s.hold == nil, let r = s.recentlyResolved[item], r.wordless,
                   t - r.at <= CalmTuning.recentlyResolvedTTL + 1e-9, !s.rejected.contains(item) {
                    // Calm (R4): the duck went (no words in time); their late words still stop
                    // Dee unless they say "go on" (`holdForWords`, as for any words over Dee).
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty, !Backchannel.isBackchannel(clean),
                       !Backchannel.isHoldSoundToken(clean, sound: sound(item, s, at: t)) {
                        s.recentlyResolved[item] = nil
                        holdForWords(item, text: clean, partialAt: nil, &s)
                    }
                }
                if let i = s.graceItems.firstIndex(of: item), s.wordsPending[item] == nil {
                    // Tune 6: an onset Dee talked on through (`resumeGrace`), decided the user's.
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
                    if duckOnOnset { rescue(item, text, &s, at: t) }
                } else {
                    mark(.transcript, detail: item)
                    apply(s.core.serverTranscript(itemID: item, text: text, at: t), &s)
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if empty, s.ownEndItems[item] != nil { s.ownEndItems[item]?.empty = true }
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
                if s.ownEndItems[item] != nil { s.ownEndItems[item]?.failed = true }
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
                if let (p, setup) = Self.problem(for: reason, provider: configuration.provider) {
                    if let setup { s.needsSetup = setup }
                    if s.problem != p {
                        s.problem = p
                        brain.yield(.connection(p))
                        if s.awake, s.linkGeneration > 0 { awakeContinuation.yield(.failed(p)) }
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

    /// The problem a fallback reason means, worded for `provider` (OpenAI: v0.5's texts).
    static func problem(for reason: FallbackReason, provider: ProviderLabel) -> (VoiceProblem, Bool?)? {
        guard !provider.isOpenAI else { return problem(for: reason) }
        let name = provider.spokenName
        switch reason {
        case .noKey: return (.cloudVoiceNeedsSetup("No key for \(name)."), true)
        case .unauthorized: return (.cloudVoiceNeedsSetup(refusedKey(provider, nil)), true)
        case .quotaExceeded, .rateLimited: return (.cloudVoiceUnavailable("\(name) is busy."), nil)
        case .socketLost(_, let d): return (.cloudVoiceUnavailable("Lost \(name)\(d.map { ": \($0)" } ?? ".")"), nil)
        case .connectFailed(let d): return (.cloudVoiceUnavailable("Can't reach \(name): \(d)"), nil)
        case .serverError(let d): return (.cloudVoiceUnavailable("\(name) failed\(d.map { ": \($0)" } ?? ".")"), nil)
        case .noResponse, .congested: return nil
        }
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
                let clip = s.clips[u] != nil || s.cues.contains(u)
                apply(s.core.playbackStarted(at: t, aside: clip), &s)
                if !clip {
                    for ev in s.sentences.itemStarted(u) { brain.yield(Self.brainEvent(ev)) }
                }
            case .level(let l):
                s.core.playbackLevel(l, at: t)
            case .underrun(let u):
                mark(.note, detail: "underrun \(u)")
            case .finished(let u, let ms, let flushed):
                if s.cues.remove(u) != nil {
                    // A listening cue: nothing for the brain or the session.
                } else if let clip = s.clips.removeValue(forKey: u) {
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
                        // The session learns Dee stopped once Dee's echo has left the room.
                        s.finishDueAt = t + s.core.outputLatency + EarCore.echoTail
                    }
                }
                if !graph.player.isBusy {
                    apply(s.core.playbackFinished(at: t), &s)
                    if let h = s.hold, !h.probe, h.phase == .ducked {
                        // Calm: Dee's reply played out under the duck — nothing is left to give
                        // way; their words are an ordinary turn (`duckPlayedOut`: no carry-on).
                        s.hold = nil
                        graph.player.unduck()
                        for item in h.items { s.playedOutDucks[item] = t }
                        mark(.note, detail: "unduck \(h.itemID ?? "-") (resume)")
                    }
                }
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
            // A phone call / Siri / services reset stopped Dee's output: the server
            // must hear what of Dee's reply was played (not a barge-in: no event),
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
        // Dee's output rendered up to now: the echo reference for these frames.
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
        let chunks: AsyncStream<PCM16Capture.Chunk>
        if let wakeFrom = s.wakeFrom {
            // The first uplink of a window: from the wake onset − 0.3 s, never earlier
            // (no speech from before the phrase leaves the phone), never the gap since
            // the last window.
            s.wakeFrom = nil
            chunks = capture.open(from: wakeFrom, maxPreroll: PCM16Capture.ringSeconds)
        } else {
            let from = s.map.captureEnd ?? max(0, capture.capturedFrames - Int64(configuration.prerollSeconds * PCM16Capture.sampleRate))
            chunks = capture.open(from: from, maxPreroll: configuration.prerollSeconds)
        }
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
                configuration.uplinkActivity?.record(frames: chunk.frames - skip, voice: s.core.voiceActive(at: graph.now))
                return true
            }
            s.map.sent(startFrame: chunk.startFrame, frames: chunk.frames)
            session.feedAudio(s.uplinkGate.process(chunk.data, startFrame: chunk.startFrame))
            configuration.uplinkActivity?.record(frames: chunk.frames, voice: s.core.voiceActive(at: graph.now))
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
                // one Dee talks on through (`resumeGrace`) is no barge-in at all.
                if e == .bargeIn, s.hold != nil || talkOn { continue }
                voice(e, &s)
            case .bargeIn(let item?) where configuration.holdOnBargeIn && s.sessionPlaying && s.lastSessionItem != nil
                    && s.hold == nil && herVoiceQueued(s)
                    && s.lastResumeAt.map({ graph.now - $0 <= Self.resumeGrace + 1e-9 }) == true:
                // Tune 6: just after Dee went on from "Keep going.", the rest of it
                // ("I'm listening.") starts: Dee talks on; its words decide.
                talkOn = true
                let now = graph.now
                apply(s.core.playbackResumed(at: now), &s)      // not a cut stretch: later onsets are decided afresh
                if s.wordsPending[item] == nil { s.wordsPending[item] = (now, [], false) }
                s.graceItems.append(item)
                if s.graceItems.count > 16 { s.graceItems.removeFirst(s.graceItems.count - 16) }
                mark(.note, detail: "after resume: words decide \(item)")
            case .bargeIn(let item) where s.hold?.probe == true:
                // Their voice in Dee's silence: the probe was them. A hold since the pause.
                confirmProbe(item, &s)
                if let item { accept(item, &s) }
            case .bargeIn(let item) where duckOnOnset && s.hold != nil:
                // Calm: the local-only run under a duck (R3 e) pauses Dee; it joins the hold.
                if s.hold?.phase == .ducked { escalate(&s, why: item == nil ? "localOnly" : "legacy") }
                if let item {
                    s.hold?.add(item)
                    accept(item, &s)
                }
            case .bargeIn(let item):
                if configuration.holdOnBargeIn, s.sessionPlaying, s.lastSessionItem != nil, s.hold == nil, herVoiceQueued(s) {
                    // Silent at once; whether Dee's reply ends here their words decide.
                    graph.player.hold()
                    var h = FloorHold(itemID: item, since: graph.now)
                    let why = duckOnOnset ? "localOnly" : "legacy"
                    h.why = why
                    s.hold = h
                    mark(.note, detail: "hold \(item ?? "-") why=\(why)")
                    holdContinuation.yield(.paused(itemID: item))
                } else {
                    cutReply(&s)
                }
                if let item { accept(item, &s) }
            case .duck(let item, let via):
                applyDuck(item, via: via, &s)
            case .sustained(let item, let all, let pitched):
                mark(.note, detail: "sustained \(item ?? "-") all=\(Self.secs(all)) pitched=\(Self.secs(pitched))")
                guard let h = s.hold, !h.probe else { break }
                if h.phase == .ducked, h.goOnKnown {
                    // Round 3 (live t2-backchannel-echo20 c02: «Don't stop.», go-on deferred ×3,
                    // then 1.20 s of voice paused Dee and the hold cut the reply): their words said
                    // go on; what more they say decides by its words.
                    mark(.note, detail: "sustained ignored: go-on \(h.itemID ?? "-")")
                    // Round 3 review (regress F2): armed again for something new (`checkHold`).
                    s.hold?.sustainIgnored = true
                    break
                }
                s.hold?.sustained = true
                if h.phase == .ducked { escalate(&s, why: "sustained") }
            case .yieldAside(let item):
                if s.sessionPlaying || !s.sessionItems.isEmpty {
                    // Dee's reply was queued behind the aside: the user is talking, it goes too.
                    cutReply(&s)
                } else {
                    graph.player.flush()
                }
                if let item { accept(item, &s) }
            case .acceptOnset(let item):
                if duckOnOnset, let h = s.hold, !h.probe, h.phase == .ducked, !h.items.contains(item),
                   s.heldStarts[item] != nil {
                    // Calm (review F1): a new item under the duck, judged the user's (not Dee's
                    // echo): more of what they say over Dee, so it decides the hold too.
                    s.hold?.add(item)
                    s.hold?.starts[item] = s.core.itemOnset(item) ?? graph.now
                }
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
                // Tune 7 (T6-4): pause Dee and listen. Not right after Dee went on from
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
                // Nobody spoke into Dee's silence: Dee goes on from exactly there.
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
        // Dee's next item never starts while an onset over Dee is being decided: if
        // it is the user, Dee would begin a new sentence over them. Calm (R6): not while
        // ducked — Dee's next sentence starts at the duck gain.
        let boundary = s.sessionPlaying && s.core.deciding && s.core.pendingMayBeUser(at: graph.now)
            && s.hold?.phase != .ducked
        if graph.player.holdAtBoundary != boundary { graph.player.holdAtBoundary = boundary }
    }

    /// Calm (R1 / R2): onset evidence over Dee's reply ducks Dee — a `FloorHold` in phase
    /// `.ducked`; Dee keeps talking at `CalmTuning.duckGainDB` (−6 dB in a TV room). A duck
    /// that comes while a hold exists joins it; one right after Dee went on from a
    /// backchannel (`resumeGrace`) talks on, as a barge-in there does.
    private func applyDuck(_ item: String?, via: String, _ s: inout Inner) {
        let now = graph.now
        if s.hold?.probe == true {
            // Their voice in Dee's silence (a probe): Dee is quiet already — a hold since the pause.
            s.core.escalated()
            confirmProbe(item, &s)
            if let item { accept(item, &s) }
        } else if s.hold != nil {
            // A paused hold (their words paused Dee): the ear's duck is that pause.
            if s.hold?.phase != .ducked { s.core.escalated() }
            if let item {
                s.hold?.add(item)
                accept(item, &s)
            }
        } else if configuration.holdOnBargeIn, s.sessionPlaying, s.lastSessionItem != nil, herVoiceQueued(s) {
            if let item, s.lastResumeAt.map({ now - $0 <= Self.resumeGrace + 1e-9 }) == true {
                // Tune 6: just after Dee went on from "Keep going.": Dee talks on; its words decide.
                apply(s.core.playbackResumed(at: now), &s)
                if s.wordsPending[item] == nil { s.wordsPending[item] = (now, [], false) }
                s.graceItems.append(item)
                if s.graceItems.count > 16 { s.graceItems.removeFirst(s.graceItems.count - 16) }
                mark(.note, detail: "after resume: words decide \(item)")
                return
            }
            let tv = s.core.tvRoom
            let gain = tv ? CalmTuning.duckGainTVDB : CalmTuning.duckGainDB
            graph.player.duck(gainDB: gain)
            var h = FloorHold(itemID: item, since: now)
            h.phase = .ducked
            h.duckSince = now
            h.tvRoom = tv
            if let item, s.backchannelItems.contains(item) || s.recentlyResolved[item] != nil {
                // Round 3 (live t2-backchannel-echo20 c03): an item a duck was released for while
                // they still said it (the local-only run of its rest) is this hold's again — not a
                // backchannel Dee went on through; its words decide.
                s.backchannelItems.removeAll { $0 == item }
                s.recentlyResolved[item] = nil
                h.starts[item] = s.core.itemOnset(item)
            }
            s.hold = h
            mark(.note, detail: "duck \(item ?? "-") gain=\(Int(gain.rounded())) via=\(via)")
            if let item { accept(item, &s) }
        } else {
            // Nothing of a reply to give way with (as a barge-in there): cut at once.
            s.core.escalated()
            cutReply(&s)
            voice(.bargeIn, &s)
            if let item { accept(item, &s) }
        }
    }

    static func secs(_ v: Double) -> String { String(format: "%.2f", v) }

    /// The words of `item`, an item left to its words (`deferToWords`), are only Dee's echo.
    ///
    /// Tune 11 (T10-2b / T10-3): one word over Dee's voice with no echo cancellation is
    /// judged by Dee's echo model, not by which word came back (one word can never reach the
    /// two- or three-new-word bar, and any word can be a mishearing either way): the item's
    /// sound Dee's playback explains is Dee's echo, whatever its word (live echo10 bc01: Dee's
    /// echo came back as "Sorry." and stopped Dee); a voice in it Dee's echo can't be is the
    /// user's, whatever its word (live echo10 c01: "Stop." came back as "Doc." and was
    /// deleted as Dee's echo while Dee talked on).
    /// One word a person says alone to stop, call or ask Dee (not "sorry": T10-2b's echo).
    static let stopsHerAlone: Set<String> = ["stop", "wait", "no", "hey", "hello", "what"]

    private func isHerEcho(_ item: String, _ text: String, strict: Bool, _ s: inout Inner, at t: Double) -> Bool {
        // Tune 11 review: never deleted on sound alone when the word stops Dee ("Stop.",
        // offline l01 1.5 s in measured "explained"): the words decide it, as at 89d0c0f.
        let one = HerWords.words(text)
        if one.count == 1, s.echoExposedItems.contains(item),
           let explained = s.core.echoExplains(itemID: item, at: t),
           !(explained && Self.stopsHerAlone.contains(one[0])) {
            if !explained, !s.voiceOverEchoItems.contains(item) {
                s.voiceOverEchoItems.append(item)
                if s.voiceOverEchoItems.count > 16 { s.voiceOverEchoItems.removeFirst(s.voiceOverEchoItems.count - 16) }
                mark(.note, detail: "one word of \(item): a voice Dee's echo can't be")
            }
            return explained
        }
        return s.herWords.isHerEcho(text, at: t, strict: strict, asks: sound(item, s, at: t)?.questionLike == true)
    }

    /// An item's words decided it: the user's (the brain gets everything held
    /// back, in order) or Dee's echo (deleted; the brain never sees it).
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

    /// The words over Dee's voice said "go on" (or the onset was Dee's echo after
    /// all): Dee goes on from exactly where Dee paused.
    private func resumeHold(_ s: inout Inner, at t: Double, why: String) {
        guard let h = s.hold else { return }
        if h.phase == .ducked, !h.probe {
            // Calm: Dee never paused — the duck is released instead.
            unduck(&s, at: t, why: "resume", event: why)
            return
        }
        s.hold = nil
        resolved(h, wordless: h.noWords, &s, at: t)
        if h.commitSent, s.burstCommit != nil { s.burstCommit?.resumed = true } else { s.burstCommit = nil }
        graph.player.resume()
        apply(s.core.playbackResumed(at: t), &s)
        mark(.note, detail: "resumed \(h.itemID ?? "-") (\(why))")
        if why != "echo" {
            if echoProne(h, s) {
                // Tune 8 (T7-3): likely Dee's own echo ("Yeah." 0.26 s into Dee's reply, AEC
                // off): no grace — the next onset over Dee pauses Dee on its sound.
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

    /// Tune 8 (T7-3): the hold is likely Dee's own echo — every item of it began early
    /// in Dee's stretch with no echo cancellation (`echoOnsetWindow`), and all its words
    /// are at most one word (fillers aside). "Keep going." (two words) never is.
    private func echoProne(_ h: FloorHold, _ s: Inner) -> Bool {
        let items = h.items.filter { !h.tails.contains($0) }
        guard !items.isEmpty, items.allSatisfy(s.echoProneItems.contains) else { return false }
        let text = items.map { h.final[$0] ?? h.partial[$0] ?? "" }.joined(separator: " ")
        return Backchannel.words(text).filter { !Backchannel.fillers.contains($0) }.count <= 1
    }

    /// A server item that is only the tail of the burst we just committed
    /// (`holdTailMax`): it joins the hold (deciding nothing without words), or —
    /// Dee already went on — it is a backchannel too. Never a turn: the brain
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

    /// Words Dee never said, over Dee's voice (an item Dee's echo opened): unless
    /// they say "go on", Dee goes quiet now and the brain answers them (which
    /// ends Dee's reply where Dee paused).
    private func holdForWords(_ item: String, text: String, partialAt: Double?, why: String = "answer", _ s: inout Inner) {
        if s.hold?.probe == true, s.sessionPlaying, !Backchannel.isBackchannel(text) {
            // Words Dee never said, while a probe has Dee paused: it is a hold since then.
            confirmProbe(item, &s)
            s.core.probeConfirmed()
            if let partialAt {
                s.hold?.partial[item] = text
                s.hold?.lastDeltaAt = partialAt
            }
            return
        }
        if duckOnOnset, let h = s.hold, !h.probe, h.phase == .ducked, s.sessionPlaying, !h.items.contains(item),
           !Backchannel.isBackchannel(text) {
            // Calm round 2: Dee is ducked for another of their items; these words (an item left
            // to its words, now theirs: "Mm, … what about the moon?") join that hold and decide
            // it with it — its verdict pauses Dee for words that aren't "go on".
            if s.core.tvRoom, tvWords(item, text, s, at: graph.now) {
                dropAmbient(item, &s, at: graph.now)
                return
            }
            s.hold?.add(item)
            s.hold?.starts[item] = s.core.itemOnset(item) ?? graph.now
            if let partialAt {
                s.hold?.partial[item] = text
                s.hold?.lastDeltaAt = partialAt
            } else {
                s.hold?.final[item] = text
            }
            if why == "stopword" { escalate(&s, why: why) } else { checkHold(&s, at: graph.now) }
            return
        }
        guard s.sessionPlaying, herVoiceQueued(s), s.hold == nil, !Backchannel.isBackchannel(text) else { return }
        if duckOnOnset, s.core.tvRoom, tvWords(item, text, s, at: graph.now) {
            // Calm round 2: words over Dee in a TV room with no voice of their own over the TV
            // (an item left to its words, or late words after the duck went): the TV's.
            dropAmbient(item, &s, at: graph.now)
            return
        }
        graph.player.hold()
        var h = FloorHold(itemID: item, since: graph.now)
        if let partialAt {
            h.partial[item] = text
            h.lastDeltaAt = partialAt
        }
        h.why = duckOnOnset ? why : "legacy"
        s.hold = h
        mark(.note, detail: "hold \(item) (words) why=\(h.why ?? "legacy")")
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

    /// Tune 7: the probe was the user (their voice in Dee's silence, or their words):
    /// a hold from when Dee paused, announced to the brain now.
    private func confirmProbe(_ item: String?, _ s: inout Inner) {
        guard s.hold?.probe == true else { return }
        s.hold?.probe = false
        if let item { s.hold?.add(item) }
        mark(.note, detail: "probe confirmed \(item ?? "-")")
        holdContinuation.yield(.paused(itemID: item))
    }

    /// A hold ended as a real barge-in: marked when Dee paused (Dee was silent
    /// from then on); announced (`.bargeIn`) only when `announce`.
    private func releaseHold(_ s: inout Inner, announce: Bool) {
        guard let h = s.hold else { return }
        s.hold = nil
        if h.probe { return }                      // nothing was announced: nothing ends
        timeline.mark(.bargeIn, at: h.since, detail: h.itemID)
        if announce { continuation.yield(.bargeIn) }
        holdContinuation.yield(.ended(itemIDs: h.items, byVoice: announce))
    }

    /// Stops Dee's reply where the listener is: flush, then tell the server exactly
    /// how much of the item was played. Late audio of that response is gated out.
    /// A hold it ends is a barge-in (timeline mark at the pause); `announce`: the
    /// voice ended it on its own (no words came, nobody answered them), so the app
    /// hears `.bargeIn`. When the brain ends it (`respond`, `stopSpeaking`) it is
    /// already acting on their words: no event that would stop its new reply.
    private func cutReply(_ s: inout Inner, announce: Bool = false) {
        // Calm: a ducked hold the brain's answer (or a stop) ends pauses first (R3 d).
        if s.hold?.phase == .ducked, s.hold?.probe != true { escalate(&s, why: "brain") }
        s.core.initiativePending = false
        specCut(&s, why: "cut")
        graph.player.flush()
        defer { releaseHold(&s, announce: announce) }
        if s.sessionPlaying, s.lastSessionItem != nil {
            s.gate.closeAfterCut()
            s.sessionPlaying = false
            s.finishDueAt = nil                        // `bargeIn` ends Dee's playback for the session
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

    /// Whether an item that played out un-flushed was all Dee meant to say: its
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

    /// One of Dee's items stopped: place its sentences on what was played, tell the brain.
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

    /// What of each of Dee's items was heard, after the player was flushed (or an
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
    /// treating it as possibly Dee's echo.
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
