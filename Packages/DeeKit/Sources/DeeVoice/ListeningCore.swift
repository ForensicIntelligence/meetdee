import Foundation

/// The platform-free heart of `VoiceService`: everything that decides *what
/// happens* (events, half-duplex, barge-in, end of utterance, sound filtering)
/// given microphone frames, transcriber results, classifier results and speech
/// playback state. `VoiceService` only moves audio in and out; this struct is
/// fully unit-tested.
public struct ListeningCore: Sendable {
    public enum Action: Sendable, Equatable {
        case emit(VoiceEvent)
        /// Ask the analyzer to finalize its volatile range.
        case finalizeVolatile
        /// The recognizer has just (re)opened: ignore transcriber results for audio
        /// fed before now, and (on barge-in) feed the pre-roll.
        case recognitionOpened(bargeIn: Bool)
    }

    public var listeningEnabled = true { didSet { if !listeningEnabled { resetTurn() } } }
    public var recognizerReady = false
    public var aecActive = false

    public private(set) var vad = EnergyVAD()
    public private(set) var gate = DuplexGate()
    private var endpoint = EndpointDetector()
    private var prosody = ProsodyAccumulator()
    private var barge = BargeInDetector()
    private var filter = UnexpectedSoundFilter()
    private var predictor = TurnPredictor()
    private var pauseLearner = PauseScaleLearner()
    private var lastPauseEvent: (start: Double, turnEnd: Double, hesitation: Double)?

    /// Predictive end of turn (SELF.md §7.1). When false the endpoint waits the
    /// fixed `TurnPredictor.defaultHold · pauseScale` and no `.pause` events are sent.
    public var turnPredictionEnabled = true {
        didSet { if !turnPredictionEnabled { endpoint.setQuietInterval(baseHold) } }
    }

    /// Per-person pause scale, 0.7…1.6 (1 = typical). Setting it (a stored profile
    /// value when someone is identified, or a +0.1 bump after Dee clipped them)
    /// restarts learning from that value; reading it gives the learned value, which
    /// adapts after every turn with within-turn pauses (EWMA, shrinkage prior).
    public var pauseScale: Double {
        get { pauseLearner.scale }
        set {
            pauseLearner.set(newValue)
            if endpoint.isEmpty || predictor.last == nil { endpoint.setQuietInterval(baseHold) }
        }
    }

    /// The latest pause estimate of the current turn, if any.
    public var turnEstimate: TurnPredictor.Estimate? { predictor.last }

    /// Seconds of quiet the endpoint currently waits for.
    public var quietInterval: Double { endpoint.quietInterval }

    private var baseHold: Double { TurnPredictor.defaultHold * pauseLearner.scale }

    private var reportedListening: Bool?
    private var nextMicEmit = -Double.infinity
    private var nextSpeechLevelEmit = -Double.infinity
    private var ownSpeechLevel = 0.0
    private var lastSpeechEnd = -Double.infinity
    private var lastVoiced = -Double.infinity
    /// Last voiced frame that was the user, not Dee's own voice or its tail.
    private var lastUserVoiced = -Double.infinity
    /// When Dee last asked to speak (start of her own-voice interval).
    private var lastSpeechStart = -Double.infinity
    private var lastPartial = ""
    private var recent: [(t: Double, db: Double)] = []

    public static let micLevelInterval = 0.05      // 20 Hz
    public static let speechLevelInterval = 1.0 / 30
    /// Ignore classifier results this long after Dee stops (her own voice's tail),
    /// when the result's audio window is unknown: one classifier window (1.5 s) plus
    /// the worst analysis delay (~0.4 s), so no window can still contain her voice.
    public static let ownVoiceTail = 1.5 + 0.4
    /// With a known audio window: windows reaching within this of her speech are hers.
    public static let ownVoiceGuard = 0.3
    /// While she speaks (echo cancellation on), laughter / applause must beat the
    /// barge-in bar by this much to count as the user's (her residual echo can't).
    public static let socialOverSpeechMarginDB = 4.0
    /// `userIsSpeaking` stays true this long after the last voiced frame.
    public static let userSpeechHold = 0.6
    public static let soundLoudnessWindow = 1.6

    public init() {}

    /// The recognizer should be fed right now.
    public func isListening(at t: Double) -> Bool {
        listeningEnabled && recognizerReady && gate.isOpen(at: t)
    }

    /// Mean dBFS of the room when nobody is talking.
    public var ambientDB: Double { vad.noiseFloorDB }

    // MARK: Microphone

    public mutating func frame(_ samples: [Float], sampleRate: Double, at t: Double) -> [Action] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let dt = Double(samples.count) / sampleRate
        let db = Level.rmsDB(samples)
        let voiced = vad.process(frameDB: db, frameDuration: dt)
        if voiced {
            lastVoiced = t
            // Without echo cancellation her own voice (and its tail) trips the VAD.
            let ownVoice = gate.speaking ? !gate.bargedIn : t - lastSpeechEnd < gate.resumeDelay
            if !ownVoice { lastUserVoiced = t }
        }
        recent.append((t, db))
        if let first = recent.first, t - first.t > Self.soundLoudnessWindow * 2 {
            recent.removeAll { t - $0.t > Self.soundLoudnessWindow }
        }

        var actions: [Action] = []
        if barge.update(frameDB: db, voiced: voiced, floorDB: vad.noiseFloorDB, ownSpeechLevel: ownSpeechLevel,
                        aecActive: aecActive, speaking: gate.speaking, frameDuration: dt) {
            gate.bargeIn()
            actions.append(.emit(.bargeIn))
        }
        actions += sync(at: t, bargeIn: gate.bargedIn)

        guard isListening(at: t) else { return actions }
        let f0 = prosody.add(frame: samples, sampleRate: sampleRate, voiced: voiced)
        endpoint.voice(voiced, at: t)
        // "Sounding": above the VAD threshold now, not just its hangover.
        let sounding = voiced && db > vad.noiseFloorDB + vad.thresholdAboveFloor && db > vad.absoluteMinDB
        predictor.frame(sounding: sounding, db: db, f0Hz: f0, duration: dt, at: t)
        if Self.due(&nextMicEmit, at: t, every: Self.micLevelInterval) {
            actions.append(.emit(.micLevel(Level.meter(db))))
        }
        // Drop stray noise collected before anyone actually spoke.
        if endpoint.isEmpty, !voiced, t - lastVoiced > 1.5, !prosody.isEmpty {
            prosody.reset()
            predictor.resetTurn()
        }
        actions += predictTurn(at: t)
        actions += checkEndpoint(at: t)
        return actions
    }

    /// Periodic housekeeping when no microphone frames arrive (e.g. no mic).
    public mutating func tick(at t: Double) -> [Action] {
        var actions = sync(at: t, bargeIn: false)
        if isListening(at: t) { actions += predictTurn(at: t) + checkEndpoint(at: t) }
        return actions
    }

    // MARK: Transcriber

    public mutating func transcript(_ text: String, isFinal: Bool, at t: Double) -> [Action] {
        guard isListening(at: t) else { return [] }
        if isFinal { endpoint.final(text, at: t) } else { endpoint.volatile(text, at: t) }
        let now = endpoint.text
        predictor.partial(now, at: t)
        guard !now.isEmpty, now != lastPartial else { return [] }
        lastPartial = now
        return [.emit(.partial(now))]
    }

    // MARK: Speaking

    /// The user is talking right now: the VAD heard their voice in the last
    /// `userSpeechHold` seconds, or the endpoint detector holds words not yet
    /// delivered as `.heard`. Check before Dee starts talking on her own initiative.
    public func userIsSpeaking(at t: Double) -> Bool {
        t - lastUserVoiced <= Self.userSpeechHold || !endpoint.isEmpty
    }

    /// Dee is about to talk: close the recognizer now (before audio starts).
    /// Whatever the user had said so far is delivered as `.heard` rather than lost,
    /// and the analyzer is asked to finalize so no result straddles the pause.
    public mutating func speechRequested(at t: Double) -> [Action] {
        let wasOpen = isListening(at: t)
        if !gate.speaking {
            barge.reset()
            lastSpeechStart = t
        }
        var actions: [Action] = []
        if !endpoint.isEmpty {
            actions.append(deliver(endpoint.text))
        }
        gate.speechRequested()
        resetTurn()
        if wasOpen { actions.append(.finalizeVolatile) }
        return actions + sync(at: t, bargeIn: false)
    }

    public mutating func speakingStarted() -> [Action] {
        [.emit(.speakingStarted)]
    }

    public mutating func speechLevel(_ level: Double, at t: Double) -> [Action] {
        ownSpeechLevel = min(max(level.isFinite ? level : 0, 0), 1)
        guard gate.speaking, Self.due(&nextSpeechLevelEmit, at: t, every: Self.speechLevelInterval) else { return [] }
        return [.emit(.speechLevel(ownSpeechLevel))]
    }

    public mutating func speakingFinished(at t: Double, started: Bool) -> [Action] {
        let wasBargedIn = gate.bargedIn
        gate.speechFinished(at: t)
        barge.reset()
        ownSpeechLevel = 0
        lastSpeechEnd = t
        var actions: [Action] = []
        if started { actions += [.emit(.speechLevel(0)), .emit(.speakingFinished)] }
        actions += sync(at: t, bargeIn: wasBargedIn)
        return actions
    }

    // MARK: Sounds

    /// Classifier results. `window` is the host-time span of audio the result
    /// covers, when known; results whose window overlaps Dee's own speech (plus
    /// `ownVoiceGuard`) are dropped. Without it, everything until `ownVoiceTail`
    /// after she stops is dropped.
    public mutating func classified(_ results: [(identifier: String, confidence: Double)],
                                    window: ClosedRange<Double>? = nil, at t: Double) -> [Action] {
        let loudness = recent.filter { t - $0.t <= Self.soundLoudnessWindow }.map(\.db).max() ?? vad.noiseFloorDB
        var candidates = Array(results.prefix(3))
        if gate.speaking {
            // Only the user's laugh / applause at her punchline, clearly above her echo.
            guard aecActive else { return [] }
            let bar = barge.bar(floorDB: vad.noiseFloorDB, ownSpeechLevel: ownSpeechLevel) + Self.socialOverSpeechMarginDB
            guard loudness >= bar else { return [] }
            candidates = candidates.filter {
                let k = SoundCatalog.kind(of: $0.identifier)
                return k == .laughter || k == .applause
            }
        } else if let window {
            let ownStart = lastSpeechStart - Self.ownVoiceGuard
            let ownEnd = lastSpeechEnd + Self.ownVoiceGuard
            if window.upperBound > ownStart && window.lowerBound < ownEnd { return [] }
        } else if t - lastSpeechEnd < Self.ownVoiceTail {
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

    /// Rate limiter that averages exactly `1/every` Hz when fed faster than that
    /// (it schedules from the previous slot, not from the arrival time).
    static func due(_ next: inout Double, at t: Double, every interval: Double) -> Bool {
        guard t >= next - 1e-9 else { return false }
        next = max(next + interval, t - interval)
        if next <= t - interval + 1e-9 { next = t + interval }   // after a long gap: restart the grid
        return true
    }

    private mutating func sync(at t: Double, bargeIn: Bool) -> [Action] {
        let open = isListening(at: t)
        guard open != reportedListening else { return [] }
        let first = reportedListening == nil
        reportedListening = open
        var actions: [Action] = []
        if open {
            resetTurn()
            lastPartial = ""
            actions.append(.recognitionOpened(bargeIn: bargeIn))
        } else if !first {
            actions.append(.emit(.micLevel(0)))
        }
        actions.append(.emit(.listening(open)))
        return actions
    }

    /// Clears the utterance in progress (endpoint, prosody, turn prediction).
    private mutating func resetTurn() {
        endpoint.reset()
        prosody.reset()
        predictor.resetTurn()
        endpoint.setQuietInterval(baseHold)
    }

    /// At in-turn pauses: estimate end of turn, set the endpoint's hold, emit `.pause`.
    private mutating func predictTurn(at t: Double) -> [Action] {
        guard turnPredictionEnabled, !endpoint.isEmpty || predictor.voicedTime > 0,
              let e = predictor.update(at: t, pauseScale: pauseLearner.scale) else { return [] }
        endpoint.setQuietInterval(e.hold)
        // One event per pause, re-sent only when the estimate actually moves.
        let start = t - e.pause
        if let p = lastPauseEvent, abs(p.start - start) < 1e-6,
           abs(p.turnEnd - e.turnEnd) < 0.01, abs(p.hesitation - e.hesitation) < 0.01 { return [] }
        lastPauseEvent = (start, e.turnEnd, e.hesitation)
        return [.emit(.pause(turnEnd: e.turnEnd, hesitation: e.hesitation))]
    }

    private mutating func checkEndpoint(at t: Double) -> [Action] {
        switch endpoint.check(at: t) {
        case .wait:
            return []
        case .finalizeVolatile:
            return [.finalizeVolatile]
        case .endUtterance(let text):
            return [deliver(text)]
        }
    }

    /// `.heard` for `text` with the prosody collected so far; resets prosody.
    private mutating func deliver(_ text: String) -> Action {
        let p = prosody.prosody(text: text)
        // Voiced time when the VAD caught it; otherwise a typical 2.5 words/s guess.
        let voicedTime = prosody.voicedDuration
        let duration = voicedTime > 0 ? voicedTime : Double(ProsodyAccumulator.wordCount(text)) / 2.5
        prosody.reset()
        pauseLearner.observe(pauses: predictor.endTurn(text: text))
        endpoint.setQuietInterval(baseHold)
        lastPartial = ""
        return .emit(.heard(HeardUtterance(text: text, prosody: p, duration: duration)))
    }
}
