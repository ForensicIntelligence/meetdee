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
        /// was sound her echo model didn't explain (no other voice's pitch) — the
        /// words must be clearly not hers.
        case deferToWords(itemID: String, strict: Bool)
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
    /// Longest wait for evidence on a server onset while she keeps playing.
    public static let decisionTimeout = 1.5
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
    /// The user's speech item the server has open (and that is not echo).
    public private(set) var serverOpen: String?

    private struct ItemTimes: Sendable {
        var onset: Double
        var end: Double?
    }
    private var items: [String: ItemTimes] = [:]
    private var itemOrder: [String] = []
    private var rejected: Set<String> = []
    private var rejectedOrder: [String] = []

    private var lastUserVoiced = -Double.infinity
    /// Last frame of pitched user voice once `speechRun` of it was heard.
    private var lastUserSpeech = -Double.infinity
    private var speechRunNow = VoiceRun()
    private var lastUserSounding = -Double.infinity
    private var lastVoiced = -Double.infinity

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
        if userVoiced, speechRunNow.reached(Self.speechRun) { lastUserSpeech = t }
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
            times.end = end.map { min($0, t) } ?? t - 0.2
            items[itemID] = times
        }
        var actions = decide(at: t, final: itemID)
        if serverOpen == itemID { serverOpen = nil }
        if !rejected.contains(itemID) {
            // Their turn is over: learn its pauses, start the next turn clean.
            pauseLearner.observe(pauses: predictor.endTurn(text: ""))
            lastPauseEvent = nil
        }
        actions += syncUplink(at: t)
        return actions
    }

    /// The server's transcript of a user item: `.heard` with local prosody over
    /// the item's audio window. Nothing for echo, unknown items or empty text.
    public mutating func serverTranscript(itemID: String, text: String, at t: Double) -> [Action] {
        latest = max(latest, t)
        guard !rejected.contains(itemID) else { return [] }
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
            let timedOut = speaking ? waited >= Self.decisionTimeout && !stillOpen
                : waited >= Self.decisionTimeout && t >= tailEnd + Self.userAfterTail * 2
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
                if hint.pitched >= Self.wordsHint - 1e-9 || hint.unexplained >= Self.wordsHintUnexplained - 1e-9 {
                    // Something of the user may be in it: their words decide.
                    if serverOpen == p.itemID || isFinal { serverOpen = nil }
                    actions.append(.deferToWords(itemID: p.itemID, strict: hint.pitched < Self.wordsHint - 1e-9))
                    continue
                }
                markRejected(p.itemID)
                actions.append(.rejectEcho(itemID: p.itemID))
                continue
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
        pending.removeAll { $0.itemID == id }
        if serverOpen == id { serverOpen = nil }
        items[id] = nil
        itemOrder.removeAll { $0 == id }
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
