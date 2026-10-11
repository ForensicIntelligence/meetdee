import Foundation

/// The platform-free decisions of `CloudVoice`: everything that decides *what
/// happens* given microphone frames, the realtime server's speech reports and
/// Dee's own playback. `CloudVoice` only moves audio and events; this struct is
/// unit-tested on its own with synthetic frames on a virtual clock.
///
/// What it decides:
/// - **Barge-in vs. echo.** The server's VAD hears everything the microphone
///   picks up, including what is left of Dee's own voice after echo
///   cancellation. A server `speech_started` while she plays (or within her echo
///   tail: the route's output latency plus `echoTail`) is only taken as the user
///   when there is local evidence: `BargeInDetector` (sustained voice above a bar
///   that rises with her own level), or the user still sounding after her audio
///   has left the room. Evidence → `.bargeIn` (flush, cancel, truncate); her
///   audio ended and the user carried on → `.acceptOnset` (a quick "Yes!" right
///   after her question counts: voice clearly above the echo she left, once her
///   direct sound is gone); no evidence by the server's `speech_stopped` (or
///   `decisionTimeout`) → `.rejectEcho`. Long, continuous, pitched local voice
///   the server has not reported barges in on its own (`localOnlyRun`), never
///   right after a laugh / applause was classified, and evidence the user
///   stopped giving expires. Over an aside (a laugh clip) the user talking is not a
///   barge-in: the clip stops quietly (`.yieldAside`), and an aside never deletes
///   the words of a user who held the floor when it started.
/// - **Echo reference and the noise floor.** Her rendered output (`reference`)
///   and the microphone go into `EchoReference`, which learns the echo path
///   (delay-searched envelope correlation) and predicts how much of every frame
///   is her. Once it knows, the barge-in bar is relative to the room, not fixed:
///   `nearAboveFloorDB` over the noise floor (which does not creep up on her own
///   echo) and `echoMarginDB` over the echo she explains, and only *pitched,
///   voice-band* frames count (`voiceLike`): a fan, a tap or clinking dishes are
///   never the user. Until it knows (the first moments of her first reply, or no
///   reference at all), the old conservative bar holds.
/// - **Near-end voice keeps an item.** An onset over her playback that reaches its
///   `speech_stopped` (or the decision timeout) without the sustained evidence is
///   still the user — never deleted as echo — when `nearEndEvidence` of pitched
///   voice her playback doesn't explain lies in its window.
/// - **Initiatives.** Local voice from the user before an initiative's first
///   audio cancels it (`.cancelInitiative`), ahead of the server's own VAD.
/// - **The face.** `.micLevel` (20 Hz while listening), `.pause` from
///   `TurnPredictor` (prosody only: there are no live partials), `.speakingStarted`
///   / `.speechLevel` (~30 Hz while she plays, gaps between words included, 0
///   before `.speakingFinished`) / `.speakingFinished`, `.bargeIn`, `.sound`.
/// - **`.heard`** when the server's transcript of a user item lands: the text plus
///   prosody measured locally over that item's audio window (mapped from the
///   server's milliseconds by the caller), with Dee's echo frames left out.
/// - **The uplink.** Mic audio goes to the server while connected and listening;
///   with listening off, `wakeOnVoice` opens it for sustained local voice (the
///   2 s pre-roll carries the start of what was said).
///
/// Times are host seconds on one clock (the graph's).
public struct EarCore: Sendable {
    public enum Action: Sendable, Equatable {
        case emit(VoiceEvent)
        /// The user really talked over her reply: flush the player, then tell the
        /// server what was played (`bargeIn(playedMs:)`). `itemID`: the user item
        /// the server opened for it (nil when only local evidence exists so far).
        /// The `.bargeIn` event follows as its own action.
        case bargeIn(itemID: String?)
        /// The user is talking over an aside (a clip): stop it quietly. Not a
        /// barge-in: no event, nothing to tell the server.
        case yieldAside(itemID: String?)
        /// A server onset during her playback or echo tail was the user after all
        /// (her audio had ended, or they held the floor through an aside).
        case acceptOnset(itemID: String)
        /// A server onset was Dee's own voice: delete that user item.
        case rejectEcho(itemID: String)
        /// A server onset over her voice that the local evidence can't settle
        /// (a voice under her echo as loud as the user): its words decide
        /// (`HerWords`). Neither accepted nor deleted yet. `strict`: the only hint
        /// was sound her echo model didn't explain (no other voice's pitch, no voice
        /// after her playback and its tail) — the words must be clearly not hers.
        case deferToWords(itemID: String, strict: Bool)
        /// Tune 7 (T6-4): without echo cancellation (her echo as loud as the user),
        /// an onset over her voice is still undecided, but there is a
        /// voice in its window her echo model doesn't explain: pause her now and
        /// listen in her silence (her loud echo masks the user; without it their
        /// voice shows at once). Neither accepted nor deleted: the decision follows
        /// as usual (`.bargeIn` once the evidence is there). Once per item.
        case probe(itemID: String)
        /// Tune 7: the probe heard nobody (quiet `probeQuiet` once her echo had
        /// cleared, or `probeMax`): she goes on from where she paused. A probe the
        /// user's voice confirms ends with `.bargeIn` instead.
        case probeEnded
        /// The user started talking before an initiative's first audio.
        case cancelInitiative
        /// Mic audio should (true) or should no longer (false) go to the server.
        case uplink(Bool)
        /// The user's voice is (true) or is no longer (false) heard locally —
        /// ~0.3 s ahead of the server's `speech_started` (`RealtimeSession.setLocalSpeech`).
        case localSpeech(Bool)
    }

    // MARK: Tunables

    /// Her voice's room tail after the last sample leaves the speaker.
    public static let echoTail = 0.5
    /// Tune 7 (T6-4): a probe (`.probe`) ends once nobody made a sound into her
    /// silence for this long — longer than the gap in "Wait, … stop talking" — …
    public static let probeQuiet = 0.7
    /// …counted from when her echo has left the room after the pause…
    public static let probeEchoClear = 0.15
    /// …and never lasts longer than this.
    public static let probeMax = 1.5
    /// Longest wait for evidence on a server onset while she keeps playing.
    public static let decisionTimeout = 1.5
    /// Tune 3: an onset the server still holds open after she stopped is given up
    /// (her echo) only this long after her echo left the room — the user may yet
    /// talk into it (tune-2 live, tv15 p06a: the TV opened it, the user spoke
    /// 0.7 s after her tail, and it was deleted at the timeout). Its stop decides
    /// it sooner.
    public static let openItemAfterTail = 4.0
    /// Tune 3: voice that is not hers (out of her playback and its tail) this long
    /// in an onset's window, without the evidence to accept it, sends it to its
    /// words instead of deleting it on the sound.
    public static let voiceAfterHer = 0.15
    /// Local evidence this long before the server's onset still counts.
    public static let evidenceLookback = 1.0
    /// Continuous voice above the bar (gaps up to `runGap`) this long, with no
    /// server onset: barge in anyway. Long, so a laugh or a burst of applause at
    /// her joke doesn't cut her off; the server's onset is the usual path.
    public static let localOnlyRun = 1.0
    /// Longest gap inside one continuous run of voice above the bar.
    public static let runGap = 0.12
    /// Share of a local-only run that must be pitched (speech, not claps / noise).
    public static let localOnlyPitched = 0.6
    /// No local-only barge-in this long after a laugh / applause was classified.
    public static let socialSuppress = 2.0
    /// Her direct sound has left the room this long after the output latency;
    /// what follows is only her decaying echo.
    public static let directEchoGuard = 0.1
    /// After she stopped: voice this much above the loudest echo she left in the
    /// microphone counts as the user.
    public static let postEchoMarginDB = 5.0
    /// That much of it accepts an onset in her echo tail at once (a short "Yes!").
    public static let quickAnswer = 0.12
    /// Her echo level estimate decays this fast (dB/s) to follow her recent peak.
    static let echoPeakDecayDBPerSecond = 6.0
    /// Sounding voice after her echo tail that proves an onset was the user.
    public static let userAfterTail = 0.25
    /// User voice that cancels a pending initiative.
    public static let initiativeOnset = 0.15
    /// Sustained local voice that opens the uplink while listening is off.
    public static let wakeVoice = 0.4
    /// The uplink stays open this long after the last voice that woke it.
    public static let wakeHold = 3.0
    /// `userIsSpeaking` stays true this long after the last voiced frame.
    public static let userSpeechHold = 0.6
    /// Unpitched sound this soon after their voice still counts as their speech.
    public static let speechBridge = 0.25
    /// Their voice over a known bed is at least this far above the room's floor.
    public static let voiceAboveFloorDB = 6.0
    /// `voiceActive` stays true this long after the last frame of their voice.
    public static let voiceActiveHold = 0.15
    public static let micLevelInterval = 0.05
    public static let speechLevelInterval = 1.0 / 30
    /// A player level older than this reads as 0 (an underrun or a gap between items).
    public static let levelStale = 0.07
    /// Without echo cancellation her voice reaches the mic almost unattenuated:
    /// the user must be this much louder again to count.
    public static let noAECMarginDB = 14.0
    /// Seconds of frame statistics kept for prosody windows.
    public static let frameLogSeconds = 40.0
    /// Pad around a server audio window when measuring prosody.
    public static let windowPad = 0.15
    /// Ignore classifier results this long after she stops when the result's audio
    /// window is unknown (one 1.5 s window plus the worst analysis delay).
    public static let ownVoiceTail = 1.5 + 0.4
    /// With a known window: windows reaching within this of her playback are hers.
    public static let ownVoiceGuard = 0.3
    /// With a learned echo path: the user's voice must be this far above the noise
    /// floor (AEC off: `noAECNearExtraDB` more)…
    public static let nearAboveFloorDB = 9.0
    /// …and this far above the echo her playback explains (AEC off: `noAECEchoMarginDB`)…
    public static let echoMarginDB = 6.0
    public static let noAECEchoMarginDB = 9.0
    public static let noAECNearExtraDB = 5.0
    /// …and at least this loud (dBFS; AEC off: +`noAECNearExtraDB`).
    public static let nearMinDB = -45.0
    /// Pitched near-end voice in an onset's window that keeps it from being deleted as echo.
    public static let nearEndEvidence = 0.2
    /// Voice-like near-end sound (`voiceHint`) in an onset's window that, without
    /// the evidence to accept it, sends it to `deferToWords` instead of deleting it.
    public static let wordsHint = 0.08
    /// …or this much unexplained voice-shaped sound (then the words must be clearly not hers).
    public static let wordsHintUnexplained = 0.12
    /// Near-end voice in an undecided onset's window that holds her next item back.
    public static let boundaryEvidence = 0.06
    /// Near-end voice that, with the server's onset, barges in at once.
    public static let corroboratedEvidence = 0.12
    /// Her echo's first moments in a stretch (after the longest echo delay) are
    /// never near-end evidence: the reverb is still building and the echo's
    /// level is least predictable there.
    public static let onsetGuard = 0.25
    /// Her echo gain assumed until it is learned (energy ratio): −20 dB with echo
    /// cancellation, 0 dB without.
    public static let echoPriorAEC = 0.01
    public static let echoPriorNoAEC = 1.0
    /// …of which at least this much pitched.
    public static let nearEndPitched = 0.08
    /// Sound with pitched voice in it that makes "the user is speaking" (noise,
    /// however loud, never does): this much sound, `VoiceRun.pitchedNeeded` of it pitched.
    public static let speechRun = 0.1
    /// Share of a frame's energy below ~1 kHz for it to count as voice (clinks, hiss: no).
    public static let voiceBandShare = 0.35
    static let voiceBandHz = 1_000.0
    /// YIN dip that counts as "periodic" for voicing (the f0 for prosody uses 0.15).
    public static let voicingThreshold = 0.35
    /// Laughter / applause while she plays must beat the barge-in bar by this.
    public static let socialOverSpeechMarginDB = 4.0
    public static let soundLoudnessWindow = 1.6
    /// The uplink gate opens this far above the room bed's ceiling (`RoomBed`)…
    public static let uplinkMarginDB = 5.0
    /// …but never more than this above the room's floor, nor above `uplinkMaxDB`:
    /// whatever the bed learned, a voice at the phone always gets through.
    public static let uplinkMaxAboveFloorDB = 12.0
    public static let uplinkMaxDB = -28.0
    /// Frames this far above the bed's ceiling are not learned as the bed.
    static let bedLearnHeadroomDB = 2.0
    /// With a known bed, the user's bar (with her voice in the room) is this far
    /// above its ceiling and `bedFloorMarginDB` above its floor: a steady fan or
    /// tap never reaches its ceiling + 3 dB, so a soft voice over it still counts.
    /// Never stricter than the fixed `nearAboveFloorDB` (which holds until the
    /// bed is known): a bed that learned some speech only means the old bar.
    public static let bedCeilingMarginDB = 3.0
    public static let bedFloorMarginDB = 4.0

    // MARK: Gates

    /// App gate (Dee asleep / backgrounded: false).
    public private(set) var listeningEnabled = true
    /// The realtime session is connected.
    public private(set) var connected = false
    /// Microphone permission (or injected audio).
    public private(set) var microphone = true
    /// With listening off, sustained local voice opens the uplink.
    public var wakeOnVoice = true
    /// Echo cancellation is really on (`AudioGraph.Facts`).
    public var aecActive = false {
        didSet {
            configureBarge()
            if aecActive != oldValue { echo.reset(); spectral.reset() }   // a new echo path
        }
    }
    /// Route output latency (s): her voice is still in the room this long after rendering.
    public var outputLatency = 0.0 {
        didSet {
            outputLatency = outputLatency.isFinite ? min(max(outputLatency, 0), 0.5) : 0
            if abs(outputLatency - oldValue) > 0.005 { echo.reset(); spectral.reset() }
            echo.outputLatency = outputLatency
            spectral.outputLatency = outputLatency
        }
    }

    /// Listening right now: enabled, connected, microphone.
    public var isListening: Bool { listeningEnabled && connected && microphone }

    // MARK: State

    public private(set) var vad = EnergyVAD()
    private var room = NoiseFloorTracker()
    /// The room's bed (fan, tap, TV) and its ceiling: the uplink gate's bar.
    public private(set) var bed = RoomBed()
    /// The uplink gate as seen at 40 ms (frames it would pass are not the bed).
    private var gateOpenUntil = -Double.infinity
    /// Her echo path, learned from her rendered output against the microphone.
    public private(set) var echo = EchoReference()
    /// …and per frequency band, for a voice under her loud echo.
    private var spectral = SpectralEcho()
    private var lastFrameAbove = false
    private var barge = BargeInDetector()
    private var predictor = TurnPredictor()
    private var pauseLearner = PauseScaleLearner()
    private var filter = UnexpectedSoundFilter()
    private var lastPauseEvent: (start: Double, turnEnd: Double, hesitation: Double)?

    /// Her audio is playing (from the first rendered sample until the player is idle).
    public private(set) var speaking = false
    /// The stretch playing now holds only asides (clips), no reply audio.
    public private(set) var asideOnly = false
    private var userHeldFloorAtAside = false
    private var startedEmitted = false
    private var bargedIn = false
    private var lastStretchBarged = false
    private var stretchStart = -Double.infinity
    private var playbackEnd = -Double.infinity
    private var ownLevel = 0.0
    private var lastLevelAt = -Double.infinity

    private var evidenceAt: Double?
    private var lastAboveBar = -Double.infinity
    private var aboveRunStart = -Double.infinity
    private var aboveRunFrames = 0
    private var aboveRunPitched = 0
    private var lastSocialSoundAt = -Double.infinity
    private var soundingAfterTail = 0.0
    /// Her echo in the microphone during this stretch (recent peak, dBFS).
    private var echoPeakDB = -Double.infinity
    /// Frozen when she stops: the echo she leaves behind is at most this loud.
    private var endEchoDB = -Double.infinity
    /// Voice clearly above her leftover echo since her direct sound left the room.
    private var postRun = 0.0

    private struct Pending: Sendable, Equatable {
        var itemID: String
        var arrivedAt: Double
    }
    private var pending: [Pending] = []
    /// Tune 7: onsets a `.probe` was sent for (newest 16).
    private var probed: [String] = []
    /// Tune 7: when the current probe paused her (nil: none).
    private var probeSince: Double?
    /// Items left to their words while the probe is on: it waits for them (their
    /// words may be the user's "Stop." that her echo hid), up to `probeMax`.
    private var probeWaits: Set<String> = []
    /// The user's speech item the server has open (and that is not echo).
    public private(set) var serverOpen: String?
    /// Tune 6: `serverOpen` was committed while still open (the voice's quick commit
    /// of a hold): the server goes on in an item it never announces (no
    /// speech_started), so the next stop or commit of *any* item closes it.
    private var serverOpenCommitted: String?

    private struct ItemTimes: Sendable {
        var onset: Double
        var end: Double?
    }
    private var items: [String: ItemTimes] = [:]
    /// Tune 9 (T8-1): the sound of items whose transcript came (their times are gone):
    /// `itemSound` still answers for them (newest 32).
    private var itemSounds: [String: FragmentSound] = [:]
    private var itemSoundOrder: [String] = []
    private var itemOrder: [String] = []
    private var rejected: Set<String> = []
    private var rejectedOrder: [String] = []

    private var lastUserVoiced = -Double.infinity
    /// Last frame of pitched user voice once `speechRun` of it was heard.
    private var lastUserSpeech = -Double.infinity
    private var speechRunNow = VoiceRun()
    private var lastUserSounding = -Double.infinity
    private var lastVoiced = -Double.infinity
    /// Last frame of the user's near-end voice (see `lastVoiceTime`).
    private var lastVoiceFrame = -Double.infinity

    /// An initiative was sent and has no audio yet.
    public var initiativePending = false { didSet { if !initiativePending { initiativeRun = VoiceRun() } } }
    private var initiativeRun = VoiceRun()

    private var wakeRun = 0.0
    private var wakeUntil = -Double.infinity
    private var uplinkReported = false
    private var localSpeechReported = false
    /// She went on after a hold here: what the user said before it was decided
    /// already (a backchannel) and is no evidence for a new onset.
    private var resumedAt = -Double.infinity

    /// Listening as last reported (starts closed: only an opening is news).
    private var reportedListening = false
    private var nextMicEmit = -Double.infinity
    private var nextSpeechLevelEmit = -Double.infinity
    private var latest = -Double.infinity

    private struct FrameStat: Sendable {
        var t: Double
        var dt: Double
        var energy: Double
        var samples: Int
        var rate: Double
        var peak: Float
        var db: Double
        var user: Bool
        var f0: Double?
        /// Her voice was in the room.
        var her: Bool
        /// Voiced by the energy VAD, or clearly above a known bed (a soft voice).
        var rawVoiced: Bool
        /// Pitched, voice-band.
        var voiceLike: Bool
        /// The user's sound (not her echo), above the room's floor.
        var sounding: Bool
        /// The user's speech (sound in a run with pitched voice: `userIsSpeaking`).
        var speech = false
        /// Her envelope that could reach this frame (before the echo gain; nil:
        /// no reference). Kept so the frame can be judged again with the echo
        /// path learned later: near-end evidence always uses the best model.
        var reach: Double?
        var floorDB: Double
        /// The room's part of the user's bar (floor, minimum, her echo tail).
        var minBar: Double
        /// dB over her predicted echo the user's voice needs.
        var margin: Double
        /// The echo gain the frame was judged with live (learned, or the prior).
        var gainThen: Double?
        /// In the first moments of a stretch of hers, while her echo (and its
        /// reverb) is still building up: never near-end with a reference.
        var herOnset = false
        /// Above the conservative fixed bar (used when there is no reference).
        var fallbackAbove: Bool
        /// Per band, a voice her echo doesn't explain, above the room's bar (`SpectralEcho`).
        var spectralNear = false
        /// …and the frame's pitch is not hers (another voice is in it).
        var spectralPitched = false
        /// Tune 11: the share of the frame's energy her echo model doesn't explain (nil: no model yet).
        var spectralShare: Double?
    }

    /// The user's bar for a logged frame under the echo path known now (before
    /// it is learned: the prior); nil without a reference.
    private func userBar(_ f: FrameStat) -> Double? {
        // Judged again only ever more strictly: a frame her echo explained stays hers.
        guard let r = f.reach, let now = echo.gain ?? echo.prior else { return nil }
        let g = max(now, f.gainThen ?? 0)
        return max(f.minBar, Level.powerDB(g * r + pow(10, f.floorDB / 10)) + f.margin)
    }

    /// Near-end sound in a logged frame (above the user's bar, not explained by
    /// her playback), and whether it was pitched voice. Judged with the echo path
    /// known *now*: frames from before it was learned are judged again with it.
    private func judge(_ f: FrameStat, onsetGuard: Bool = true) -> (near: Bool, pitched: Bool) {
        // Out of her playback: the user's speech, by the same test as `userIsSpeaking`
        // (a running tap or a clatter never is).
        guard f.her else { return (f.speech, f.speech && f.voiceLike) }
        guard let bar = userBar(f) else { return (f.fallbackAbove, f.fallbackAbove && f.voiceLike) }
        if f.herOnset, onsetGuard { return (false, false) }
        if f.rawVoiced && f.db >= bar { return (true, f.voiceLike) }
        let near = f.rawVoiced && f.spectralNear
        return (near, near && f.spectralPitched)
    }
    private var frames: [FrameStat] = []
    /// The last frame's measurements (tests print them to tune against fixtures).
    var debugFrame: (db: Double, floor: Double, bar: Double, f0: Double?, low: Double, voiceLike: Bool, above: Bool)?
    var debugSpec: SpectralEcho.Result?
    var debugState: String { "ev \(evidenceAt != nil) pend \(pending.map(\.itemID)) spk \(speaking) her \(herTime(at: latest)) barged \(bargedIn) fired \(barge.hasFired) spec \(debugSpec.map { String(format: "%.1f f%.2f l%.2f", $0.nearDB, $0.fraction, $0.lowShare) } ?? "-") sn \(frames.last?.spectralNear == true ? 1 : 0)\(frames.last?.spectralPitched == true ? 1 : 0) rdy \(spectral.ready) conf \(echo.confident) minBar \(frames.last.map { String(format: "%.1f", $0.minBar) } ?? "-")" }

    public init() {
        configureBarge()
    }

    /// Per-person pause scale, 0.7…1.6 (1 = typical): the `.pause` hold estimate.
    public var pauseScale: Double {
        get { pauseLearner.scale }
        set { pauseLearner.set(newValue) }
    }

    /// Mean dBFS of the room when nobody is talking.
    public var ambientDB: Double { vad.noiseFloorDB }

    /// The room's noise floor for the user's bar: the VAD's floor, or — once known —
    /// a low percentile of the last few seconds (a running tap or a fan is the
    /// floor, not a quiet moment between clinks), whichever is higher.
    public var roomFloorDB: Double { max(vad.noiseFloorDB, room.floorDB ?? -160) }

    /// The uplink gate's bar (dBFS per 10 ms): mic audio below it is the room's bed
    /// (a TV, a fan) and is sent attenuated (`UplinkGate`). Nil until the bed is known.
    public var uplinkBarDB: Double? {
        guard let c = bed.ceilingDB else { return nil }
        return min(c + Self.uplinkMarginDB, (bed.floorDB ?? roomFloorDB) + Self.uplinkMaxAboveFloorDB, Self.uplinkMaxDB)
    }

    /// The room's part of the user's bar while her voice is in the room: over a
    /// known bed, above its ceiling (and clearly above its floor); before that,
    /// the fixed margin over the floor.
    private func roomBar(extra: Double) -> Double {
        let floor = roomFloorDB
        guard let c = bed.ceilingDB else { return floor + Self.nearAboveFloorDB + extra }
        return min(floor + Self.nearAboveFloorDB, max(floor + Self.bedFloorMarginDB, c + Self.bedCeilingMarginDB)) + extra
    }

    /// When the user last actually made sound (no VAD hangover), host seconds.
    public var lastUserSoundTime: Double { lastUserSounding }

    /// An onset is waiting for the barge-in / echo decision.
    public var deciding: Bool { !pending.isEmpty }

    /// The onset of `itemID` waits for the barge-in / echo decision.
    public func isDeciding(_ itemID: String) -> Bool { pending.contains { $0.itemID == itemID } }

    /// An onset being decided already has near-end voice in its window (it may
    /// well be the user): her next item waits at the boundary until it is decided.
    public func pendingMayBeUser(at t: Double) -> Bool {
        pending.contains { p in
            let from = max((items[p.itemID]?.onset ?? p.arrivedAt - 0.3) - 0.3, resumedAt)
            return nearEndVoice(from: from, to: t).all >= Self.boundaryEvidence - 1e-9
        }
    }

    /// `itemID` was rejected as echo.
    public func isRejected(_ itemID: String) -> Bool { rejected.contains(itemID) }

    // MARK: Gates

    public mutating func setListeningEnabled(_ on: Bool, at t: Double) -> [Action] {
        listeningEnabled = on
        if !on { resetTurn() }
        return sync(at: t)
    }

    public mutating func setConnected(_ on: Bool, at t: Double) -> [Action] {
        connected = on
        if !on {
            // A new connection starts a new server timeline: nothing open survives.
            serverOpen = nil
            pending.removeAll()
            initiativePending = false
            resetTurn()
        }
        return sync(at: t)
    }

    public mutating func setMicrophone(_ on: Bool, at t: Double) -> [Action] {
        microphone = on
        return sync(at: t)
    }

    // MARK: Microphone

    public mutating func frame(_ samples: [Float], sampleRate: Double, at t: Double) -> [Action] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        latest = max(latest, t)
        let dt = Double(samples.count) / sampleRate
        var energy = 0.0
        var peak: Float = 0
        for v in samples {
            let d = Double(v)
            energy += d * d
            peak = max(peak, abs(v))
        }
        let db = Level.powerDB(energy / Double(samples.count))
        let her = herTime(at: t)
        // The floor never creeps up on her own echo (it may still fall).
        let rawVoiced = vad.process(frameDB: db, frameDuration: dt, allowRise: !her)
        if rawVoiced { lastVoiced = t }
        let knewEcho = echo.gain != nil
        feedEcho(samples, at: t, duration: dt)
        if !knewEcho, let g = echo.gain, g > (echo.prior ?? 0) {
            // Her echo is louder than the prior assumed: evidence built on it is void.
            evidenceAt = nil
            barge.reset()
            lastAboveBar = -Double.infinity
        }
        // What of this frame her playback can explain (before the echo gain).
        let reach = echo.hasReference(at: t) ? echo.reach(from: t - dt, to: t) : nil
        // Per band: a voice under her loud echo still shows where she is quiet.
        let spec = spectral.analyze(samples, rate: sampleRate, endingAt: t, delay: echo.delay,
                                    broadbandGain: echo.gain ?? echo.prior,
                                    learn: her && speaking && !bargedIn && echo.confident && !lastFrameAbove)
        // The room's own floor, learned while her voice is out of the room (what
        // is left while she talks may be the user talking over her).
        if !her { room.add(db, at: t) }
        // The bed: frames neither hers nor (as far as the uplink gate can tell) the
        // user's. Sound clearly above the bed's ceiling but under the gate's bar may
        // be a soft voice: it never teaches the bed to be louder.
        if let bar = uplinkBarDB, db >= bar { gateOpenUntil = t + UplinkGate.hangover }
        let maybeVoice = bed.ceilingDB.map { db >= $0 + Self.bedLearnHeadroomDB } ?? false
        if !her, uplinkBarDB == nil || (t > gateOpenUntil && !maybeVoice) {
            bed.add(db, duration: dt, at: t)
        } else {
            bed.advance(to: t)
        }
        let level = ownLevelNow(at: t)
        // Without any reference: the conservative fixed bar.
        var fallbackBar = barge.bar(floorDB: roomFloorDB, ownSpeechLevel: level)
        // In her echo tail her level reads 0: the user must also be clearly above
        // the echo she left behind.
        let tailBar = her && !speaking ? postBar : -Double.infinity
        fallbackBar = max(fallbackBar, tailBar)
        // Pitched, voice-band sound: speech, not a fan, a tap or a clink.
        var f0: Double?
        var looseF0: Double?
        var voiceLike = false
        var lowShare = 0.0
        // Over a known bed, sound clearly above it is a candidate for the user's
        // voice even where the energy VAD (10 dB over the minima) doesn't call it
        // voiced: a soft voice over a fan sits 7–9 dB above it.
        let extra = aecActive ? 0 : Self.noAECNearExtraDB
        let heard = rawVoiced || (bed.ceilingDB != nil && db >= roomBar(extra: extra) && db > vad.absoluteMinDB)
        if heard {
            let (small, rate) = PitchDetector.decimate(samples, sampleRate: sampleRate)
            // Voicing needs periodicity, not a clean pitch track: real speech glides
            // within a frame, so a looser YIN dip counts here (prosody keeps the strict f0).
            let pitch = PitchDetector.analyzeLoose(small, sampleRate: rate, looseThreshold: Self.voicingThreshold)
            f0 = pitch.f0
            looseF0 = pitch.looseF0
            let periodic = pitch.f0 != nil || pitch.periodic
            lowShare = Self.lowBandShare(samples, sampleRate: sampleRate)
            voiceLike = periodic && lowShare >= Self.voiceBandShare
        }
        var stat = FrameStat(t: t, dt: dt, energy: energy, samples: samples.count, rate: sampleRate, peak: peak,
                             db: db, user: false, f0: f0, her: her, rawVoiced: heard, voiceLike: voiceLike,
                             sounding: false, reach: reach, floorDB: roomFloorDB,
                             minBar: max(roomBar(extra: extra), Self.nearMinDB + extra, tailBar),
                             margin: aecActive ? Self.echoMarginDB : Self.noAECEchoMarginDB,
                             gainThen: reach == nil ? nil : (echo.gain ?? echo.prior),
                             herOnset: speaking && t - stretchStart < EchoReference.maxLag + outputLatency + Self.onsetGuard,
                             fallbackAbove: rawVoiced && db >= fallbackBar)
        stat.spectralNear = spec.map { $0.isVoice && $0.nearDB >= stat.minBar } ?? false
        stat.spectralShare = spec?.fraction
        if stat.spectralNear, let f = f0 ?? looseF0 {
            // Under her echo the frame is pitched anyway: only a pitch that isn't
            // hers says the sound she doesn't explain is a voice.
            stat.spectralPitched = SpectralEcho.differentVoice(f, from: spectral.herPitches(at: t, delay: echo.delay))
        }
        debugSpec = spec
        // Above the user's bar: sound her playback doesn't explain.
        // (Over a laugh clip — all onset — talking still makes it give way.)
        let judged: (near: Bool, pitched: Bool) = her ? judge(stat, onsetGuard: !asideOnly)
            : (stat.fallbackAbove, stat.fallbackAbove && voiceLike)
        let above = judged.near
        debugFrame = (db, roomFloorDB, userBar(stat) ?? fallbackBar, f0, lowShare, voiceLike, above)
        lastFrameAbove = above
        if her && !bargedIn {
            if barge.update(near: above, pitched: judged.pitched, frameDuration: dt) {
                evidenceAt = t
            }
        }
        // Her own echo level while she plays (frames that are not the user).
        if speaking && !above {
            echoPeakDB = max(db, echoPeakDB - Self.echoPeakDecayDBPerSecond * dt)
        }
        // After she stopped: voice clearly above the echo she left is the user.
        let afterDirect = !speaking && t >= playbackEnd + outputLatency + Self.directEchoGuard
        let postAbove = afterDirect && t < tailEnd && rawVoiced && db >= postBar && voiceLike
        if !speaking { postRun = postAbove ? postRun + dt : max(0, postRun - dt) }
        // While her voice is in the room, voiced frames below the bar are her echo.
        let userVoiced = rawVoiced && (!her || bargedIn || above || postAbove)
        let sounding = userVoiced && db > roomFloorDB + vad.thresholdAboveFloor && db > vad.absoluteMinDB
        if userVoiced { lastUserVoiced = t }
        if sounding { lastUserSounding = t }
        // "The user is speaking" needs voice, not just sound (kitchen noise is not a turn).
        // Pitched frames build the run, other sound holds it, silence lets it go.
        let speechFrame = sounding && voiceLike
        speechRunNow.update(sounding: sounding, pitched: speechFrame, dt: dt)
        // Once it is speech, the VAD's hangover carries it like any voiced frame.
        // Their voice: pitched speech of theirs, and — over a known bed — at the
        // uplink gate's bar (a TV's talkers, a clink, a tap stay under it).
        // Over a known bed its bar decides (a soft "w" over a fan is 7 dB above the
        // bed, under the VAD's 10); before, the VAD's.
        let aboveRoom = uplinkBarDB.map { db >= max($0, roomFloorDB + Self.voiceAboveFloorDB) } ?? sounding
        let theirs = userVoiced || (heard && (!her || bargedIn || above || postAbove))
        if theirs, voiceLike, aboveRoom, db > vad.absoluteMinDB { lastVoiceFrame = t }
        // Once it is speech, unpitched sound carries it only right after their voice
        // (a consonant, a breath between words): a kitchen's clatter or a TV after
        // they stopped never keeps "the user is speaking" on (tune 4 live F2:
        // ready replies held 0.6–1.3 s in kitchen15 / tv15).
        if userVoiced, speechRunNow.reached(Self.speechRun), t - lastVoiceFrame <= Self.speechBridge + 1e-9 {
            lastUserSpeech = t
        }
        if !userVoiced { f0 = nil }                       // her echo's pitch is not the user's
        if above {
            if t - lastAboveBar > Self.runGap + dt + 1e-9 {
                aboveRunStart = t - dt
                aboveRunFrames = 0
                aboveRunPitched = 0
            }
            lastAboveBar = t
            aboveRunFrames += 1
            if judged.pitched { aboveRunPitched += 1 }
        }
        // Evidence the user stopped giving expires (a cough long ago is not a barge-in).
        if evidenceAt != nil, t - lastAboveBar > Self.evidenceLookback {
            evidenceAt = nil
            barge.reset()
        }
        stat.user = userVoiced
        stat.f0 = f0
        stat.sounding = sounding
        stat.speech = lastUserSpeech == t
        log(stat)
        if !speaking, t >= tailEnd, speechFrame { soundingAfterTail += dt }

        var actions: [Action] = []
        // The user beat her initiative's first audio.
        if initiativePending, !speaking {
            initiativeRun.update(sounding: sounding, pitched: speechFrame, dt: dt)
            if initiativeRun.reached(Self.initiativeOnset) {
                initiativePending = false
                actions.append(.cancelInitiative)
            }
        }
        // Waking the uplink while listening is off.
        if !listeningEnabled, wakeOnVoice {
            wakeRun = sounding ? wakeRun + dt : max(0, wakeRun - dt)
            if wakeRun >= Self.wakeVoice - 1e-9 || (sounding && t < wakeUntil) { wakeUntil = t + Self.wakeHold }
        } else {
            wakeRun = 0
        }
        // Turn shape for the face (the server decides the actual end of turn).
        if isListening, !her || bargedIn {
            predictor.frame(sounding: sounding, db: db, f0Hz: f0, duration: dt, at: t)
            if predictor.voicedTime > 0, serverOpen == nil, t - lastUserSounding > 2.5 {
                predictor.resetTurn()                         // stray noise, nobody's turn
            }
            actions += predictTurn(at: t)
        }
        if isListening, !speaking, Self.due(&nextMicEmit, at: t, every: Self.micLevelInterval) {
            actions.append(.emit(.micLevel(Level.meter(db))))
        }
        actions += decide(at: t, final: nil)
        actions += localOnlyBargeIn(at: t)
        actions += checkProbe(at: t)
        actions += syncUplink(at: t)
        actions += syncLocalSpeech(at: t)
        return actions
    }

    /// Housekeeping at ~30 Hz: speech level, decision deadlines, uplink.
    public mutating func tick(at t: Double) -> [Action] {
        latest = max(latest, t)
        var actions: [Action] = []
        if speaking, Self.due(&nextSpeechLevelEmit, at: t, every: Self.speechLevelInterval) {
            actions.append(.emit(.speechLevel(ownLevelNow(at: t))))
        }
        actions += decide(at: t, final: nil)
        actions += localOnlyBargeIn(at: t)
        actions += checkProbe(at: t)
        actions += syncUplink(at: t)
        actions += syncLocalSpeech(at: t)
        return actions
    }

    /// The user's own voice, as heard here (not the server's open speech).
    private mutating func syncLocalSpeech(at t: Double) -> [Action] {
        let on = isListening && t - lastUserSpeech <= Self.userSpeechHold
        guard on != localSpeechReported else { return [] }
        localSpeechReported = on
        return [.localSpeech(on)]
    }

    // MARK: Her playback

    /// An utterance's first sample played (`aside`: a clip, not reply audio).
    public mutating func playbackStarted(at t: Double, aside: Bool) -> [Action] {
        latest = max(latest, t)
        guard !speaking else {
            if !aside { asideOnly = false }
            return []
        }
        speaking = true
        asideOnly = aside
        userHeldFloorAtAside = aside && userHoldsFloor(at: t)
        bargedIn = false
        stretchStart = t
        evidenceAt = nil
        soundingAfterTail = 0
        echoPeakDB = -Double.infinity
        postRun = 0
        barge.reset()
        nextSpeechLevelEmit = -Double.infinity
        startedEmitted = true
        initiativePending = false
        return [.emit(.speakingStarted)]
    }

    /// Her paused reply goes on (the words over it were a backchannel, or the
    /// onset was her echo): a fresh stretch of hers. Her echo builds up again
    /// (onset guard), and a new onset over her is decided like any other.
    public mutating func playbackResumed(at t: Double) -> [Action] {
        latest = max(latest, t)
        guard speaking else { return [] }
        probeSince = nil
        probeWaits.removeAll()
        bargedIn = false
        lastStretchBarged = false
        stretchStart = t
        resumedAt = t
        evidenceAt = nil
        lastAboveBar = -Double.infinity
        barge.reset()
        return []
    }

    /// 0…1 from the samples just played.
    public mutating func playbackLevel(_ level: Double, at t: Double) {
        ownLevel = min(max(level.isFinite ? level : 0, 0), 1)
        lastLevelAt = t
    }

    /// Her rendered output (`PCMStreamPlayer.takeReference()`), for echo gating.
    public mutating func reference(_ bins: [EchoReference.Bin]) {
        echo.addReference(bins)
        spectral.addReference(bins)
    }

    /// The player is idle: everything played, or was flushed.
    public mutating func playbackFinished(at t: Double) -> [Action] {
        latest = max(latest, t)
        guard speaking else { return [] }
        probeSince = nil
        probeWaits.removeAll()
        speaking = false
        playbackEnd = t
        lastStretchBarged = bargedIn
        bargedIn = false
        ownLevel = 0
        lastLevelAt = -Double.infinity
        soundingAfterTail = 0
        endEchoDB = echoPeakDB
        postRun = 0
        var actions: [Action] = []
        if startedEmitted {
            startedEmitted = false
            actions += [.emit(.speechLevel(0)), .emit(.speakingFinished)]
        }
        return actions + decide(at: t, final: nil)
    }

    // MARK: Server speech

    /// `input_audio_buffer.speech_started`. `onset`: host time of `audio_start_ms`
    /// when the uplink map knows it.
    public mutating func serverSpeechStarted(itemID: String, onset: Double?, at t: Double) -> [Action] {
        latest = max(latest, t)
        guard !rejected.contains(itemID) else { return [] }
        let start = onset.map { min($0, t) } ?? t - 0.3
        remember(itemID, ItemTimes(onset: start, end: nil))
        // While the user is already cutting her off (or just did), whatever the
        // server hears is them.
        let overPlayback = (speaking && !bargedIn) || (!speaking && !lastStretchBarged && start < tailEnd)
        guard overPlayback else {
            serverOpen = itemID
            return syncUplink(at: t)
        }
        pending.append(Pending(itemID: itemID, arrivedAt: t))
        return decide(at: t, final: nil) + syncUplink(at: t)
    }

    /// `input_audio_buffer.speech_stopped`: the turn's audio is complete. Undecided
    /// onsets are decided now, before the item is committed.
    public mutating func serverSpeechStopped(itemID: String, end: Double?, at t: Double) -> [Action] {
        latest = max(latest, t)
        if var times = items[itemID] {
            // An end mapped before the item's onset is from another timeline (a
            // rollover rebased the map under a late event): the window would be
            // empty and the words in it unseen. The server stopped it about now.
            let mapped = end.map { min($0, t) }
            times.end = mapped.flatMap { $0 > times.onset ? $0 : nil } ?? t - 0.2
            items[itemID] = times
        }
        var actions = decide(at: t, final: itemID)
        // Tune 6 (interrupt-clean q02): our commit split their burst; the server's
        // stop is for the unannounced tail item, and it ends the open speech too.
        if serverOpen == itemID || (serverOpen != nil && serverOpenCommitted == serverOpen) { serverOpen = nil }
        if !rejected.contains(itemID) {
            // Their turn is over: learn its pauses, start the next turn clean.
            pauseLearner.observe(pauses: predictor.endTurn(text: ""))
            lastPauseEvent = nil
        }
        actions += syncUplink(at: t)
        return actions
    }

    /// `input_audio_buffer.committed`: an onset still undecided is decided now, as
    /// at its stop (a commit may come with no `speech_stopped`, e.g. one the app
    /// sent). No-op for anything else.
    public mutating func serverCommitted(itemID: String, at t: Double) -> [Action] {
        guard pending.contains(where: { $0.itemID == itemID }) else { return [] }
        return serverSpeechStopped(itemID: itemID, end: nil, at: t)
    }

    /// Tune 6: `input_audio_buffer.committed` of any item. The open item committed
    /// (our quick commit) stays open — they may be talking on, in an item the server
    /// never announces — until the next stop or commit; a commit of another item
    /// after it closes it (t2-interrupt-clean q02: `userIsSpeaking` stayed on 8 s).
    public mutating func serverItemCommitted(itemID: String, at t: Double) -> [Action] {
        latest = max(latest, t)
        guard let open = serverOpen else { return [] }
        if open == itemID {
            serverOpenCommitted = itemID
            return []
        }
        guard serverOpenCommitted == open else { return [] }
        serverOpen = nil
        return syncUplink(at: t)
    }

    /// The user's last burst of sound since `since`: its first and last sounding
    /// frame (bursts are split by `gap` of silence), and the seconds of sound in it.
    /// Nil when they made no sound since then.
    public func lastUserBurst(since: Double, gap: Double) -> (start: Double, end: Double, sound: Double)? {
        var end: Double?, start = 0.0, sound = 0.0
        for f in frames.reversed() {
            if f.t < since { break }
            guard f.sounding else { continue }
            if end == nil {
                end = f.t
            } else if start - f.t >= gap - 1e-9 {
                break
            }
            start = f.t - f.dt
            sound += f.dt
        }
        return end.map { (start, $0, sound) }
    }

    /// The server's transcript of a user item: `.heard` with local prosody over
    /// the item's audio window. Nothing for echo, unknown items or empty text.
    public mutating func serverTranscript(itemID: String, text: String, at t: Double) -> [Action] {
        latest = max(latest, t)
        guard !rejected.contains(itemID) else { return [] }
        if let it = items[itemID] { keepSound(itemID, sound(from: it.onset, to: min(it.end ?? t, t))) }
        let times = items.removeValue(forKey: itemID)
        itemOrder.removeAll { $0 == itemID }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var acc = ProsodyAccumulator()
        var span = 0.0
        if let times {
            let lo = times.onset - Self.windowPad
            let hi = (times.end ?? t) + Self.windowPad
            span = max(0, (times.end ?? t) - times.onset)
            for f in frames where f.t - f.dt >= lo && f.t <= hi {
                acc.add(energy: f.energy, samples: f.samples, peak: f.peak, voiced: f.user, f0: f.f0, sampleRate: f.rate)
            }
        }
        let p = acc.prosody(text: clean)
        let words = Double(ProsodyAccumulator.wordCount(clean))
        let duration = acc.voicedDuration > 0 ? acc.voicedDuration : (span > 0 ? span : words / 2.5)
        return [.emit(.heard(HeardUtterance(text: clean, prosody: p, duration: duration)))]
    }

    /// Tests: an undecided onset goes to its words now (as a final decision would
    /// when the local evidence can't settle it).
    mutating func deferToWordsNow(_ itemID: String) -> [Action] {
        guard pending.contains(where: { $0.itemID == itemID }) else { return [] }
        pending.removeAll { $0.itemID == itemID }
        if serverOpen == itemID { serverOpen = nil }
        return [.deferToWords(itemID: itemID, strict: false)]
    }

    /// The item was rejected as echo elsewhere (or deleted): forget it.
    public mutating func forget(_ itemID: String) {
        markRejected(itemID)
    }

    // MARK: Questions

    /// The user is talking right now: their voice in the last `userSpeechHold`, or
    /// the server has their speech open. An onset still being decided (maybe her
    /// own echo) doesn't count until it is known to be them.
    public func userIsSpeaking(at t: Double) -> Bool {
        t - lastUserSpeech <= Self.userSpeechHold || serverOpen != nil
    }

    /// When the user's voice was last heard (graph clock): a frame of pitched,
    /// voice-band sound that is theirs (not her echo) and above the room's bed.
    /// No hangover: the release gate's "are they talking now?".
    public var lastVoiceTime: Double { lastVoiceFrame }

    /// The user's voice is in the room right now: heard within `voiceActiveHold`.
    /// Far quicker to let go than `userIsSpeaking` (0.6 s), and never on for a
    /// kitchen, a fan or a TV in the next room.
    public func voiceActive(at t: Double) -> Bool {
        t - lastVoiceFrame <= Self.voiceActiveHold + 1e-9
    }

    /// Seconds of the user's pitched voice in server item `itemID` (its onset to
    /// its end, or `t`), nil when the item is unknown here.
    public func voiceSeconds(itemID: String, until t: Double) -> Double? {
        guard let it = items[itemID] else { return nil }
        return nearEndVoice(from: it.onset, to: min(it.end ?? t, t)).pitched
    }

    /// Tune 9 (T8-1): what server item `itemID` sounded like (`FragmentSound`): their
    /// near-end voice from its onset to its end (or `t`), judged with the echo path known
    /// now — never her echo. After its transcript, what it sounded like then. Nil when
    /// the item is unknown here (rejected, forgotten, or never announced).
    public func itemSound(itemID: String, until t: Double) -> FragmentSound? {
        if let it = items[itemID] { return sound(from: it.onset, to: min(it.end ?? t, t)) }
        return itemSounds[itemID]
    }

    /// Their voice between `a` and `b` (`itemSoundPad` after it: the last syllable's decay).
    private func sound(from a: Double, to b: Double) -> FragmentSound {
        var out: [FragmentSound.Frame] = []
        for f in frames where f.t - f.dt >= a - 1e-9 && f.t <= b + Self.itemSoundPad + 1e-9 {
            let j = judge(f)
            out.append(FragmentSound.Frame(t: f.t, dt: f.dt, db: f.db, near: j.near, pitched: j.pitched,
                                           f0: j.pitched ? f.f0 : nil))
        }
        return FragmentSound.analyze(out)
    }

    /// Seconds after an item's end its sound still counts (`itemSound`).
    static let itemSoundPad = 0.08

    private mutating func keepSound(_ id: String, _ sound: FragmentSound) {
        if itemSounds[id] == nil { itemSoundOrder.append(id) }
        itemSounds[id] = sound
        while itemSoundOrder.count > 32 { itemSounds[itemSoundOrder.removeFirst()] = nil }
    }

    /// Tune 8 (T7-3): with no echo cancellation, server item `itemID` began within
    /// `within` s of the start of her current stretch (her first audio, or her
    /// resume), while she plays — where her own echo most often opens an item
    /// (live: "Yeah." 0.26 s into her reply, "You." 0.7 s). False once forgotten.
    public func onsetEarlyInStretch(itemID: String, within: Double) -> Bool {
        guard !aecActive, speaking, let it = items[itemID] else { return false }
        return it.onset - stretchStart <= within + 1e-9
    }

    /// Tune 11 (T10-2b / T10-3): less near-end sound than this in an item's window, and
    /// less than `unexplainedShare` of its energy unexplained over her voice: her echo.
    public static let explainedVoice = 0.12
    /// This much near-end sound with `voiceShare`, or `unexplainedShare` of its energy
    /// unexplained over her voice: a voice her echo can't be.
    public static let unexplainedVoice = 0.16
    public static let voiceShare = 0.20
    public static let unexplainedShare = 0.25

    /// Tune 11 (T10-2b / T10-3): does her echo model (`EchoReference` + `SpectralEcho`: her
    /// rendered output through the echo path learned from it) explain the sound of server
    /// item `itemID`, from its onset to its end? True: it is all hers (under
    /// `explainedVoice` of near-end sound, under `unexplainedShare` unexplained). False:
    /// there is a voice in it her echo can't be (`unexplainedVoice` with `voiceShare`, or
    /// `unexplainedShare`). Nil in between (the sound can't tell), or when the item is
    /// unknown here.
    ///
    /// Offline, −10 dB echo without echo cancellation through the room IR (harness fixtures,
    /// five of her voices), items the ear left to their words: her echo alone 0.04–0.08 s
    /// (most) or 0.12 s, one 0.16 s at a share of 0.19; "Stop." and "Go on." 0.12–0.40 s,
    /// mostly 0.16 s or more at a share over 0.20.
    public func echoExplains(itemID: String, at t: Double) -> Bool? {
        guard let it = items[itemID] else { return nil }
        let b = min(it.end ?? t, t)
        var near = 0.0, share = 0.0, herSeconds = 0.0, seen = false
        for f in frames where f.t - f.dt >= it.onset - 1e-9 && f.t <= b + 1e-9 {
            seen = true
            if judge(f).near { near += f.dt }
            if f.her, !f.herOnset, let x = f.spectralShare {
                share += x * f.dt
                herSeconds += f.dt
            }
        }
        guard seen else { return nil }
        let meanShare = herSeconds > 0 ? share / herSeconds : 0
        if meanShare >= Self.unexplainedShare - 1e-9
            || (near >= Self.unexplainedVoice - 1e-9 && meanShare >= Self.voiceShare - 1e-9) { return false }
        if near < Self.explainedVoice - 1e-9 { return true }
        return nil
    }

    /// Her voice may be in the microphone right now: playing, or within the echo
    /// tail of a stretch the user did not cut.
    public func herVoiceInRoom(at t: Double) -> Bool { herTime(at: t) }

    /// The user is mid-turn (an aside now leaves their turn alone).
    public func userHoldsFloor(at t: Double) -> Bool {
        t - lastUserSpeech <= Self.userSpeechHold || serverOpen != nil
    }

    /// Near-end voice (above the bar, not explained by her playback) between
    /// `from` and `to`: seconds of it, and seconds of it that were pitched.
    public func nearEndVoice(from a: Double, to b: Double) -> (all: Double, pitched: Double) {
        var all = 0.0, pitched = 0.0
        for f in frames.reversed() {
            if f.t < a { break }
            guard f.t <= b else { continue }
            let j = judge(f)
            if j.near { all += f.dt }
            if j.pitched { pitched += f.dt }
        }
        return (all, pitched)
    }

    /// Tune 7 (T6-4): a voice in the pending onset's window that her echo doesn't
    /// explain — the same hint that leaves an item to its words at its stop
    /// (`deferToWords`), seen while the item is still open.
    private func probeHint(_ p: Pending, at t: Double) -> Bool {
        let from = max((items[p.itemID]?.onset ?? p.arrivedAt - 0.3) - 0.3, resumedAt)
        let hint = voiceHint(from: from, to: t)
        return hint.pitched >= Self.wordsHint - 1e-9 || hint.unexplained >= Self.wordsHintUnexplained - 1e-9
    }

    /// Tune 7: the probe is over when nobody spoke into her silence (`probeQuiet`
    /// after her echo cleared and after their last sound), or at `probeMax`.
    private mutating func checkProbe(at t: Double) -> [Action] {
        guard let since = probeSince else { return [] }
        guard speaking, !bargedIn else { probeSince = nil; probeWaits.removeAll(); return [] }
        let quietFrom = max(since + Self.probeEchoClear, lastUserSounding)
        let quiet = t - quietFrom >= Self.probeQuiet - 1e-9 && probeWaits.isEmpty
        guard quiet || t - since >= Self.probeMax - 1e-9 else { return [] }
        probeSince = nil
        probeWaits.removeAll()
        return [.probeEnded]
    }

    /// Tests: a probe for the undecided onset `itemID` now (as its hint would start one).
    mutating func probeNow(_ itemID: String, at t: Double) -> [Action] {
        guard pending.contains(where: { $0.itemID == itemID }), speaking, !bargedIn, probeSince == nil else { return [] }
        probed.append(itemID)
        probeSince = t
        return [.probe(itemID: itemID)]
    }

    /// The voice confirmed the probe by their words (`holdForWords`): it is a hold now.
    public mutating func probeConfirmed() {
        probeSince = nil
        probeWaits.removeAll()
    }

    /// An item left to its words (`deferToWords`) was decided by them (the user's
    /// or her echo): a probe no longer waits for it.
    public mutating func wordsDecided(itemID: String) { probeWaits.remove(itemID) }

    /// A probe is on: her voice is paused while the ear listens (`.probe`).
    public var isProbing: Bool { probeSince != nil }

    /// Seconds of frames in the window that hold a voice that isn't hers:
    /// `pitched` near-end frames (over her loud echo: bands she doesn't explain,
    /// at a pitch she isn't speaking at), and `unexplained` voice-shaped bands her
    /// echo model doesn't explain (her own mis-predicted echo can do that too).
    private func voiceHint(from a: Double, to b: Double) -> (pitched: Double, unexplained: Double) {
        var p = 0.0, u = 0.0
        for f in frames.reversed() {
            if f.t < a { break }
            guard f.t <= b else { continue }
            if judge(f).pitched { p += f.dt }
            if f.her && !f.herOnset && f.rawVoiced && f.spectralNear { u += f.dt }
        }
        return (p, u)
    }

    /// Seconds of voice-like sound in the window that her voice can't be (out of
    /// her playback and its tail): someone else's, however soft.
    private func voiceAfterHer(from a: Double, to b: Double) -> Double {
        var v = 0.0
        for f in frames.reversed() {
            if f.t < a { break }
            guard f.t <= b, !f.her, f.rawVoiced, f.voiceLike else { continue }
            v += f.dt
        }
        return v
    }

    // MARK: Sounds

    /// Classifier results; `window` is the host-time span of the audio when known.
    /// Her own playback (and its tail) is never reported as a sound; while she
    /// plays, only the user's laugh / applause clearly above her echo gets through.
    public mutating func classified(_ results: [(identifier: String, confidence: Double)],
                                    window: ClosedRange<Double>? = nil, at t: Double) -> [Action] {
        let loudness = frames.reversed().prefix { t - $0.t <= Self.soundLoudnessWindow }.map(\.db).max() ?? vad.noiseFloorDB
        var candidates = Array(results.prefix(3))
        if candidates.contains(where: {
            let k = SoundCatalog.kind(of: $0.identifier)
            return (k == .laughter || k == .applause) && $0.confidence >= 0.4
        }) {
            lastSocialSoundAt = t                         // no local-only barge-in on a laugh
        }
        if speaking {
            guard aecActive else { return [] }
            let bar = barge.bar(floorDB: vad.noiseFloorDB, ownSpeechLevel: ownLevelNow(at: t)) + Self.socialOverSpeechMarginDB
            guard loudness >= bar else { return [] }
            candidates = candidates.filter {
                let k = SoundCatalog.kind(of: $0.identifier)
                return k == .laughter || k == .applause
            }
        } else if let window {
            let ownStart = stretchStart - Self.ownVoiceGuard
            let ownEnd = playbackEnd + Self.ownVoiceGuard + outputLatency
            if window.upperBound > ownStart && window.lowerBound < ownEnd { return [] }
        } else if t - playbackEnd < Self.ownVoiceTail + outputLatency {
            return []
        }
        for r in candidates {
            if let s = filter.evaluate(identifier: r.identifier, confidence: r.confidence,
                                       loudnessDB: loudness, ambientDB: vad.noiseFloorDB, at: t) {
                return [.emit(.sound(s))]
            }
        }
        return []
    }

    // MARK: Internals

    /// When her echo has certainly left the room.
    private var tailEnd: Double { playbackEnd + outputLatency + Self.echoTail }

    /// After she stopped, the user's voice must reach this (dBFS) to count inside
    /// her echo tail: clearly above the echo she left, and real voice.
    private var postBar: Double {
        max(endEchoDB + Self.postEchoMarginDB, vad.noiseFloorDB + vad.thresholdAboveFloor, vad.absoluteMinDB)
    }

    /// Her voice may be in the microphone: playing, or within the echo tail of a
    /// stretch that was not cut by the user.
    private func herTime(at t: Double) -> Bool {
        speaking || (!lastStretchBarged && t < tailEnd)
    }

    private func ownLevelNow(at t: Double) -> Double {
        t - lastLevelAt <= Self.levelStale ? ownLevel : 0
    }

    /// The microphone in 10 ms bins for the echo model.
    private mutating func feedEcho(_ samples: [Float], at t: Double, duration dt: Double) {
        let n = max(1, Int((dt / EchoReference.bin).rounded()))
        let size = samples.count / n
        guard size > 0 else { return }
        let floorE = pow(10, roomFloorDB / 10)
        for k in 0..<n {
            let lo = k * size, hi = k == n - 1 ? samples.count : lo + size
            var e = 0.0
            for i in lo..<hi { let d = Double(samples[i]); e += d * d }
            echo.addMic(energy: e / Double(hi - lo), floor: floorE, at: t - Double(n - 1 - k) * dt / Double(n))
        }
    }

    /// Share of the frame's energy below ~1 kHz (one-pole low-pass).
    static func lowBandShare(_ x: [Float], sampleRate: Double) -> Double {
        guard !x.isEmpty, sampleRate > 0 else { return 0 }
        let a = 1 - exp(-2 * .pi * voiceBandHz / sampleRate)
        var y = 0.0, low = 0.0, all = 0.0
        for v in x {
            let d = Double(v)
            y += a * (d - y)
            low += y * y
            all += d * d
        }
        return all > 0 ? min(low / all, 1) : 0
    }

    /// Pitched near-end voice in the window of a pending onset (from a little
    /// before the server's onset to its end, or now).
    private func nearEndEvidence(for itemID: String, arrivedAt: Double, at t: Double, need: Double) -> Bool {
        let times = items[itemID]
        let from = max((times?.onset ?? arrivedAt - 0.3) - 0.3, resumedAt)
        let to = (times?.end ?? t) + 0.1
        let v = nearEndVoice(from: from, to: to)
        return v.all >= need - 1e-9 && v.pitched >= Self.nearEndPitched - 1e-9
    }

    private mutating func configureBarge() {
        echo.prior = aecActive ? Self.echoPriorAEC : Self.echoPriorNoAEC
        let base = BargeInDetector()
        let extra = aecActive ? 0 : Self.noAECMarginDB
        barge.minAboveFloorDB = base.minAboveFloorDB + extra
        barge.minDB = base.minDB + extra
    }

    /// Decides pending onsets. `final`: that item's speech has stopped.
    private mutating func decide(at t: Double, final: String?) -> [Action] {
        guard !pending.isEmpty else { return [] }
        var actions: [Action] = []
        var keep: [Pending] = []
        for p in pending {
            let isFinal = p.itemID == final
            // Sustained local evidence; or the server heard speech too and there is
            // near-end voice in its window (two detectors agree: a short "Wait,").
            let evidence = (evidenceAt.map { max($0, lastAboveBar) >= p.arrivedAt - Self.evidenceLookback } ?? false)
                || (echo.hasReference(at: t)
                    && nearEndEvidence(for: p.itemID, arrivedAt: p.arrivedAt, at: t, need: Self.corroboratedEvidence))
            if evidence {
                evidenceAt = nil
                barge.reset()
                if speaking && !bargedIn {
                    bargedIn = true                       // the user cut this stretch
                    if asideOnly {
                        actions.append(.yieldAside(itemID: p.itemID))
                        actions.append(.acceptOnset(itemID: p.itemID))
                    } else {
                        actions += [.bargeIn(itemID: p.itemID), .emit(.bargeIn)]
                    }
                } else {
                    actions.append(.acceptOnset(itemID: p.itemID))
                }
                serverOpen = isFinal ? nil : p.itemID
                continue
            }
            if soundingAfterTail >= Self.userAfterTail - 1e-9 || (asideOnly && speaking && userHeldFloorAtAside)
                || (speaking && bargedIn) || (!speaking && postRun >= Self.quickAnswer - 1e-9) {
                actions.append(.acceptOnset(itemID: p.itemID))
                serverOpen = isFinal ? nil : p.itemID
                continue
            }
            let waited = t - p.arrivedAt
            // While she plays, an item the server still holds open is never given up
            // on: the user may yet speak inside it (her echo opened it, they talked
            // on). It is decided at its `speech_stopped`.
            let stillOpen = items[p.itemID].map { $0.end == nil } ?? false
            // After she stopped, an item still open waits for its stop (or
            // `openItemAfterTail`): the user may yet talk into it (tv15 p06a).
            let timedOut = speaking ? waited >= Self.decisionTimeout && !stillOpen
                : waited >= Self.decisionTimeout && t >= tailEnd + Self.userAfterTail * 2
                    && (!stillOpen || t >= tailEnd + Self.openItemAfterTail - 1e-9)
            if isFinal || timedOut, nearEndEvidence(for: p.itemID, arrivedAt: p.arrivedAt, at: t, need: Self.nearEndEvidence) {
                // Voice her playback doesn't explain: the user, never deleted as echo.
                evidenceAt = nil
                barge.reset()
                if speaking && !bargedIn {
                    bargedIn = true
                    if asideOnly {
                        actions += [.yieldAside(itemID: p.itemID), .acceptOnset(itemID: p.itemID)]
                    } else {
                        actions += [.bargeIn(itemID: p.itemID), .emit(.bargeIn)]
                    }
                } else {
                    actions.append(.acceptOnset(itemID: p.itemID))
                }
                serverOpen = isFinal ? nil : p.itemID
                continue
            }
            if isFinal || timedOut {
                let times = items[p.itemID]
                let hint = voiceHint(from: max((times?.onset ?? p.arrivedAt - 0.3) - 0.3, resumedAt), to: (times?.end ?? t) + 0.1)
                let afterHer = voiceAfterHer(from: max((times?.onset ?? p.arrivedAt - 0.3) - 0.3, resumedAt), to: t)
                if hint.pitched >= Self.wordsHint - 1e-9 || hint.unexplained >= Self.wordsHintUnexplained - 1e-9
                    || afterHer >= Self.voiceAfterHer - 1e-9 {
                    // Something of the user may be in it: their words decide.
                    if serverOpen == p.itemID || isFinal { serverOpen = nil }
                    if probeSince != nil { probeWaits.insert(p.itemID) }
                    // Strict (her garbled echo may pass for words she never said) only
                    // with nothing but her echo model's misses to go on. Voice where hers
                    // can't be (after her playback and its tail) is someone else's: their
                    // words are judged as words (tune 10, T9-2: "Are you awake?" 0.47 s
                    // after her reply was deleted as her echo).
                    let strict = hint.pitched < Self.wordsHint - 1e-9 && afterHer < Self.voiceAfterHer - 1e-9
                    actions.append(.deferToWords(itemID: p.itemID, strict: strict))
                    continue
                }
                markRejected(p.itemID)
                actions.append(.rejectEcho(itemID: p.itemID))
                continue
            }
            if !aecActive, speaking, !bargedIn, !asideOnly, probeSince == nil, !probed.contains(p.itemID), probeHint(p, at: t) {
                probed.append(p.itemID)
                if probed.count > 16 { probed.removeFirst(probed.count - 16) }
                probeSince = t
                actions.append(.probe(itemID: p.itemID))
            }
            keep.append(p)
        }
        pending = keep
        return actions
    }

    /// Strong local evidence the server has not reported (yet): a long, continuous,
    /// pitched run of voice above the bar that is still going on.
    private mutating func localOnlyBargeIn(at t: Double) -> [Action] {
        guard speaking, !bargedIn, pending.isEmpty, evidenceAt != nil else { return [] }
        if asideOnly {
            // Talking over her laugh: give way at once.
            evidenceAt = nil
            barge.reset()
            bargedIn = true
            return [.yieldAside(itemID: nil)]
        }
        guard t - lastAboveBar <= Self.runGap + 1e-9,
              t - aboveRunStart >= Self.localOnlyRun - 1e-9,
              Double(aboveRunPitched) >= Self.localOnlyPitched * Double(max(aboveRunFrames, 1)),
              t - lastSocialSoundAt > Self.socialSuppress else { return [] }
        evidenceAt = nil
        bargedIn = true
        return [.bargeIn(itemID: nil), .emit(.bargeIn)]
    }

    private mutating func syncUplink(at t: Double) -> [Action] {
        let woke = wakeOnVoice && t < wakeUntil
        let want = connected && microphone && (listeningEnabled || woke || serverOpen != nil || !pending.isEmpty)
        guard want != uplinkReported else { return [] }
        uplinkReported = want
        return [.uplink(want)]
    }

    private mutating func sync(at t: Double) -> [Action] {
        var actions: [Action] = []
        let open = isListening
        if open != reportedListening {
            reportedListening = open
            if !open { actions.append(.emit(.micLevel(0))) }
            actions.append(.emit(.listening(open)))
        }
        return actions + syncUplink(at: t)
    }

    private mutating func resetTurn() {
        predictor.resetTurn()
        lastPauseEvent = nil
    }

    private mutating func predictTurn(at t: Double) -> [Action] {
        guard predictor.voicedTime > 0, let e = predictor.update(at: t, pauseScale: pauseLearner.scale) else { return [] }
        let start = t - e.pause
        if let p = lastPauseEvent, abs(p.start - start) < 1e-6,
           abs(p.turnEnd - e.turnEnd) < 0.01, abs(p.hesitation - e.hesitation) < 0.01 { return [] }
        lastPauseEvent = (start, e.turnEnd, e.hesitation)
        return [.emit(.pause(turnEnd: e.turnEnd, hesitation: e.hesitation))]
    }

    private mutating func log(_ f: FrameStat) {
        frames.append(f)
        if let first = frames.first, f.t - first.t > Self.frameLogSeconds * 1.25 {
            frames.removeAll { f.t - $0.t > Self.frameLogSeconds }
        }
    }

    private mutating func remember(_ id: String, _ times: ItemTimes) {
        if items[id] == nil { itemOrder.append(id) }
        items[id] = times
        while itemOrder.count > 32 { items[itemOrder.removeFirst()] = nil }
    }

    private mutating func markRejected(_ id: String) {
        probeWaits.remove(id)
        pending.removeAll { $0.itemID == id }
        if serverOpen == id { serverOpen = nil }
        items[id] = nil
        itemOrder.removeAll { $0 == id }
        itemSounds[id] = nil
        guard rejected.insert(id).inserted else { return }
        rejectedOrder.append(id)
        if rejectedOrder.count > 64 { rejected.remove(rejectedOrder.removeFirst()) }
    }

    /// Rate limiter that averages exactly `1/every` Hz when fed faster than that.
    static func due(_ next: inout Double, at t: Double, every interval: Double) -> Bool {
        guard t >= next - 1e-9 else { return false }
        next = max(next + interval, t - interval)
        if next <= t - interval + 1e-9 { next = t + interval }
        return true
    }
}

/// Minimum-statistics noise floor: a low percentile of the last `window` seconds
/// of frame levels. Stationary noise (a fan, a running tap) *is* the floor; brief
/// quiet moments between clinks don't drag it down, and speech (which has gaps)
/// doesn't lift it.
struct NoiseFloorTracker: Sendable {
    static let window = 1.5
    static let percentile = 0.15
    /// Seconds of frames before the estimate is used.
    static let warmUp = 0.6

    private var levels: [(t: Double, db: Double)] = []
    private var span = 0.0
    private(set) var floorDB: Double?

    mutating func add(_ db: Double, at t: Double) {
        guard db.isFinite, t.isFinite else { return }
        if let last = levels.last { span += max(0, t - last.t) }
        levels.append((t, db))
        while let first = levels.first, t - first.t > Self.window {
            levels.removeFirst()
        }
        guard span >= Self.warmUp, levels.count >= 4 else { return }
        let sorted = levels.map(\.db).sorted()
        floorDB = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * Self.percentile))]
    }
}

/// A run of the user's sound that must also hold voice: sounding frames build it,
/// silence lets it decay (at half rate); it counts once it is long enough *and*
/// `pitchedNeeded` of it was pitched, voice-band sound. Real speech has unvoiced
/// consonants between vowels; a tap, a fan or a clink has no voice at all.
struct VoiceRun: Sendable, Equatable {
    static let pitchedNeeded = 0.08

    private(set) var run = 0.0
    private(set) var pitched = 0.0

    mutating func update(sounding: Bool, pitched isPitched: Bool, dt: Double) {
        if sounding || isPitched {
            run += dt
            if isPitched { pitched += dt }
        } else {
            run = max(0, run - dt * 0.5)
            pitched = max(0, pitched - dt * 0.5)
        }
        pitched = min(pitched, run)
    }

    func reached(_ length: Double) -> Bool {
        run >= length - 1e-9 && pitched >= min(Self.pitchedNeeded, length) - 1e-9
    }
}
