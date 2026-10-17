import AVFAudio
import Foundation
import Synchronization

/// A node set that plays through the graph's engine (Dee's synthesized voice).
/// The graph attaches it before every engine start and detaches it on teardown.
protocol AudioGraphClient: AnyObject, Sendable {
    /// Attach and connect the client's nodes (engine stopped).
    func attach(to engine: AVAudioEngine)
    /// Unhook the nodes so they can join a new engine.
    func detach(from engine: AVAudioEngine)
    /// Run an engine start / stop with the client's player activity excluded.
    func withEngineLock<T>(_ body: () throws -> T) rethrows -> T
    /// The engine stopped (or is about to): stop playing now.
    func suspend()
    /// The engine runs again.
    func resume()
}

/// Dee's one audio graph: an `AVAudioEngine` with voice processing (echo
/// cancellation) that carries both directions, so every sound Dee makes is
/// cancelled from what Dee hears.
///
/// It owns:
/// - the audio session (`.playAndRecord` / `.voiceChat` / `.defaultToSpeaker`) and
///   the engine's whole life: route changes, interruptions (the mic tap is
///   reinstalled), media-services resets, and recovery when the app returns to the
///   foreground (audit C12). After every restart it re-reads whether echo
///   cancellation is really on and the route's output latency, and reports them
///   (`Event.running`, audit C4);
/// - the microphone tap, fanned out to any number of consumers in order, plus a
///   24 kHz PCM16 `capture` with a 2 s pre-roll for the cloud;
/// - `player`, a 24 kHz PCM16 stream player with a jitter buffer and an exact
///   played-milliseconds counter (barge-in truncation);
/// - the injection seam: `inject(_:)` feeds audio at the tap point, and
///   `DEE_VOICE_INJECT` replaces the microphone with prepared audio (Simulator,
///   UI tests, harness).
///
/// `AudioGraph.manual()` builds the same player path in offline manual-rendering
/// mode: `render(frames:)` runs it faster than real time with no hardware (unit
/// tests, the macOS harness).
///
/// Fail-soft: errors are reported as events and nothing here crashes for lack of
/// hardware.
public final class AudioGraph: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// `.voiceChat` session mode (else `.default`) with the microphone.
        public var voiceChatMode = true
        public var preferredIOBufferDuration = 0.02
        /// Feed this audio file or manifest instead of the microphone (`DEE_VOICE_INJECT`).
        public var injection: URL?
        /// Injected audio holds no echo of Dee, so report echo cancellation as on
        /// (`DEE_VOICE_INJECT_AEC=0` to test the half-duplex path).
        public var injectionEchoFree = true

        public init(voiceChatMode: Bool = true, preferredIOBufferDuration: Double = 0.02,
                    injection: URL? = nil, injectionEchoFree: Bool = true) {
            self.voiceChatMode = voiceChatMode
            self.preferredIOBufferDuration = preferredIOBufferDuration
            self.injection = injection
            self.injectionEchoFree = injectionEchoFree
        }

        /// Defaults plus `DEE_VOICE_INJECT` / `DEE_VOICE_INJECT_AEC`.
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            var c = Configuration()
            if let path = env["DEE_VOICE_INJECT"], !path.isEmpty {
                c.injection = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                c.injectionEchoFree = env["DEE_VOICE_INJECT_AEC"] != "0"
            }
            return c
        }
    }

    /// What the running graph is like right now.
    public struct Facts: Sendable, Equatable {
        /// Voice-processing echo cancellation is really on (or injected audio is echo-free).
        public var aecActive: Bool
        /// Microphone (or injection) sample rate; 0 without input.
        public var inputSampleRate: Double
        /// Seconds from render to the speaker (route latency + IO buffer).
        public var outputLatency: Double
        public var injecting: Bool
        /// Output port types, e.g. "Speaker", "BluetoothA2DPOutput".
        public var route: String

        public init(aecActive: Bool, inputSampleRate: Double, outputLatency: Double, injecting: Bool, route: String) {
            self.aecActive = aecActive
            self.inputSampleRate = inputSampleRate
            self.outputLatency = outputLatency
            self.injecting = injecting
            self.route = route
        }
    }

    public enum Event: Sendable, Equatable {
        /// Audio runs (first start or after recovering); the facts were just re-read.
        case running(Facts)
        /// Audio stopped under us (interruption, route change, services reset); the
        /// graph restarts by itself. After a route / configuration change the
        /// stream player just pauses and resumes where it was (nothing is cut).
        case interrupted(String)
        /// An interruption (phone call, Siri) or a media-services reset stopped Dee's
        /// output — not the user. Sent for every such interruption, also when
        /// nothing was playing (`utterance` nil): a reply still being generated
        /// must not play when audio comes back minutes later. When the stream
        /// player's reply was cut, the server must be told what was heard
        /// (`conversation.item.truncate` at `playedMs`). Flushed `.finished` player
        /// events follow as for any flush.
        case playbackCut(utterance: String?, playedMs: Int, why: String)
        case error(String)
    }

    public let configuration: Configuration
    /// Streamed (cloud) speech.
    public let player = PCMStreamPlayer()
    /// The microphone as 24 kHz PCM16 with a 2 s pre-roll; off until enabled.
    public let capture = PCM16Capture()

    /// The owner's event slot. Called from audio / notification / control threads.
    /// Everyone else (the local and the realtime voice share one graph) uses
    /// `addObserver`, so no subscriber unhooks another.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { hooks.withLock { $0.onEvent } }
        set { hooks.withLock { $0.onEvent = newValue } }
    }

    /// Adds an event observer (called after `onEvent`, in the order added); add it
    /// before `start` to see the first `.running`, or read `facts`. Returns its id.
    @discardableResult
    public func addObserver(_ body: @escaping @Sendable (Event) -> Void) -> Int {
        hooks.withLock { h in
            let id = h.nextObserver
            h.nextObserver += 1
            h.observers.append((id, body))
            return id
        }
    }

    public func removeObserver(_ id: Int) {
        hooks.withLock { $0.observers.removeAll { $0.id == id } }
    }

    private struct Hooks {
        var onEvent: (@Sendable (Event) -> Void)?
        var observers: [(id: Int, body: @Sendable (Event) -> Void)] = []
        var nextObserver = 1
        var consumers: [(id: Int, body: @Sendable (AVAudioPCMBuffer, Double) -> Void)] = []
        var nextConsumer = 1
        var clients: [any AudioGraphClient] = []
    }

    private struct Lifecycle {
        var started = false
        var shutDown = false
        var microphone = false
        var inputFormat: UncheckedBox<AVAudioFormat>?
        var facts: Facts?
    }

    private let hooks = Mutex(Hooks())
    private let lifecycle = Mutex(Lifecycle())
    /// Serializes the tap point (mic tap vs. injection) so consumers see one ordered stream.
    private let funnelLock = NSLock()

    private let control = DispatchQueue(label: "dee.voice.graph", qos: .userInitiated)
    private var engine: AVAudioEngine?            // control-queue confined (manual: set once in init)
    private var micInstalled = false              // control-queue confined
    private var observers: [NSObjectProtocol] = []   // per engine
    private var appObservers: [NSObjectProtocol] = []   // for the graph's life (foreground)
    private var retryToken = 0                    // control-queue confined
    private var retryScheduled = false            // control-queue confined
    private var injector: AudioInjector?          // control-queue confined
    private var pollTimer: DispatchSourceTimer?   // control-queue confined

    /// Manual-rendering mode only.
    private let manual: Bool
    private let renderedFrames = Atomic<Int64>(0)   // written by the render caller

    /// Test seam: make the next `n` engine builds fail, and scale retry delays.
    struct TestHooks {
        var failBuilds = 0
        var buildAttempts = 0
        var retryScale = 1.0
    }
    let testHooks = Mutex(TestHooks())

    public init(configuration: Configuration = .fromEnvironment()) {
        self.configuration = configuration
        manual = false
        player.timeline = .shared
    }

    private init(manualSampleRate: Double, channels: AVAudioChannelCount, maximumFrameCount: AVAudioFrameCount,
                 aecActive: Bool, outputLatency: Double) throws {
        configuration = Configuration()
        manual = true
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: manualSampleRate, channels: channels) else {
            throw NSError(domain: "DeeVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad manual format"])
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
        attachPlayer(to: engine)
        engine.prepare()
        try engine.start()
        self.engine = engine
        let latency = outputLatency.isFinite ? max(outputLatency, 0) : 0
        lifecycle.withLock { l in
            l.started = true
            l.facts = Facts(aecActive: aecActive, inputSampleRate: 0, outputLatency: latency, injecting: false, route: "manual")
        }
        player.renderClock = true
        player.outputLatency = latency
        player.clock = { [weak self] in self?.manualNow ?? 0 }
    }

    /// The player path in offline manual-rendering mode: nothing plays, nothing
    /// listens; `render(frames:)` pulls output and `inject(_:)` feeds the tap
    /// point. Events are delivered synchronously after each render.
    ///
    /// Test / harness configuration: `aecActive` and `outputLatency` are the facts
    /// the graph reports (what `CloudVoice` / `EarCore` tune their echo margins
    /// and tails by), as a real route would; `setManualFacts` changes them later.
    public static func manual(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
                              maximumFrameCount: AVAudioFrameCount = 4096,
                              aecActive: Bool = true, outputLatency: Double = 0) throws -> AudioGraph {
        try AudioGraph(manualSampleRate: sampleRate, channels: channels, maximumFrameCount: maximumFrameCount,
                       aecActive: aecActive, outputLatency: outputLatency)
    }

    /// Manual mode only (tests, harness): reports new facts as a route change
    /// would — `.running(facts)` with echo cancellation on/off and the output
    /// latency (`.started` times include it). Returns false outside manual mode.
    @discardableResult
    public func setManualFacts(aecActive: Bool, outputLatency: Double) -> Bool {
        guard manual else { return false }
        let latency = outputLatency.isFinite ? max(outputLatency, 0) : 0
        let facts = lifecycle.withLock { l -> Facts in
            var f = l.facts ?? Facts(aecActive: aecActive, inputSampleRate: 0, outputLatency: latency, injecting: false, route: "manual")
            f.aecActive = aecActive
            f.outputLatency = latency
            l.facts = f
            return f
        }
        player.outputLatency = latency
        emit(.running(facts))
        return true
    }

    /// Back-off before retrying a failed engine start (seconds): 2, 4, 8, then every 30.
    static func retryDelay(attempt: Int) -> Double {
        let delays = [2.0, 4, 8, 30]
        return delays[min(max(attempt, 0), delays.count - 1)]
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Public surface

    /// The latest facts (nil before the first start).
    public var facts: Facts? { lifecycle.withLock { $0.facts } }

    /// Built by `manual()` (offline rendering, no hardware).
    public var isManual: Bool { manual }

    /// The graph's clock in host seconds: `systemUptime` live; in manual mode the
    /// time rendered so far (what `inject` stamps buffers with by default). Every
    /// DeeVoice timestamp for this graph is on this clock.
    public var now: Double { manual ? manualNow : Self.now() }

    /// The microphone's format (nil without a mic or when injecting).
    var inputFormat: AVAudioFormat? { lifecycle.withLock { $0.inputFormat?.value } }

    /// Audio from the tap point, in order, on the audio thread: `(buffer, hostTime)`
    /// where `hostTime` is when its last sample was captured (the input timestamp,
    /// else the arrival time). Keep it quick.
    @discardableResult
    public func addMicConsumer(_ body: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) -> Int {
        hooks.withLock { h in
            let id = h.nextConsumer
            h.nextConsumer += 1
            h.consumers.append((id, body))
            return id
        }
    }

    public func removeMicConsumer(_ id: Int) {
        hooks.withLock { $0.consumers.removeAll { $0.id == id } }
    }

    /// Feeds `buffer` at the microphone tap point, exactly as if the mic had
    /// delivered it (tests, harness, injection). `t`: host time of its last sample.
    public func inject(_ buffer: AVAudioPCMBuffer, at t: Double? = nil) {
        funnel(buffer, at: t ?? (manual ? manualNow : Self.now()))
    }

    /// Adds a node set that plays through this engine. Call before `start`.
    func attachClient(_ client: any AudioGraphClient) {
        hooks.withLock { $0.clients.append(client) }
    }

    /// Configures the session and starts the engine. `microphone`: permission to
    /// record (ignored when injecting, which never uses the mic). Returns the facts,
    /// or nil after emitting `.error`.
    @discardableResult
    public func start(microphone: Bool) async -> Facts? {
        guard !manual else { return facts }
        let proceed = lifecycle.withLock { l -> Bool in
            guard !l.started, !l.shutDown else { return false }
            l.started = true
            l.microphone = microphone
            return true
        }
        guard proceed else { return facts }
        return await withCheckedContinuation { (c: CheckedContinuation<Facts?, Never>) in
            control.async {
                self.observeForeground()
                let facts = self.build(report: true)
                // A failed first build keeps retrying with back-off (and on every
                // return to the foreground); `.running` announces success.
                if facts == nil { self.scheduleRebuild(attempt: 0) }
                c.resume(returning: facts)
            }
        }
    }

    /// Stops everything for good.
    public func shutdown() {
        let first = lifecycle.withLock { l -> Bool in
            defer { l.shutDown = true }
            return !l.shutDown
        }
        guard first else { return }
        player.flush()
        capture.isEnabled = false
        guard !manual else {
            engine?.stop()
            return
        }
        control.sync {
            teardown()
            for o in appObservers { NotificationCenter.default.removeObserver(o) }
            appObservers.removeAll()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    /// Makes sure audio runs (call when the app becomes active, or when Dee should
    /// listen again): restarts a stopped engine, rebuilds a missing one.
    public func ensureRunning() {
        guard !manual else { return }
        control.async { [self] in
            // A retry is already on its way; don't start a second chain.
            guard lifecycle.withLock({ $0.started && !$0.shutDown }), !retryScheduled else { return }
            if let engine {
                if !engine.isRunning { restart(attempt: 0) }
            } else {
                rebuild(attempt: 0)
            }
        }
    }

    // MARK: Manual rendering

    private var manualNow: Double { Double(renderedFrames.load(ordering: .acquiring)) / manualRate }
    private var manualRate: Double { max(engine?.manualRenderingFormat.sampleRate ?? 48_000, 1) }

    /// Manual mode: renders `frames` of output (the engine's manual format) and
    /// then delivers the player's events. Throws outside manual mode.
    public func render(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard manual, let engine else {
            throw NSError(domain: "DeeVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: "render(frames:) needs AudioGraph.manual()"])
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else {
            throw NSError(domain: "DeeVoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "no buffer"])
        }
        let status = try engine.renderOffline(frames, to: out)
        guard status == .success else {
            throw NSError(domain: "DeeVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "render status \(status.rawValue)"])
        }
        renderedFrames.add(Int64(out.frameLength), ordering: .releasing)
        player.poll(now: manualNow)
        return out
    }

    // MARK: Tap point

    private func funnel(_ buffer: AVAudioPCMBuffer, at t: Double) {
        funnelLock.lock(); defer { funnelLock.unlock() }
        let consumers = hooks.withLock { $0.consumers }
        for c in consumers { c.body(buffer, t) }
        capture.consume(buffer, at: t)
    }

    // MARK: Engine (control queue)

    private var injecting: Bool { configuration.injection != nil }

    private func emit(_ e: Event) {
        let (onEvent, observers) = hooks.withLock { ($0.onEvent, $0.observers) }
        onEvent?(e)
        for o in observers { o.body(e) }
    }

    private var clients: [any AudioGraphClient] { hooks.withLock { $0.clients } }

    /// Runs `body` holding every client's engine lock (fixed order).
    private func withClientLocks<T>(_ list: ArraySlice<any AudioGraphClient>, _ body: () throws -> T) rethrows -> T {
        guard let first = list.first else { return try body() }
        return try first.withEngineLock { try withClientLocks(list.dropFirst(), body) }
    }

    private func attachPlayer(to engine: AVAudioEngine) {
        engine.attach(player.node)
        engine.connect(player.node, to: engine.mainMixerNode, format: PCMStreamPlayer.format)
    }

    private func detachPlayer(from engine: AVAudioEngine) {
        if player.node.engine === engine { engine.detach(player.node) }
    }

    /// Builds and starts a new engine; nil on failure (reported as `.error` when `report`).
    private func build(report: Bool) -> Facts? {
        let simulatedFailure = testHooks.withLock { h -> Bool in
            h.buildAttempts += 1
            guard h.failBuilds > 0 else { return false }
            h.failBuilds -= 1
            return true
        }
        if simulatedFailure {
            if report { emit(.error("Audio engine failed to start: simulated")) }
            return nil
        }
        let microphone = lifecycle.withLock { $0.microphone }
        let useMic = microphone && !injecting
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if useMic {
                try session.setCategory(.playAndRecord, mode: configuration.voiceChatMode ? .voiceChat : .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try? session.setPreferredIOBufferDuration(configuration.preferredIOBufferDuration)
            try session.setActive(true)
        } catch {
            if report { emit(.error("Audio session unavailable: \(error.localizedDescription)")) }
            return nil
        }
        #endif

        let engine = AVAudioEngine()
        var inputFormat: AVAudioFormat?
        if useMic {
            enableVoiceProcessing(engine.inputNode)
            inputFormat = installMicTap(on: engine)
        }
        for c in clients { c.attach(to: engine) }
        attachPlayer(to: engine)
        engine.prepare()
        do {
            try withClientLocks(clients[...]) { try engine.start() }
        } catch {
            if micInstalled { engine.inputNode.removeTap(onBus: 0); micInstalled = false }
            for c in clients { c.detach(from: engine) }
            detachPlayer(from: engine)
            if report { emit(.error("Audio engine failed to start: \(error.localizedDescription)")) }
            return nil
        }
        self.engine = engine
        lifecycle.withLock { $0.inputFormat = inputFormat.map(UncheckedBox.init) }
        observe(engine)
        startInjection()
        startPolling()
        return publishFacts(engine)
    }

    /// Turns on Apple's echo cancellation (no AGC: prosody needs real loudness).
    private func enableVoiceProcessing(_ input: AVAudioInputNode) {
        if !input.isVoiceProcessingEnabled {
            do { try input.setVoiceProcessingEnabled(true) } catch { return }   // simulator / unsupported route
        }
        guard input.isVoiceProcessingEnabled else { return }
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    }

    /// Installs the mic tap with the node's current format; nil without usable input.
    private func installMicTap(on engine: AVAudioEngine) -> AVAudioFormat? {
        let input = engine.inputNode
        if micInstalled { input.removeTap(onBus: 0); micInstalled = false }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            self?.funnel(buffer, at: Self.lastSampleTime(buffer, when: when, arrival: Self.now()))
        }
        micInstalled = true
        return format
    }

    /// Host seconds at which the buffer's last sample was captured: from the tap's
    /// input timestamp when it is valid and sane, else the arrival time (which is
    /// late by the input latency plus up to an IO cycle).
    static func lastSampleTime(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, arrival: Double) -> Double {
        guard when.isHostTimeValid, buffer.format.sampleRate > 0 else { return arrival }
        let t = AVAudioTime.seconds(forHostTime: when.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate
        return t <= arrival + 0.01 && t >= arrival - 0.5 ? t : arrival
    }

    /// Re-reads echo cancellation, input rate and output latency; reports them.
    @discardableResult
    private func publishFacts(_ engine: AVAudioEngine) -> Facts {
        let useMic = lifecycle.withLock { $0.microphone } && !injecting
        let aec = injecting ? configuration.injectionEchoFree : (useMic && engine.inputNode.isVoiceProcessingEnabled)
        let inputRate = injecting ? AudioInjector.sampleRate : (lifecycle.withLock { $0.inputFormat?.value.sampleRate } ?? 0)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        #else
        let latency = engine.outputNode.presentationLatency
        let route = "default"
        #endif
        let facts = Facts(aecActive: aec, inputSampleRate: inputRate,
                          outputLatency: latency.isFinite ? max(latency, 0) : 0, injecting: injecting, route: route)
        lifecycle.withLock { $0.facts = facts }
        player.outputLatency = facts.outputLatency
        emit(.running(facts))
        return facts
    }

    private func startInjection() {
        guard let url = configuration.injection, injector == nil else { return }
        do {
            let inj = try AudioInjector(url: url)
            injector = inj
            inj.start { [weak self] buffer, t in self?.funnel(buffer, at: t) }
        } catch {
            emit(.error("\(error)"))
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dee.voice.player-events", qos: .userInitiated))
        t.schedule(deadline: .now() + 0.02, repeating: 1.0 / 60, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.player.poll() }
        t.resume()
        pollTimer = t
    }

    /// Stops and dismantles the engine (mic tap, observers, nodes) so a new one can be built.
    private func teardown() {
        retryToken &+= 1
        retryScheduled = false
        injector?.stop()
        injector = nil
        pollTimer?.cancel()
        pollTimer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let engine {
            if micInstalled { engine.inputNode.removeTap(onBus: 0) }
            withClientLocks(clients[...]) { engine.stop() }
            for c in clients { c.detach(from: engine) }
            detachPlayer(from: engine)
        }
        engine = nil
        micInstalled = false
    }

    /// Audio stopped under us: stop every client player now, synchronously, so
    /// nothing plays on a stopped engine. The stream player's source node just
    /// stops being pulled and resumes where it was when the engine runs again, so
    /// a route change (AirPods in) pauses Dee's reply rather than ending it. Only a
    /// real interruption or a services reset (`cutStream`) cuts it, reported as
    /// `.playbackCut` (also when nothing was playing) so the server can be told
    /// what was heard and a reply on its way can be cancelled.
    func interrupted(_ why: String, cutStream: Bool) {
        for c in clients { c.suspend() }
        let cut = cutStream ? player.flush() : nil
        emit(.interrupted(why))
        if cutStream { emit(.playbackCut(utterance: cut?.utterance, playedMs: cut?.playedMs ?? 0, why: why)) }
    }

    /// `AVAudioEngineConfigurationChange` (route / format change; the engine
    /// stopped itself): pause, then restart.
    func configurationChanged() {
        interrupted("The audio route changed.", cutStream: false)
        guard !manual else { return }
        control.async { self.restart(attempt: 0) }
    }

    /// Recovery when the app becomes active, for the graph's whole life (also when
    /// the first build failed and no engine exists yet).
    private func observeForeground() {
        guard appObservers.isEmpty else { return }
        // Foreground: iOS may have deactivated the session while suspended without
        // posting `.ended` ("wasSuspended"); make sure the engine runs again.
        appObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.ensureRunning()
        })
    }

    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.configurationChanged()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let self, let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            switch type {
            case .began:
                self.interrupted("Audio was interrupted.", cutStream: true)
            case .ended:
                // Dee is a conversation, not media: always come back (mic tap
                // reinstalled). If the session can't be reactivated yet, the retry
                // back-off and the next foreground take over.
                self.control.async { self.restart(attempt: 0) }
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.interrupted("Audio services were reset; voice restarting.", cutStream: true)
            self.control.async { self.rebuild(attempt: 0) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            // Latency and echo cancellation can change without an engine reconfiguration.
            self.control.async {
                guard let engine = self.engine, engine.isRunning else { return }
                let before = self.facts
                let useMic = self.lifecycle.withLock { $0.microphone } && !self.injecting
                if useMic, !engine.inputNode.isVoiceProcessingEnabled {
                    self.restart(attempt: 0)      // VP dropped: stop, re-enable, restart
                    return
                }
                if before.map({ $0 != self.currentFacts(engine) }) ?? true { self.publishFacts(engine) }
            }
        })
        #endif
    }

    /// Facts as they would be published now (no side effects).
    private func currentFacts(_ engine: AVAudioEngine) -> Facts {
        var f = facts ?? Facts(aecActive: false, inputSampleRate: 0, outputLatency: 0, injecting: injecting, route: "")
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        f.outputLatency = max(session.outputLatency + session.ioBufferDuration, 0)
        f.route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        #endif
        let useMic = lifecycle.withLock { $0.microphone } && !injecting
        if useMic { f.aecActive = engine.inputNode.isVoiceProcessingEnabled }
        return f
    }

    /// Control queue: restart the existing engine (interruption ended, route
    /// change, foreground). Reinstalls the mic tap (the format may have changed)
    /// and turns echo cancellation back on if the route dropped it.
    private func restart(attempt: Int) {
        guard let engine, !lifecycle.withLock({ $0.shutDown }) else { return }
        let useMic = lifecycle.withLock { $0.microphone } && !injecting
        if engine.isRunning, useMic, !engine.inputNode.isVoiceProcessingEnabled {
            // The route dropped echo cancellation under a running engine: stop the
            // players first (never inside the client locks), then rebuild the input.
            interrupted("Echo cancellation went off; restarting audio.", cutStream: false)
            withClientLocks(clients[...]) { engine.stop() }
        }
        do {
            try withClientLocks(clients[...]) {
                if !engine.isRunning {
                    if useMic {
                        enableVoiceProcessing(engine.inputNode)
                        let f = installMicTap(on: engine)
                        lifecycle.withLock { $0.inputFormat = f.map(UncheckedBox.init) }
                    }
                    #if os(iOS)
                    try AVAudioSession.sharedInstance().setActive(true)
                    #endif
                    engine.prepare()
                    try engine.start()
                }
            }
            for c in clients { c.resume() }
            publishFacts(engine)
        } catch {
            if attempt == 0 { emit(.error("Audio engine couldn't restart: \(error.localizedDescription)")) }
            let token = retryToken
            retryScheduled = true
            control.asyncAfter(deadline: .now() + Self.retryDelay(attempt: attempt)) { [weak self] in
                guard let self, token == self.retryToken else { return }
                self.retryScheduled = false
                self.restart(attempt: attempt + 1)
            }
        }
    }

    /// Control queue: after a media-services reset every engine, node and session
    /// setting is invalid — dismantle everything and build a new engine.
    private func rebuild(attempt: Int) {
        guard !lifecycle.withLock({ $0.shutDown }) else { return }
        teardown()
        if build(report: attempt == 0) != nil {
            for c in clients { c.resume() }
            return
        }
        scheduleRebuild(attempt: attempt)
    }

    /// Control queue: try `rebuild` again after the back-off for `attempt`.
    private func scheduleRebuild(attempt: Int) {
        let token = retryToken
        retryScheduled = true
        let delay = Self.retryDelay(attempt: attempt) * testHooks.withLock { $0.retryScale }
        control.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.retryToken else { return }
            self.retryScheduled = false
            self.rebuild(attempt: attempt + 1)
        }
    }
}
