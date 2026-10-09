import AVFAudio
import Foundation

/// Dee's mouth: AVSpeechSynthesizer renders into buffers (`write(_:toBufferCallback:)`)
/// that play through the shared engine — player → time-pitch (a subtle robotic
/// sparkle) → main mixer — so voice-processing echo cancellation hears her and
/// can subtract her from the microphone.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onRequested: (@Sendable () -> Void)?
    var onStarted: (@Sendable () -> Void)?
    var onFinished: (@Sendable (_ started: Bool) -> Void)?
    var onLevel: (@Sendable (Double) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// Is the user talking right now? Consulted for deferred speech.
    var userSpeaking: (@Sendable () -> Bool)?

    /// Everything below is confined to `queue`, except what `engineLock` guards.
    private let queue = DispatchQueue(label: "dee.voice.tts", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private var voice: AVSpeechSynthesisVoice?
    private var converter: BufferConverter?

    /// Guards `engine`, `suspended` and every player play / stop / schedule, and is
    /// held by the engine owner around engine start / stop (`withEngineLock`), so the
    /// player is never started on an engine that is being stopped or restarted.
    private let engineLock = NSLock()
    private var engine: AVAudioEngine?
    private var suspended = false

    private var items: [(text: String, style: VoiceStyle)] = []
    private var current: (utterance: AVSpeechUtterance, id: Int)?
    private var nextUtteranceID = 0
    private var playback = PlaybackWatchdog()
    private var active = false
    private var started = false
    private var streamOpen = false
    private var streamStyle = VoiceStyle.standard
    private var chunker = SentenceChunker()
    private var generation = 0
    private var lastStreamActivity = 0.0
    private var stallCheckScheduled = false
    /// Deferred speech waiting for the user to stop talking.
    private var hold: SpeakHold?
    /// A held stream was dropped: ignore its remaining deferred fragments.
    private var droppingHeldStream = false

    /// While a stream is open but silent this long, assume the LLM forgot `endStream`.
    static let streamIdleTimeout = 12.0
    static let holdPollInterval = 0.1

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Engine wiring (call on the engine's control queue before start)

    func attach(to engine: AVAudioEngine) {
        let picked = Self.pickVoice()
        engineLock.lock()
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.pitch = 35        // cents: a hair of lift
        timePitch.overlap = 6       // < 8 adds a faint grain — her robot sparkle
        timePitch.rate = 1
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let db = Level.rmsDB(buffer.firstChannelSamples())
            self?.onLevel?(Level.meter(db, floor: -50, ceiling: -12))
        }
        self.engine = engine
        suspended = false
        engineLock.unlock()
        queue.sync {
            self.voice = picked
            self.converter = BufferConverter(target: format)
        }
    }

    /// Unhooks the player and time-pitch nodes so they can join a new engine
    /// (after a media-services reset the old engine is dead).
    func detach(from engine: AVAudioEngine) {
        engineLock.lock(); defer { engineLock.unlock() }
        player.stop()
        timePitch.removeTap(onBus: 0)
        if player.engine === engine { engine.detach(player) }
        if timePitch.engine === engine { engine.detach(timePitch) }
        if self.engine === engine { self.engine = nil }
    }

    /// Runs an engine start / stop / reconfiguration with player activity excluded.
    func withEngineLock<T>(_ body: () throws -> T) rethrows -> T {
        engineLock.lock(); defer { engineLock.unlock() }
        return try body()
    }

    /// The engine is about to stop or has stopped under us (interruption, route
    /// change): stop the player now, synchronously, so nothing tries to play on a
    /// stopped engine; queued sentence audio is flushed. Call `stop()` to abandon
    /// the rest of the speech and `resume()` once the engine runs again.
    func suspend() {
        engineLock.lock(); defer { engineLock.unlock() }
        suspended = true
        if engine != nil { player.stop() }
    }

    /// The engine runs again: allow playback, and restart the player if audio is queued.
    func resume() {
        engineLock.lock()
        suspended = false
        engineLock.unlock()
        queue.async { [self] in
            guard playback.pending > 0 else { return }
            engineLock.lock(); defer { engineLock.unlock() }
            if let engine, engine.isRunning, !suspended, !player.isPlaying { player.play() }
        }
    }

    static func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let candidates = voices.map { v in
            VoiceCandidate(
                identifier: v.identifier, name: v.name, language: v.language, quality: v.quality.rawValue,
                gender: v.gender == .female ? .female : (v.gender == .male ? .male : .unspecified),
                isNovelty: v.voiceTraits.contains(.isNoveltyVoice),
                isPersonal: v.voiceTraits.contains(.isPersonalVoice))
        }
        let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
        if let best = VoicePicker.best(candidates, preferredLanguage: preferred) {
            return AVSpeechSynthesisVoice(identifier: best.identifier)
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Public-facing (thread-safe)

    /// `deferWhileUserSpeaks`: hold this (initiative) speech until the user has
    /// been quiet for a moment; dropped if they keep talking for `SpeakHold.maxWait`
    /// or if non-deferred speech (a reply) arrives meanwhile.
    func say(_ text: String, style: VoiceStyle, deferWhileUserSpeaks: Bool = false) {
        queue.async { [self] in
            let cleaned = SpeechText.clean(text)
            guard !cleaned.isEmpty else { return }
            guard prepare(deferred: deferWhileUserSpeaks, isStream: false) else { return }
            enqueue([cleaned], style: style)
        }
    }

    func stream(_ fragment: String, style: VoiceStyle, deferWhileUserSpeaks: Bool = false) {
        queue.async { [self] in
            if deferWhileUserSpeaks && droppingHeldStream && streamOpen == false { return }
            guard prepare(deferred: deferWhileUserSpeaks, isStream: true) else { return }
            if !streamOpen {
                streamOpen = true
                chunker.reset()
                if hold == nil { markActive() }
            }
            streamStyle = style
            lastStreamActivity = Self.now()
            enqueue(chunker.append(fragment), style: style)
            scheduleStreamWatchdog()
        }
    }

    func endStream() {
        queue.async { [self] in
            if droppingHeldStream && !streamOpen { droppingHeldStream = false; return }
            guard streamOpen else { return }
            streamOpen = false
            enqueue(chunker.flush(), style: streamStyle)
            checkFinished()
        }
    }

    func stop() {
        queue.async { [self] in stopNow() }
    }

    // MARK: Queue-confined

    /// Applies the defer rules for a new request; false when it must be ignored.
    private func prepare(deferred: Bool, isStream: Bool) -> Bool {
        if !deferred {
            // A reply supersedes held initiative speech; the held stream's remaining
            // (deferred) fragments are ignored until its endStream.
            if hold != nil { dropHeld() }
            return true
        }
        if hold != nil { return true }                       // joins the held speech
        guard !active, userSpeaking?() == true else { return true }
        guard hasEngine else { return true }                 // enqueue reports the error
        hold = SpeakHold(since: Self.now())
        scheduleHoldCheck()
        return true
    }

    private var hasEngine: Bool {
        engineLock.lock(); defer { engineLock.unlock() }
        return engine != nil
    }

    private func dropHeld() {
        let wasStream = streamOpen
        hold = nil
        items.removeAll()
        streamOpen = false
        chunker.reset()
        droppingHeldStream = wasStream
    }

    private func scheduleHoldCheck() {
        queue.asyncAfter(deadline: .now() + Self.holdPollInterval) { [weak self] in
            guard let self, self.hold != nil else { return }
            switch self.hold!.check(userSpeaking: self.userSpeaking?() ?? false, at: Self.now()) {
            case .wait:
                self.scheduleHoldCheck()
            case .drop:
                self.dropHeld()
            case .release:
                self.hold = nil
                guard !self.items.isEmpty || self.streamOpen else { return }
                self.markActive()
                self.synthesizeNext()
            }
        }
    }

    private func stopNow() {
        generation += 1
        items.removeAll()
        current = nil
        playback.reset()
        streamOpen = false
        hold = nil
        droppingHeldStream = false
        chunker.reset()
        synthesizer.stopSpeaking(at: .immediate)
        engineLock.lock()
        if engine != nil { player.stop() }
        engineLock.unlock()
        finish()
    }

    private func enqueue(_ sentences: [String], style: VoiceStyle) {
        guard !sentences.isEmpty else { return }
        guard hasEngine else {
            onError?("Dee's voice isn't started yet.")
            return
        }
        items += sentences.map { ($0, style) }
        guard hold == nil else { return }                    // waiting for the user to finish
        markActive()
        if current == nil { synthesizeNext() }
    }

    private func markActive() {
        guard !active else { return }
        active = true
        onRequested?()
    }

    private func synthesizeNext() {
        guard current == nil, hold == nil else { return }
        guard !items.isEmpty else { checkFinished(); return }
        let item = items.removeFirst()
        let u = AVSpeechUtterance(string: item.text)
        u.voice = voice
        u.pitchMultiplier = item.style.pitch
        u.rate = min(max(item.style.rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        u.volume = item.style.volume
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.04
        u.prefersAssistiveTechnologySettings = false
        nextUtteranceID += 1
        let id = nextUtteranceID
        current = (u, id)
        let gen = generation
        synthesizer.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            let box = UncheckedBox(pcm.frameLength == 0 ? nil : pcm.deepCopy())
            self.queue.async { self.received(box.value, generation: gen, utterance: id) }
        }
    }

    private func received(_ pcm: AVAudioPCMBuffer?, generation gen: Int, utterance id: Int) {
        guard gen == generation, current?.id == id else { return }
        guard let pcm else { utteranceDone(id); return }     // zero-length buffer: synthesis finished
        guard let converted = converter?.convert(pcm) else { return }
        // Check-and-play atomically with respect to engine start / stop.
        engineLock.lock()
        guard let engine, engine.isRunning, !suspended else { engineLock.unlock(); return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.playback.played(at: Self.now())
                self.checkFinished()
            }
        }
        engineLock.unlock()
        playback.scheduled(at: Self.now())
        scheduleStallCheck()
        if !started {
            started = true
            onStarted?()
        }
    }

    /// Backstop: queued audio whose completions never arrive (the engine stopped
    /// under us) must not leave her "speaking" — and deaf — forever.
    private func scheduleStallCheck() {
        guard !stallCheckScheduled else { return }
        stallCheckScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.stallCheckScheduled = false
            guard self.active, self.playback.pending > 0 else { return }
            if self.playback.isStalled(at: Self.now()) {
                self.stopNow()
            } else {
                self.scheduleStallCheck()
            }
        }
    }

    private func utteranceDone(_ id: Int) {
        guard current?.id == id else { return }
        current = nil
        synthesizeNext()
    }

    private func checkFinished() {
        guard active, current == nil, items.isEmpty, playback.pending == 0, !streamOpen else { return }
        finish()
    }

    private func finish() {
        guard active else { return }
        active = false
        let wasStarted = started
        started = false
        onFinished?(wasStarted)
    }

    private func scheduleStreamWatchdog() {
        let gen = generation
        queue.asyncAfter(deadline: .now() + Self.streamIdleTimeout) { [weak self] in
            guard let self, gen == self.generation, self.streamOpen else { return }
            let idle = Self.now() - self.lastStreamActivity
            guard idle >= Self.streamIdleTimeout - 0.05 else { return }
            self.streamOpen = false
            self.enqueue(self.chunker.flush(), style: self.streamStyle)
            self.checkFinished()
        }
    }

    // MARK: AVSpeechSynthesizerDelegate — a second "done" signal in case the
    // zero-length terminal buffer never arrives.

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = UncheckedBox(utterance)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let c = self.current, c.utterance === box.value else { return }
            self.utteranceDone(c.id)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let box = UncheckedBox(utterance)
        queue.async { [weak self] in
            guard let self, let c = self.current, c.utterance === box.value else { return }
            self.utteranceDone(c.id)
        }
    }
}

/// Counts sentence buffers queued on the player and notices when playback stalls
/// (buffers outstanding, none finished for `stallTimeout`).
struct PlaybackWatchdog: Sendable, Equatable {
    var stallTimeout = 3.0
    private(set) var pending = 0
    private var lastProgress = 0.0

    mutating func scheduled(at t: Double) {
        if pending == 0 { lastProgress = t }
        pending += 1
    }

    mutating func played(at t: Double) {
        pending = max(0, pending - 1)
        lastProgress = t
    }

    mutating func reset() { pending = 0 }

    func isStalled(at t: Double) -> Bool {
        pending > 0 && t - lastProgress >= stallTimeout
    }
}

/// Deferred speech: wait while the user talks, release when they stop, give up
/// if they keep going.
struct SpeakHold: Sendable, Equatable {
    enum Decision: Sendable, Equatable { case wait, release, drop }
    static let maxWait = 8.0
    let since: Double

    func check(userSpeaking: Bool, at t: Double) -> Decision {
        if !userSpeaking { return .release }
        return t - since >= Self.maxWait ? .drop : .wait
    }
}
