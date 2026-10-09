import AVFAudio
import DeeCore
import Foundation
import Speech
import Synchronization

/// Module namespace for DeeVoice.
public enum DeeVoiceModule {}

/// Dee's ears and voice, hands-free.
///
/// One `AVAudioEngine` carries both directions: the microphone tap feeds the
/// energy VAD / prosody, SpeechAnalyzer (speech-to-text) and SoundAnalysis
/// (sound events); speech synthesis plays through the same engine so iOS voice
/// processing can cancel her own voice from the mic (barge-in).
///
/// Half-duplex by default: recognition pauses while she speaks and resumes
/// ~0.4 s after. All decisions live in `ListeningCore` (pure, unit-tested); this
/// class only moves audio.
///
/// Fail-soft: on macOS, in the simulator, without permissions or without the
/// speech model, `start()` emits `.permission(false, …)` / `.error(…)` and the
/// rest becomes a no-op. Nothing here crashes for lack of hardware.
public final class VoiceService: @unchecked Sendable {
    private let stream: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation
    private let core = Mutex(ListeningCore())
    private let tap = Mutex(TapState())
    private let lifecycle = Mutex(Lifecycle())

    private let control = DispatchQueue(label: "dee.voice.control", qos: .userInitiated)
    private var engine: AVAudioEngine?          // control-queue confined
    private var micInstalled = false            // control-queue confined
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var engineRetryToken = 0             // control-queue confined

    private let speechIn = SpeechInput()
    private let sounds = SoundClassifier()
    private let speechOut = SpeechOutput()

    private struct TapState {
        var slicer = FrameSlicer(frameSize: 640)
        var sampleRate: Double = 0
        var preroll: [UncheckedBox<AVAudioPCMBuffer>] = []
        var prerollSeconds: Double = 0
        /// Barge-in opened the recognizer: the tap thread feeds the pre-roll before
        /// its next buffer (all feeding stays on the tap thread, in order).
        var flushPreroll = false
    }

    private struct Lifecycle {
        var started = false
        var shutDown = false
        var laughVariant = 0
        var microphone = false
        var speech = false
        var inputFormat: UncheckedBox<AVAudioFormat>?
        var recognizerStarting = false
        var recognizerAttempts = 0
        var recognizerRetryPending = false
    }

    static let frameSeconds = 0.04
    static let prerollLimit = 0.7

    /// Back-off before retrying a failed recognizer or audio engine (seconds):
    /// 2, 4, 8, then every 30.
    static func retryDelay(attempt: Int) -> Double {
        let delays = [2.0, 4, 8, 30]
        return delays[min(max(attempt, 0), delays.count - 1)]
    }

    public init() {
        (stream, continuation) = AsyncStream<VoiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        wireComponents()
    }

    /// The event stream. Single consumer: every access returns the same stream.
    public var events: AsyncStream<VoiceEvent> { stream }

    /// The user is talking right now: voice in the last 0.6 s (not Dee's own), or
    /// words heard but not yet delivered as `.heard`. Check before Dee speaks on her
    /// own initiative, so she doesn't talk over someone mid-sentence.
    public var userIsSpeaking: Bool {
        core.withLock { $0.userIsSpeaking(at: Self.now()) }
    }

    /// App gate: false while Dee sleeps / nobody is there. Sound classification
    /// keeps running regardless so Dee can wake to an unexpected noise.
    public var listeningEnabled: Bool {
        get { core.withLock { $0.listeningEnabled } }
        set {
            let actions = core.withLock { c -> [ListeningCore.Action] in
                c.listeningEnabled = newValue
                return c.tick(at: Self.now())
            }
            perform(actions)
        }
    }

    /// Per-person pause scale (0.7…1.6, 1 = typical; SELF.md §7.1). Set it when
    /// someone is identified (their stored `SocialProfile.pauseScale`) or bump it by
    /// +0.1 after Dee clipped them; read it back at turn end to persist what was learned.
    public var pauseScale: Double {
        get { core.withLock { $0.pauseScale } }
        set { core.withLock { $0.pauseScale = newValue } }
    }

    /// Predictive end of turn on/off (on by default). Off = fixed 0.8 s · pauseScale hold, no `.pause` events.
    public var turnPredictionEnabled: Bool {
        get { core.withLock { $0.turnPredictionEnabled } }
        set { core.withLock { $0.turnPredictionEnabled = newValue } }
    }

    // MARK: Lifecycle

    /// Requests microphone + speech permission, configures the audio session,
    /// starts the engine (emits `.ready` as soon as she can speak), then installs
    /// the on-device speech model if needed and starts listening (`.listening(true)`).
    public func start() async {
        let proceed = lifecycle.withLock { l -> Bool in
            guard !l.started, !l.shutDown else { return false }
            l.started = true
            return true
        }
        guard proceed else { return }

        #if os(iOS)
        let hasMicKey = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        let hasSpeechKey = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        let mic = hasMicKey ? await AVAudioApplication.requestRecordPermission() : false
        let speech = (mic && hasSpeechKey) ? await Self.requestSpeechAuthorization() : false
        emit(.permission(microphone: mic, speech: speech))
        if !hasMicKey { emit(.error("Missing NSMicrophoneUsageDescription; Dee can't listen.")) }

        lifecycle.withLock { l in
            l.microphone = mic
            l.speech = speech
        }
        let setup = await withCheckedContinuation { (c: CheckedContinuation<EngineSetup, Never>) in
            control.async { c.resume(returning: self.buildEngine(microphone: mic)) }
        }
        if let message = setup.error {
            emit(.error(message))
            return
        }
        applied(setup)
        startTimer()
        emit(.ready)
        await startRecognizer()
        #else
        // macOS (tests, previews): the live audio path is iOS-only. Fail soft.
        emit(.permission(microphone: false, speech: false))
        emit(.error("Live voice is only available on iPhone and iPad."))
        #endif
    }

    public func shutdown() {
        let first = lifecycle.withLock { l -> Bool in
            defer { l.shutDown = true }
            return !l.shutDown
        }
        guard first else { return }
        speechOut.stop()
        speechIn.stop()
        sounds.stop()
        control.sync {
            timer?.cancel()
            timer = nil
            teardownEngine()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        continuation.finish()
    }

    // MARK: Speaking

    public func say(_ text: String, style: VoiceStyle) {
        guard !isShutDown else { return }
        speechOut.say(text, style: style)
    }

    /// `deferWhileUserSpeaks`: for speech on Dee's own initiative. If the user is
    /// talking, it waits until they have been quiet for ~0.6 s; it is dropped if they
    /// keep talking for 8 s, or if non-deferred speech (a reply) arrives meanwhile.
    public func say(_ text: String, style: VoiceStyle, deferWhileUserSpeaks: Bool) {
        guard !isShutDown else { return }
        speechOut.say(text, style: style, deferWhileUserSpeaks: deferWhileUserSpeaks)
    }

    /// Incremental text from the LLM; spoken sentence by sentence as it arrives.
    public func stream(_ fragment: String, style: VoiceStyle) {
        guard !isShutDown else { return }
        speechOut.stream(fragment, style: style)
    }

    /// `stream` with the same deferral rule as `say(_:style:deferWhileUserSpeaks:)`
    /// (pass the same flag for every fragment of one reply).
    public func stream(_ fragment: String, style: VoiceStyle, deferWhileUserSpeaks: Bool) {
        guard !isShutDown else { return }
        speechOut.stream(fragment, style: style, deferWhileUserSpeaks: deferWhileUserSpeaks)
    }

    public func endStream() {
        speechOut.endStream()
    }

    public func stopSpeaking() {
        speechOut.stop()
    }

    /// A short spoken laugh ("Hehe!", "Hahaha!") — for the mind's reflexes: she can
    /// laugh at a joke even when her mood is low. `intensity` 0…1.
    public func laugh(intensity: Double = 0.6, age: Double? = nil, energy: Double = 0.7) {
        guard !isShutDown else { return }
        let variant = lifecycle.withLock { l -> Int in
            l.laughVariant &+= 1
            return l.laughVariant
        }
        speechOut.say(Laughter.phrase(intensity: intensity, variant: variant),
                      style: Laughter.style(intensity: intensity, age: age, energy: energy))
    }

    // MARK: Internals

    private var isShutDown: Bool { lifecycle.withLock { $0.shutDown } }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func emit(_ event: VoiceEvent) { continuation.yield(event) }

    private func perform(_ actions: [ListeningCore.Action]) {
        for action in actions {
            switch action {
            case .emit(let e):
                emit(e)
            case .finalizeVolatile:
                speechIn.finalizeVolatile()
            case .recognitionOpened(let bargeIn):
                speechIn.discardResultsBeforeNow()
                // Never feed from here (this can run on the timer, the TTS queue or a
                // results task): the tap thread flushes the pre-roll itself.
                tap.withLock { st in
                    if bargeIn {
                        st.flushPreroll = true
                    } else {
                        st.flushPreroll = false
                        st.preroll.removeAll()
                        st.prerollSeconds = 0
                    }
                }
            }
        }
    }

    private func wireComponents() {
        speechIn.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            self.lifecycle.withLock { $0.recognizerAttempts = 0 }   // healthy again
            self.perform(self.core.withLock { $0.transcript(text, isFinal: isFinal, at: Self.now()) })
        }
        speechIn.onError = { [weak self] message in
            guard let self else { return }
            self.emit(.error(message))
            self.speechIn.stop()
            self.perform(self.core.withLock { c in
                c.recognizerReady = false
                return c.tick(at: Self.now())
            })
            self.scheduleRecognizerRetry()
        }
        sounds.onResult = { [weak self] results, window in
            guard let self else { return }
            self.perform(self.core.withLock { $0.classified(results, window: window, at: Self.now()) })
        }
        sounds.onError = { [weak self] message in self?.emit(.error(message)) }
        speechOut.onRequested = { [weak self] in
            guard let self else { return }
            self.perform(self.core.withLock { $0.speechRequested(at: Self.now()) })
        }
        speechOut.onStarted = { [weak self] in
            guard let self else { return }
            self.perform(self.core.withLock { $0.speakingStarted() })
        }
        speechOut.onFinished = { [weak self] started in
            guard let self else { return }
            self.perform(self.core.withLock { $0.speakingFinished(at: Self.now(), started: started) })
        }
        speechOut.onLevel = { [weak self] level in
            guard let self else { return }
            self.perform(self.core.withLock { $0.speechLevel(level, at: Self.now()) })
        }
        speechOut.onError = { [weak self] message in self?.emit(.error(message)) }
        speechOut.userSpeaking = { [weak self] in self?.userIsSpeaking ?? false }
    }

    // MARK: Recognizer (re)start

    /// Starts the recognizer if permitted; on failure retries with back-off.
    private func startRecognizer() async {
        let format = lifecycle.withLock { l -> UncheckedBox<AVAudioFormat>? in
            guard !l.shutDown, l.microphone, l.speech, !l.recognizerStarting, let f = l.inputFormat else { return nil }
            l.recognizerStarting = true
            return f
        }
        guard let format else { return }
        defer { lifecycle.withLock { $0.recognizerStarting = false } }
        do {
            try await speechIn.start(naturalFormat: format.value)
            guard !isShutDown else { speechIn.stop(); return }
            perform(core.withLock { c in
                c.recognizerReady = true
                return c.tick(at: Self.now())
            })
        } catch is CancellationError {
            return
        } catch let failure as SpeechInput.Failure where failure.isPermanent {
            emit(.error("Speech recognition unavailable: \(failure)"))
        } catch {
            emit(.error("Speech recognition unavailable: \(error)"))
            scheduleRecognizerRetry()
        }
    }

    private func scheduleRecognizerRetry() {
        let delay = lifecycle.withLock { l -> Double? in
            guard !l.shutDown, !l.recognizerRetryPending else { return nil }
            l.recognizerRetryPending = true
            defer { l.recognizerAttempts += 1 }
            return Self.retryDelay(attempt: l.recognizerAttempts)
        }
        guard let delay else { return }
        control.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lifecycle.withLock { $0.recognizerRetryPending = false }
            guard !self.isShutDown, !self.core.withLock({ $0.recognizerReady }) else { return }
            Task { await self.startRecognizer() }
        }
    }

    /// Microphone tap (audio tap thread).
    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        let t = Self.now()
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        let samples = buffer.firstChannelSamples()
        let frames = tap.withLock { st -> [[Float]] in
            if st.sampleRate != rate {
                st.sampleRate = rate
                st.slicer = FrameSlicer(frameSize: max(1, Int(rate * Self.frameSeconds)))
            }
            return st.slicer.push(samples)
        }
        let frameDuration = Self.frameSeconds
        let (actions, listening, holdPreroll) = core.withLock { c -> ([ListeningCore.Action], Bool, Bool) in
            var all: [ListeningCore.Action] = []
            for (k, f) in frames.enumerated() {
                let ft = t - Double(frames.count - 1 - k) * frameDuration
                all += c.frame(f, sampleRate: rate, at: ft)
            }
            return (all, c.isListening(at: t), c.gate.speaking && c.aecActive && c.listeningEnabled && c.recognizerReady)
        }
        perform(actions)
        if listening {
            let preroll = tap.withLock { st -> [UncheckedBox<AVAudioPCMBuffer>] in
                guard st.flushPreroll else { return [] }
                defer { st.flushPreroll = false; st.preroll.removeAll(); st.prerollSeconds = 0 }
                return st.preroll
            }
            for b in preroll { speechIn.feed(b.value) }
            speechIn.feed(buffer)
        } else if holdPreroll, let copy = buffer.deepCopy() {
            let seconds = Double(buffer.frameLength) / rate
            tap.withLock { st in
                st.preroll.append(UncheckedBox(copy))
                st.prerollSeconds += seconds
                while st.prerollSeconds > Self.prerollLimit, let first = st.preroll.first {
                    st.prerollSeconds -= Double(first.value.frameLength) / max(first.value.format.sampleRate, 1)
                    st.preroll.removeFirst()
                }
            }
        }
        sounds.analyze(buffer, hostTime: t)
    }

    private func startTimer() {
        control.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.control)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.perform(self.core.withLock { $0.tick(at: Self.now()) })
            }
            timer.resume()
            self.timer = timer
        }
    }

    // MARK: Engine (control queue)

    private struct EngineSetup: @unchecked Sendable {
        var error: String?
        var echoCancellation = false
        var inputFormat: AVAudioFormat?
    }

    /// Records a freshly built engine's facts (echo cancellation, mic format).
    private func applied(_ setup: EngineSetup) {
        lifecycle.withLock { l in
            if let f = setup.inputFormat { l.inputFormat = UncheckedBox(f) }
        }
        perform(core.withLock { c in
            c.aecActive = setup.echoCancellation
            return c.tick(at: Self.now())
        })
    }

    /// Control queue: stops and dismantles the engine (mic tap, observers, player
    /// nodes) so a new one can be built.
    private func teardownEngine() {
        engineRetryToken &+= 1
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let engine {
            if micInstalled { engine.inputNode.removeTap(onBus: 0) }
            speechOut.withEngineLock { engine.stop() }
            speechOut.detach(from: engine)
        }
        engine = nil
        micInstalled = false
    }

    #if os(iOS)
    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
    }

    private func buildEngine(microphone: Bool) -> EngineSetup {
        var setup = EngineSetup()
        let session = AVAudioSession.sharedInstance()
        do {
            if microphone {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try? session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            setup.error = "Audio session unavailable: \(error.localizedDescription)"
            return setup
        }

        let engine = AVAudioEngine()
        if microphone {
            let input = engine.inputNode
            do {
                try input.setVoiceProcessingEnabled(true)
                setup.echoCancellation = input.isVoiceProcessingEnabled
            } catch {
                setup.echoCancellation = false   // simulator / unsupported route: half-duplex only
            }
            if setup.echoCancellation {
                // Keep real loudness for prosody (AGC would flatten shouting and whispering).
                input.isVoiceProcessingAGCEnabled = false
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            setup.inputFormat = installMicTap(on: engine)
        }
        speechOut.attach(to: engine)
        engine.prepare()
        do {
            try speechOut.withEngineLock { try engine.start() }
        } catch {
            if micInstalled { engine.inputNode.removeTap(onBus: 0); micInstalled = false }
            speechOut.detach(from: engine)
            setup.error = "Audio engine failed to start: \(error.localizedDescription)"
            return setup
        }
        self.engine = engine
        observeSession(engine: engine, microphone: microphone)
        return setup
    }

    /// Installs the mic tap with the node's current format; nil when there is no usable input.
    private func installMicTap(on engine: AVAudioEngine) -> AVAudioFormat? {
        let input = engine.inputNode
        if micInstalled { input.removeTap(onBus: 0); micInstalled = false }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        micInstalled = true
        return format
    }

    private func observeSession(engine: AVAudioEngine, microphone: Bool) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            // The engine has stopped under us: abandon the sentence in flight now
            // (its queued buffers will never report back) and restart.
            self.abandonSpeech()
            self.control.async { self.restartEngine(reinstallMic: microphone, attempt: 0) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let self, let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            switch type {
            case .began:
                self.abandonSpeech()
            case .ended:
                self.control.async { self.restartEngine(reinstallMic: false, attempt: 0) }
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.emit(.error("Audio services were reset; voice restarting."))
            self.abandonSpeech()
            self.control.async { self.rebuildEngine(attempt: 0) }
        })
    }

    /// Stop the player synchronously, then drop all queued speech (emits
    /// `.speakingFinished` if she was talking, reopening the recognizer).
    private func abandonSpeech() {
        speechOut.suspend()
        speechOut.stop()
    }

    /// Control queue: restart the existing engine (interruption ended, route change).
    private func restartEngine(reinstallMic: Bool, attempt: Int) {
        guard let engine, !isShutDown else { return }
        if reinstallMic, let f = installMicTap(on: engine) {
            lifecycle.withLock { $0.inputFormat = UncheckedBox(f) }
        }
        do {
            try speechOut.withEngineLock {
                if !engine.isRunning {
                    try AVAudioSession.sharedInstance().setActive(true)
                    engine.prepare()
                    try engine.start()
                }
            }
            speechOut.resume()
        } catch {
            if attempt == 0 { emit(.error("Audio engine couldn't restart: \(error.localizedDescription)")) }
            let token = engineRetryToken
            control.asyncAfter(deadline: .now() + Self.retryDelay(attempt: attempt)) { [weak self] in
                guard let self, token == self.engineRetryToken else { return }
                self.restartEngine(reinstallMic: reinstallMic, attempt: attempt + 1)
            }
        }
    }

    /// Control queue: after a media-services reset every engine, node and session
    /// setting is invalid — dismantle everything and build a new engine.
    private func rebuildEngine(attempt: Int) {
        guard !isShutDown else { return }
        teardownEngine()
        let microphone = lifecycle.withLock { $0.microphone }
        let setup = buildEngine(microphone: microphone)
        if let message = setup.error {
            if attempt == 0 { emit(.error(message)) }
            let token = engineRetryToken
            control.asyncAfter(deadline: .now() + Self.retryDelay(attempt: attempt)) { [weak self] in
                guard let self, token == self.engineRetryToken else { return }
                self.rebuildEngine(attempt: attempt + 1)
            }
            return
        }
        applied(setup)
        speechOut.resume()
    }
    #endif
}
