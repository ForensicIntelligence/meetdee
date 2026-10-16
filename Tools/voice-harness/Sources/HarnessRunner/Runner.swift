import AVFAudio
import DeeRealtime
import DeeVoice
import DeeWake
import Foundation
import HarnessCore
import Synchronization

/// Running total of estimated spend across a whole harness run.
public final class SpendGuard: @unchecked Sendable {
    public let pricing: Pricing
    public let maxUSD: Double
    private let state = Mutex<(responses: Double, transcription: Double)>((0, 0))

    public init(pricing: Pricing, maxUSD: Double) {
        self.pricing = pricing
        self.maxUSD = maxUSD
    }

    public func add(_ usage: RunRecord.UsageRecord) {
        let d = pricing.dollars(usage)
        state.withLock { $0.responses += d }
    }

    public func addTranscription(seconds: Double) {
        let d = seconds / 60 * pricing.transcribePerMinute
        state.withLock { $0.transcription += d }
    }

    public var spent: Double { state.withLock { $0.responses + $0.transcription } }
    public var exceeded: Bool { spent > maxUSD }
}

/// Where the session's socket goes.
public enum HarnessConnection: Sendable {
    /// The real API with the key (ephemeral `ek_` minted like the app).
    case live(RealtimeAuth)
    /// A local endpoint (trace replay server); no key involved.
    case local(endpoint: URL)
    /// Anything else (tests: a `FakeSocketFactory`).
    case custom(credentials: RealtimeCredentialProvider, socketFactory: RealtimeSocketFactory)
    /// 0.6 mode 1 with every call taped (W2/W3): the key, the real network.
    case openAI(key: String, ttlSeconds: Int)
    /// 0.6 provider modes (`--provider lan-brain|lan`, or a mock / failing network in
    /// tests): built by the runner on a taped transport (`TransportTape`).
    case provider(HarnessProviderBuilder)
}

/// Builds a provider's session parts on the transport the runner hands it (taped).
public struct HarnessProviderBuilder: Sendable {
    /// `ProviderMode.rawValue` (`openAI`, `lanBrainOpenAIVoice`, `lanEverything`).
    public var mode: String
    /// - Parameters: the tape to build every Transport on; the brain's session config
    ///   (`base`, after `HarnessBrain.configure`); the wake phrase (a hearing keyword).
    public var build: @Sendable (_ tape: TransportTape, _ base: RealtimeSessionConfig, _ phrase: String) throws -> HarnessProvider
    public init(mode: String, build: @escaping @Sendable (TransportTape, RealtimeSessionConfig, String) throws -> HarnessProvider) {
        self.mode = mode; self.build = build
    }
}

/// What a provider gives the runner's session (from `DeeLocal.ProviderRuntime`).
public struct HarnessProvider: Sendable {
    public var sessionConfig: RealtimeSessionConfig
    public var credentials: RealtimeCredentialProvider
    public var socketFactory: RealtimeSocketFactory
    /// EarCore's per-frame voice evidence, shared with CloudVoice (mode 3 turn detection).
    public var uplink: UplinkActivity?
    /// Local-mode measurements (chat requests, TTFT, gaps…) read at teardown.
    public var stats: (@Sendable () async -> [String: Double])?
    /// Provider problems (hearing, chat, voice), noted in the run record.
    public var problems: AsyncStream<String>?
    public init(sessionConfig: RealtimeSessionConfig, credentials: @escaping RealtimeCredentialProvider,
                socketFactory: @escaping RealtimeSocketFactory, uplink: UplinkActivity? = nil,
                stats: (@Sendable () async -> [String: Double])? = nil, problems: AsyncStream<String>? = nil) {
        self.sessionConfig = sessionConfig; self.credentials = credentials; self.socketFactory = socketFactory
        self.uplink = uplink; self.stats = stats; self.problems = problems
    }
}

public struct RunnerOptions: Sendable {
    public var model = "gpt-realtime-2.1-mini"
    public var voice = "marin"
    /// `<dir>/<scenario>.jsonl` traces (layer 2); nil = none.
    public var traceDirectory: URL?
    /// `<dir>/<scenario>-{mic,dee}.wav` (debug listening); nil = none.
    public var audioDirectory: URL?
    public var classifySounds = true
    public var connectTimeout = 20.0
    public var leadIn = 1.5
    public var replyTimeout = 8.0
    public var gapAfter = 1.0
    /// Echo-only segments are watched this long after her audio ends.
    public var echoTail = 2.5
    /// Longest wait for the room to go quiet after a step.
    public var quietTimeout = 30.0
    public var log: (@Sendable (String) -> Void)?
    /// 0.6 `--wake`: `.alwaysOpen` (default, the tune2 baseline: never DORMANT, asserted)
    /// or `.phrase` (DORMANT until the on-device ear hears `wakePhrase`).
    public var wake: WakeMode = .alwaysOpen
    public var wakePhrase = WakeSuite.defaultPhrase
    /// The ear for `.phrase` (default: the real on-device `OnDeviceWakeEar`).
    public var makeEar: (@Sendable () -> any WakeEar)?
    /// Phrase mode: longest wait for the ear to be listening before the run starts.
    public var earTimeout = 15.0

    public init() {}
}

/// Fixture audio and manifest.
public final class FixtureLibrary: @unchecked Sendable {
    public let manifest: FixtureManifest
    public let directory: URL
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]

    public init(directory: URL) throws {
        self.directory = directory
        manifest = try FixtureManifest.load(directory.appendingPathComponent("manifest.json"))
    }

    public init(manifest: FixtureManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    public func samples(file: String) throws -> [Float] {
        if let s = lock.withLock({ cache[file] }) { return s }
        let audio = try WAV.read(directory.appendingPathComponent(file))
        let s = DSP.resampled(audio.samples, from: audio.sampleRate, to: 24_000)
        lock.withLock { cache[file] = s }
        return s
    }

    /// Preloaded samples (tests).
    public func preload(file: String, samples: [Float]) { lock.withLock { cache[file] = samples } }

    public func utterance(_ id: String) throws -> (FixtureManifest.Utterance, [Float]) {
        guard let u = manifest.utterance(id) else { throw HarnessError("unknown fixture \(id)") }
        return (u, try samples(file: u.file))
    }

    public func bed(_ id: String) throws -> [Float] {
        guard let b = manifest.noise.first(where: { $0.id == id }) else { throw HarnessError("unknown noise bed \(id)") }
        return try samples(file: b.file)
    }

    public func impulse() -> [Float]? {
        guard let ir = manifest.impulseResponses.first else { return nil }
        return try? samples(file: ir.file)
    }
}

public struct HarnessError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Paces a block callback in real time on its own thread (20 ms blocks).
final class AudioLoop: @unchecked Sendable {
    private let running = Mutex(false)
    private let done = DispatchSemaphore(value: 0)
    private let lateResyncs = Mutex(0)

    func start(period: Double, _ block: @escaping @Sendable () -> Void) {
        running.withLock { $0 = true }
        let thread = Thread { [self] in
            var next = ProcessInfo.processInfo.systemUptime
            while self.running.withLock({ $0 }) {
                block()
                next += period
                let now = ProcessInfo.processInfo.systemUptime
                if next > now {
                    Thread.sleep(forTimeInterval: next - now)
                } else if now - next > 0.25 {
                    next = now                      // fell far behind: resync, don't burst
                    self.lateResyncs.withLock { $0 += 1 }
                }
            }
            self.done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "voice-harness.audio"
        thread.start()
    }

    func stop() {
        let was = running.withLock { r -> Bool in defer { r = false }; return r }
        if was { done.wait() }
    }

    var resyncs: Int { lateResyncs.withLock { $0 } }
}

/// Runs one scenario: CloudVoice on a manual AudioGraph paced in real time, the mic
/// fed by `MicMixer` (fixtures + room bed + synthetic echo of her own output), a
/// RealtimeSession on the chosen connection, and a brain.
public final class ScenarioRunner: @unchecked Sendable {
    public let scenario: Scenario
    public let library: FixtureLibrary
    public let options: RunnerOptions
    public let brain: any HarnessBrain
    public let spend: SpendGuard
    let connection: HarnessConnection

    static let rate = 24_000
    static let block = 480
    static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private let lock = NSLock()
    private var record: RunRecord
    private let mixer = MicMixer(sampleRate: rate)
    private var micTape: [Float] = []
    private var deeTape: [Float] = []
    private var playIndex: [String: Int] = [:]
    private var userIndex: [String: Int] = [:]
    private var openResponses = 0
    private var lastAudioEnd = 0.0
    private var connected = false
    private var utteranceCounter = 0
    private var startClockNoted = false

    private var graph: AudioGraph!
    private var voice: CloudVoice!
    private var session: RealtimeSession!
    private var tap: SocketTap!
    private var wireRecorder = WireRecorder()
    private var liveConnections: Set<Int> = []
    private var tearingDown = false
    private var timeline = TurnTimeline()
    private let loop = AudioLoop()
    /// Every outbound call, on the harness clock.
    public let tape = TransportTape()
    private var ear: (any WakeEar)?
    private var providerStats: (@Sendable () async -> [String: Double])?
    private var uplinkActivity: UplinkActivity?

    public init(scenario: Scenario, library: FixtureLibrary, connection: HarnessConnection, brain: any HarnessBrain,
                spend: SpendGuard, options: RunnerOptions) {
        self.scenario = scenario
        self.library = library
        self.connection = connection
        self.brain = brain
        self.spend = spend
        self.options = options
        let stamp = ISO8601DateFormatter().string(from: Date())
        record = RunRecord(scenario: scenario.name, model: options.model, brain: brain.name, started: stamp)
        record.noise = scenario.noise
        record.echo = scenario.echo
        record.family = scenario.family
        record.state = scenario.state
        record.aecOff = scenario.aecOff
    }

    private func log(_ s: String) { options.log?(Redact.secrets("[\(scenario.name) \(String(format: "%6.2f", now))] \(s)")) }

    /// Harness clock: seconds rendered by the manual graph.
    var now: Double { graph?.now ?? 0 }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: Run

    public func run() async -> RunRecord {
        do {
            try setUp()
            try await connect()
            try await perform()
        } catch {
            locked { record.aborted = record.aborted ?? KeyFile.describe(error) }
            log("aborted: \(KeyFile.describe(error))")
        }
        await tearDown()
        return locked { record }
    }

    private func setUp() throws {
        if let noise = scenario.noise {
            mixer.setBed(try library.bed(noise.bed), snrDB: noise.snrDb)
        }
        mixer.setEcho(scenario.echo, impulse: library.impulse())
        record.bedLevelDB = mixer.bedLevelDB

        graph = try AudioGraph.manual(sampleRate: Double(Self.rate), channels: 1, maximumFrameCount: 4096)
        var config = RealtimeSessionConfig()
        config.model = options.model
        config.voice = .named(options.voice)
        brain.configure(&config)
        if let t = scenario.session {
            if let r = t.rolloverAfter { config.rolloverAfter = r }
            if let r = t.forceRolloverAfter { config.forceRolloverAfter = r }
        }
        let tap = SocketTap { [weak self] e in self?.tapEvent(e) }
        self.tap = tap
        let brain = self.brain
        let wrap: (@escaping RealtimeSocketFactory) -> RealtimeSocketFactory = { brain.wrapSocketFactory(tap.wrap($0)) }

        var trace: TraceRecorder?
        if let dir = options.traceDirectory {
            let url = dir.appendingPathComponent("\(scenario.name).jsonl")
            trace = try TraceRecorder(fileURL: url)
            record.traceFile = url.path
        }
        tape.setClock { [weak self] in self?.now ?? 0 }
        record.wakeMode = options.wake.rawValue
        record.dormantTransitions = 0
        switch connection {
        case .live(let auth):
            session = RealtimeSession(config: config, auth: auth, socketFactory: wrap(URLSessionRealtimeSocket.factory()),
                                      trace: trace)
        case .openAI(let key, let ttl):
            let transport = tape.wrap(Transport.live(redirects: .sameHost))
            let auth = KeyFile.auth(key: key, ttlSeconds: ttl, transport: transport.fetch)
            record.provider = "openAI"
            session = RealtimeSession(config: config, auth: auth, socketFactory: wrap(transport.socketFactory), trace: trace)
        case .provider(let builder):
            if let r = scenario.session?.rolloverAfter { config.rolloverAfter = r }
            let p = try builder.build(tape, config, scenario.wake?.text ?? options.wakePhrase)
            config = p.sessionConfig
            record.provider = builder.mode
            providerStats = p.stats
            uplinkActivity = p.uplink
            if let problems = p.problems {
                Task { [weak self] in
                    for await m in problems {
                        guard let self else { return }
                        let t = self.now
                        self.locked { self.record.errors.append(.init(t: t, text: "provider: \(Redact.secrets(m))")) }
                        self.log("provider problem: \(m)")
                    }
                }
            }
            session = RealtimeSession(config: config, credentials: p.credentials, socketFactory: wrap(p.socketFactory), trace: trace)
        case .local(let endpoint):
            config.endpoint = endpoint
            session = RealtimeSession(config: config, credentials: { _ in .direct("sk-local-replay-no-key") },
                                      socketFactory: wrap(URLSessionRealtimeSocket.factory()), trace: trace)
        case .custom(let credentials, let factory):
            session = RealtimeSession(config: config, credentials: credentials, socketFactory: wrap(factory), trace: trace)
        }
        var vc = CloudVoice.Configuration()
        vc.autoTick = false
        vc.classifySounds = options.classifySounds
        vc.startsDormant = options.wake == .phrase
        if let u = uplinkActivity { vc.uplinkActivity = u }
        timeline = TurnTimeline()
        voice = CloudVoice(session: session, graph: graph, clips: nil, timeline: timeline, configuration: vc)
        if options.wake == .phrase {
            guard brain.supportsWake else { throw HarnessError("--wake phrase needs the realtime brain (\(brain.name) has no window)") }
            let ear = options.makeEar?() ?? OnDeviceWakeEar(requireAuthorization: false)
            self.ear = ear
            voice.addMicSink { pcm, frame in ear.consume(pcm, captureFrame24k: frame) }
        }
        // The single consumer of `awakeStates`: counts DORMANT transitions (always-open
        // asserts 0) and hands them to the brain's window (phrase mode).
        let awake = voice.awakeStates
        let brainForStates = brain
        Task { [weak self] in
            for await st in awake {
                self?.awakeState(st)
                await brainForStates.voiceState(st)
            }
        }

        graph.player.addObserver { [weak self] e in self?.playerEvent(e) }
        let voiceEvents = voice.events
        Task { [weak self] in
            for await e in voiceEvents { self?.voiceEvent(e) }
        }
        if !brain.ownsBrainEvents {
            let brainEvents = voice.brainEvents
            Task { [weak self] in
                for await e in brainEvents {
                    self?.brainEvent(e)
                    await brain.handle(e)
                }
            }
        }
        startLoop()
    }

    private func startLoop() {
        let graph = self.graph!, voice = self.voice!
        let save = options.audioDirectory != nil
        let fmt = Self.format
        loop.start(period: Double(Self.block) / Double(Self.rate)) { [weak self] in
            guard let self else { return }
            guard let out = try? graph.render(frames: AVAudioFrameCount(Self.block)) else { return }
            let outSamples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            let mic = self.locked { () -> [Float] in
                self.mixer.pushOutput(outSamples)
                let m = self.mixer.next(Self.block).mic
                if save { self.micTape += m; self.deeTape += outSamples }
                if self.connected { self.record.uplinkSeconds += Double(Self.block) / Double(Self.rate) }
                return m
            }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Self.block))!
            buf.frameLength = AVAudioFrameCount(Self.block)
            mic.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: Self.block)
            }
            graph.inject(buf, at: graph.now)
            voice.tick()
        }
    }

    private func connect() async throws {
        let brainLog = HarnessLog(request: { [weak self] kind, outcome in
            guard let self else { return }
            let t = self.now
            self.locked { self.record.requests.append(.init(at: t, kind: kind, outcome: outcome)) }
        }, note: { [weak self] text in
            guard let self else { return }
            let t = self.now
            self.locked { self.record.notes.append(.init(t: t, text: text)) }
        }, sentence: { [weak self] text, heard in
            self?.sentenceEvent(text, heard: heard)
        }, trace: { [weak self] entry in
            guard let self else { return }
            let t = self.now
            self.locked {
                var list = self.record.brainTrace ?? []
                list.append(.init(t: t, text: entry))
                self.record.brainTrace = list
            }
        }, wake: { [weak self] e in self?.wakeEvent(e) })
        await brain.attach(voice: voice, log: brainLog)
        await brain.setTurnInstructions(scenario.instructions)
        await brain.start()
        await voice.start()
        if options.wake == .phrase, let ear {
            // DORMANT: nothing connects; only the on-device ear listens (W1/W2).
            let phrase = try WakePhrase(validating: scenario.wake?.text ?? options.wakePhrase)
            let graph = self.graph!, voice = self.voice!
            let busy: @Sendable () -> Busy = { [weak self] in
                guard let self else { return .idle }
                let reply = self.locked { self.openResponses > 0 } || graph.player.isBusy
                return Busy(replyOutstanding: reply, someoneTalking: voice.userIsSpeaking)
            }
            await brain.startWake(HarnessWakeConfig(phrase: phrase, ear: ear, clock: { graph.now }, busy: busy))
            let listening = await waitUntil(timeout: options.earTimeout) { (ear as? OnDeviceWakeEar)?.isListening ?? true }
            guard listening else { throw HarnessError("wake ear never listened (on-device speech unavailable)") }
            log("dormant; listening for “\(phrase.text)” on the device")
            return
        }
        let ok = await waitUntil(timeout: options.connectTimeout) { self.locked { self.connected } }
        guard ok else {
            let err = locked { record.errors.last?.text } ?? "timed out"
            throw HarnessError("never connected: \(err)")
        }
        log("connected")
    }

    /// `CloudVoice.awakeStates`, in order.
    private func awakeState(_ st: CloudVoice.AwakeState) {
        let t = now
        locked {
            if st == .dormant { record.dormantTransitions = (record.dormantTransitions ?? 0) + 1 }
            var list = record.wakeEvents ?? []
            list.append(.init(t: t, text: "voice \(st)"))
            record.wakeEvents = list
        }
        if options.wake == .alwaysOpen, st == .dormant { log("ASSERT: always-open run went DORMANT") }
    }

    private func wakeEvent(_ e: String) {
        let t = now
        locked {
            var list = record.wakeEvents ?? []
            list.append(.init(t: t, text: e))
            record.wakeEvents = list
        }
        log("wake: \(e)")
    }

    private func tearDown() async {
        // Let the last echoes and transcripts land.
        _ = await waitUntil(timeout: 2.0) { false }
        let history = await session?.recentTurns ?? []
        let forgotten = await session?.forgottenItemIDs ?? []
        locked {
            record.history = history.map { .init(role: $0.role.rawValue, text: $0.text, itemID: $0.itemID) }
            if !forgotten.isEmpty { record.forgottenItems = forgotten.sorted() }
            if var faults = record.faults {
                let conns = record.connections ?? []
                for i in faults.indices {
                    faults[i].recoveredAt = conns.compactMap(\.createdAt).filter { $0 > faults[i].at }.min()
                }
                record.faults = faults
            }
        }
        if let stats = providerStats {
            let st = await stats()
            locked { record.providerStats = st }
        }
        locked {
            tearingDown = true
            record.transport = tape.records
        }
        loop.stop()
        voice?.shutdown()
        await brain.detach()
        let turns = timeline.turns()
        locked {
            record.duration = now
            record.timeline = turns.map { t in
                var marks: [String: Double] = [:]
                for m in t.marks where marks[m.stage.rawValue] == nil { marks[m.stage.rawValue] = m.t }
                return .init(id: t.id, start: t.start, marks: marks,
                             details: t.marks.compactMap { m in m.detail.map { "\(m.stage.rawValue): \($0)" } })
            }
            for t in turns {
                for m in t.marks where m.stage == .truncateSent {
                    if let d = m.detail, let parsed = Self.parseTruncate(d) {
                        record.truncations.append(.init(itemID: parsed.item, audioEndMs: parsed.ms, at: m.t))
                    }
                }
            }
            if loop.resyncs > 0 { record.notes.append(.init(t: now, text: "audio loop fell behind \(loop.resyncs)×")) }
        }
        spend.addTranscription(seconds: locked { record.utterances.reduce(0) { $0 + $1.endOfSpeech - $1.onset } })
        if let dir = options.audioDirectory {
            let (mic, dee) = locked { (micTape, deeTape) }
            try? WAV.write(mic, sampleRate: Self.rate, to: dir.appendingPathComponent("\(scenario.name)-mic.wav"))
            try? WAV.write(dee, sampleRate: Self.rate, to: dir.appendingPathComponent("\(scenario.name)-dee.wav"))
        }
    }

    static func parseTruncate(_ detail: String) -> (item: String, ms: Int)? {
        // "<item> audio_end_ms=<n>"
        let parts = detail.split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("audio_end_ms="), let ms = Int(parts[1].dropFirst(13)) else { return nil }
        return (String(parts[0]), ms)
    }

    // MARK: Steps

    private func perform() async throws {
        try await sleep(scenario.leadIn ?? options.leadIn)
        for (i, step) in scenario.steps.enumerated() {
            if spend.exceeded {
                throw HarnessError(String(format: "spend cap: estimated $%.4f > $%.2f", spend.spent, spend.maxUSD))
            }
            if let ins = step.instructions { await brain.setTurnInstructions(ins) }
            if let id = step.say {
                try await userTurn(step: i, id: id, s: step)
            } else if let s = step.silence {
                log("silence \(s) s")
                try await sleep(s)
            } else if let line = step.deeSays {
                try await deeSpeaks(step: i, line: line, initiative: nil, s: step)
            } else if let ins = step.deeInitiative {
                try await deeSpeaks(step: i, line: ins, initiative: ins, s: step)
            } else if let fault = step.fault {
                inject(fault, step: i)
            } else if let action = step.host {
                let done = await brain.perform(action)
                log("host: \(done)")
                locked { record.notes.append(.init(t: now, text: "host step \(i): \(done)")) }
                // A Cortex initiative (a greeting) may follow: let it play out.
                try await sleep(0.5)
                try await waitQuiet(since: now, gap: step.gapAfter ?? options.gapAfter)
            }
            if step.instructions != nil { await brain.setTurnInstructions(scenario.instructions) }
        }
        try await waitQuiet(since: now, gap: 1.0)
    }

    /// Schedules a fixture so its first voiced sample lands at `onsetAt` (or as soon
    /// as possible), and records it.
    @discardableResult
    private func speak(step: Int, id: String, role: RunRecord.UtteranceRole, expect: Scenario.Expect,
                       mention: [String]?, onsetAt: Double? = nil, rubric: String? = nil,
                       continues: Int? = nil, probe: Scenario.Probe? = nil, forbid: [String]? = nil,
                       backchannel: Bool? = nil) throws -> RunRecord.Utterance {
        let (u, samples) = try library.utterance(id)
        let rate = Double(Self.rate)
        return locked {
            let earliest = mixer.frame
            var startFrame = earliest
            if let onsetAt {
                startFrame = max(earliest, Int((onsetAt * rate).rounded()) - u.onsetSample)
            }
            startFrame = mixer.schedule(samples, id: id, at: startFrame)
            let base = Double(startFrame) / rate
            utteranceCounter += 1
            let rec = RunRecord.Utterance(
                index: utteranceCounter, step: step, fixture: id, role: role, text: u.text, start: base,
                onset: base + Double(u.onsetSample) / rate, endOfSpeech: base + Double(u.endOfSpeechSample) / rate,
                spans: u.spans.map { .init(start: base + Double($0.start) / rate, end: base + Double($0.end) / rate) },
                expect: expect, expectMention: mention, continues: continues, rubric: rubric,
                probe: mention == nil ? nil : probe, forbidMention: forbid, backchannel: backchannel)
            record.utterances.append(rec)
            return rec
        }
    }

    private func userTurn(step i: Int, id: String, s: Scenario.Step) async throws {
        var u = try speak(step: i, id: id, role: .turn, expect: s.expected, mention: s.then == nil ? s.expectMention : nil,
                          rubric: s.then == nil ? s.rubric : nil, probe: s.probe,
                          forbid: s.then == nil ? s.forbidMention : nil)
        log("user \(id) “\(u.text)” onset \(f(u.onset)) eos \(f(u.endOfSpeech))")
        if let cont = s.then {
            // The user finishes a held turn after a gap: one turn, two fixtures.
            let held = u
            let c = try speak(step: i, id: cont.say, role: .continuation, expect: s.expect ?? .reply, mention: s.expectMention,
                              onsetAt: held.endOfSpeech + cont.afterMs / 1000, rubric: s.rubric, continues: held.index,
                              probe: s.probe, forbid: s.forbidMention)
            locked {
                if let k = record.utterances.firstIndex(where: { $0.index == held.index }) { record.utterances[k].turnEnd = c.endOfSpeech }
            }
            log("user (continues) \(cont.say) “\(c.text)” onset \(f(c.onset)) eos \(f(c.endOfSpeech))")
            u = c
        }
        try await sleepUntil(u.endOfSpeech)
        let timeout = s.replyTimeout ?? options.replyTimeout
        if let barge = s.bargeIn {
            try await bargeIn(step: i, base: u, barge: barge, timeout: timeout, s: s)
            return
        }
        if s.expected != .noReply || s.then != nil {
            _ = await waitUntil(timeout: timeout) { self.replyStarted(after: u.onset) != nil }
        }
        if let fault = s.faultDuringReply, let reply = replyStarted(after: u.onset) {
            try await sleepUntil(reply.t + (fault.afterMs ?? 800) / 1000)
            inject(fault, step: i)
        }
        try await waitQuiet(since: u.endOfSpeech, gap: s.gapAfter ?? options.gapAfter)
    }

    /// A scripted connection fault (fallback gate).
    private func inject(_ fault: Scenario.Fault, step i: Int) {
        switch fault.kind {
        case .drop: break
        case .reject401: tap.failNextOpen(.unauthorized(status: 401))
        case .reject429: tap.failNextOpen(.rateLimited(retryAfter: 1))
        }
        let dropped = tap.dropNewest()
        let t = now
        locked {
            var list = record.faults ?? []
            list.append(.init(step: i, kind: fault.kind, at: t))
            record.faults = list
        }
        log("fault \(fault.kind.rawValue): dropped connection \(dropped.map(String.init) ?? "none")")
    }

    private func bargeIn(step i: Int, base: RunRecord.Utterance, barge: Scenario.BargeIn, timeout: Double,
                         s: Scenario.Step) async throws {
        _ = await waitUntil(timeout: timeout) { self.replyStarted(after: base.onset) != nil }
        guard let reply = replyStarted(after: base.onset) else {
            log("barge-in: no reply to interrupt; speaking \(barge.say) as a plain turn")
            let u = try speak(step: i, id: barge.say, role: .bargeIn, expect: barge.expected, mention: nil,
                              rubric: barge.rubric, backchannel: barge.isBackchannel)
            locked {
                record.bargeIns.append(.init(step: i, baseFixture: base.fixture, fixture: barge.say, targetAtMs: barge.atMs,
                                             replyItem: nil, replyStarted: nil, onset: u.onset, stoppedAt: nil,
                                             outcome: .notApplicable, backchannel: barge.isBackchannel))
            }
            try await sleepUntil(u.endOfSpeech)
            try await waitQuiet(since: u.endOfSpeech, gap: s.gapAfter ?? options.gapAfter)
            return
        }
        let target = reply.t + barge.atMs / 1000
        let backchannel = barge.isBackchannel
        let u = try speak(step: i, id: barge.say, role: .bargeIn, expect: barge.expected, mention: nil, onsetAt: target,
                          rubric: barge.rubric, backchannel: backchannel)
        log("\(backchannel ? "backchannel" : "barge-in") \(barge.say) onset \(f(u.onset)) (reply \(reply.item) started \(f(reply.t)))")
        // A barge-in: watch her audio until it stops or the miss window passes. A
        // backchannel: watch through its end (a late stop on "keep going" is a stop).
        let watchUntil = backchannel ? max(u.onset + Metrics.bargeMissAfter, u.endOfSpeech + Metrics.backchannelWatch)
                                     : u.onset + Metrics.bargeMissAfter
        _ = await waitUntil(timeout: max(0, watchUntil - now) + 0.5) {
            self.locked {
                guard let k = self.playIndex[reply.item] else { return false }
                // A backchannel is watched to the end of the window unless she was cut.
                return backchannel ? self.record.playback[k].flushed == true : self.record.playback[k].ended != nil
            }
        }
        // Tune 2: DeeVoice pauses her at the onset and flushes when the words are decided
        // (up to its hold limit): give a paused reply that long to end.
        _ = await waitUntil(timeout: RunRecord.BargeOutcome.pauseHoldMax) {
            self.locked { self.playIndex[reply.item].map { self.record.playback[$0].ended != nil } ?? true }
        }
        let pauseMarks = timeline.turns().flatMap(\.marks).filter { $0.stage == .bargeIn }.map(\.t)
        let (p, later) = locked { () -> (RunRecord.Playback?, [RunRecord.Playback]) in
            // Queued items of the same response (all items when the response is unknown).
            let siblings = record.response(forItem: reply.item).map { Set($0.itemIDs) }
            return (playIndex[reply.item].map { record.playback[$0] },
                    record.playback.filter { $0.itemID != reply.item && (siblings?.contains($0.itemID) ?? true) })
        }
        // The pause that ended in a flush (any flush of this reply or its queued items).
        let flushEnd = ([p] + later.map { Optional($0) }).compactMap { $0 }
            .filter { $0.flushed == true && ($0.ended ?? 0) > u.onset }.compactMap(\.ended).min()
        let paused = flushEnd.flatMap {
            RunRecord.BargeOutcome.pauseMark(pauseMarks, replyStarted: reply.t, onset: u.onset, stoppedAt: $0)
        }
        let (outcome, stopped) = RunRecord.BargeOutcome.classify(reply: p, later: later, onset: u.onset,
                                                                  endOfSpeech: u.endOfSpeech, backchannel: backchannel,
                                                                  pausedAt: paused)
        var entry = RunRecord.BargeIn(step: i, baseFixture: base.fixture, fixture: barge.say, targetAtMs: barge.atMs,
                                      replyItem: reply.item, replyStarted: reply.t, onset: u.onset, stoppedAt: stopped,
                                      outcome: outcome, backchannel: backchannel)
        if outcome == .stopped { entry.pausedAt = paused }
        locked { record.bargeIns.append(entry) }
        log("\(backchannel ? "backchannel" : "barge-in") outcome \(backchannel && outcome == .missed ? "continued" : outcome.rawValue)\(entry.latency.map { " silent after \(f($0)) s" } ?? "")\(stopped.map { ", flushed after \(f($0 - u.onset)) s" } ?? "")")
        try await sleepUntil(u.endOfSpeech)
        _ = await waitUntil(timeout: timeout) { self.replyStarted(after: u.onset) != nil }
        try await waitQuiet(since: u.endOfSpeech, gap: s.gapAfter ?? options.gapAfter)
    }

    private func deeSpeaks(step i: Int, line: String, initiative: String?, s: Scenario.Step) async throws {
        // Room noise can read as "the user is talking" locally and refuse the
        // initiative: retry for a while (each refusal is noted in the record).
        var requested = now
        var outcome: InitiativeOutcome = .refused(.notConnected)
        let giveUp = now + 8
        while true {
            requested = now
            if let result = await brain.speak(initiative ?? line, initiative: initiative != nil) {
                switch result {
                case .sent:
                    outcome = .sent
                case .refused(let why, let retryable):
                    outcome = .refused(.notConnected)
                    guard retryable, now < giveUp else {
                        locked { record.notes.append(.init(t: requested, text: "brain refused to speak: \(why)")) }
                        break
                    }
                    locked { record.notes.append(.init(t: requested, text: "brain refused (\(why)); retrying")) }
                    try await sleep(0.5)
                    continue
                }
                break
            }
            if let initiative {
                outcome = await voice.initiative(instructions: initiative)
            } else {
                outcome = await voice.say(line)
            }
            guard case .refused(let why) = outcome, why == .userSpeaking || why == .speaking, now < giveUp else { break }
            locked { record.notes.append(.init(t: requested, text: "initiative refused (\(why.rawValue)); retrying")) }
            try await sleep(0.5)
        }
        log("dee speaks (\(outcome)): “\(line)”")
        locked { record.requests.append(.init(at: requested, kind: "initiative", outcome: "\(outcome)")) }
        var started: Double?, ended: Double?
        if outcome == .sent {
            _ = await waitUntil(timeout: options.replyTimeout) { self.anyPlaybackStarted(after: requested) != nil }
            if let p = anyPlaybackStarted(after: requested) {
                started = p.t
                _ = await waitUntil(timeout: 40) {
                    self.locked { self.playIndex[p.item].map { self.record.playback[$0].ended != nil } ?? true }
                }
                ended = locked { playIndex[p.item].flatMap { record.playback[$0].ended } } ?? now
            }
        }
        let windowEnd = (ended ?? now) + options.echoTail
        try await sleepUntil(windowEnd)
        locked {
            record.echoSegments.append(.init(step: i, line: line, requested: requested, outcome: "\(outcome)",
                                             audioStarted: started, audioEnded: ended,
                                             window: .init(start: requested, end: windowEnd)))
        }
        try await waitQuiet(since: windowEnd, gap: s.gapAfter ?? options.gapAfter)
    }

    // MARK: Waiting

    private func f(_ v: Double) -> String { String(format: "%.2f", v) }

    private func replyStarted(after t: Double) -> (item: String, t: Double)? {
        locked {
            record.playback.compactMap { p -> (String, Double)? in
                guard let s = p.started, s > t else { return nil }
                let kind = record.kind(ofItem: p.itemID)
                guard kind == nil || kind == "reply" || kind == "toolFollowUp" else { return nil }
                return (p.itemID, s)
            }.min { $0.1 < $1.1 }
        }
    }

    private func anyPlaybackStarted(after t: Double) -> (item: String, t: Double)? {
        locked {
            record.playback.compactMap { p -> (String, Double)? in
                guard let s = p.started, s >= t else { return nil }
                return (p.itemID, s)
            }.min { $0.1 < $1.1 }
        }
    }

    /// Nothing of hers playing or generating, no open user speech, for `gap` s.
    private func waitQuiet(since: Double, gap: Double) async throws {
        let ok = await waitUntil(timeout: options.quietTimeout) {
            let busy = self.graph.player.isBusy || self.mixer_fixtureActive()
            let (open, last) = self.locked { (self.openResponses, self.lastAudioEnd) }
            return !busy && open == 0 && self.now - max(since, last) >= gap
        }
        if !ok { locked { record.notes.append(.init(t: now, text: "room never went quiet within \(options.quietTimeout) s")) } }
    }

    private func mixer_fixtureActive() -> Bool { locked { mixer.fixtureActive } }

    private func sleep(_ seconds: Double) async throws { try await sleepUntil(now + seconds) }

    private func sleepUntil(_ t: Double) async throws {
        while now < t {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Polls `condition` on the harness clock; false on timeout.
    private func waitUntil(timeout: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let end = now + timeout
        while now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Observers

    private func playerEvent(_ e: PCMStreamPlayer.Event) {
        let t = graph.now
        locked {
            switch e {
            case .started(let item, let at):
                let i = playbackIndex(item)
                // In offline manual rendering the render timestamp's host time is not
                // the graph clock (PCMStreamPlayer reports ~0 s), so fall back to the
                // end of the block that rendered the first sample (≤ 20 ms late).
                let when = abs(at - t) <= 0.1 ? at : t
                if record.playback[i].started == nil { record.playback[i].started = when }
                if abs(at - t) > 0.1, !startClockNoted {
                    startClockNoted = true
                    record.notes.append(.init(t: t, text: "player .started(at: \(at)) is off the graph clock in manual mode; using render time"))
                }
            case .finished(let item, let ms, let flushed):
                let i = playbackIndex(item)
                record.playback[i].ended = t
                record.playback[i].playedMs = ms
                record.playback[i].flushed = flushed
                lastAudioEnd = max(lastAudioEnd, t)
            case .underrun(let item):
                record.notes.append(.init(t: t, text: "underrun \(item)"))
            case .level:
                break
            }
        }
    }

    private func playbackIndex(_ item: String) -> Int {
        if let i = playIndex[item] { return i }
        record.playback.append(.init(itemID: item))
        playIndex[item] = record.playback.count - 1
        return record.playback.count - 1
    }

    private func userItemIndex(_ item: String, t: Double) -> Int {
        if let i = userIndex[item] { return i }
        record.userItems.append(.init(itemID: item, firstSeen: t))
        userIndex[item] = record.userItems.count - 1
        return record.userItems.count - 1
    }

    private func voiceEvent(_ e: VoiceEvent) {
        let t = now
        switch e {
        case .bargeIn: locked { record.voiceBargeIns.append(t) }
        case .error(let m): locked { record.errors.append(.init(t: t, text: Redact.secrets(m))) }; log("voice error: \(m)")
        default: break
        }
    }

    /// Every frame and connection change of every socket (via `SocketTap`).
    private func tapEvent(_ e: SocketTap.Event) {
        let t = now
        let events = brain.ownsBrainEvents
        var lines: [String] = []
        locked {
            var signals: [WireRecorder.Signal] = []
            switch e {
            case .opened(let c):
                wireRecorder.opened(connection: c, at: t, record: &record)
            case .refused(let c, let reason):
                wireRecorder.refused(connection: c, reason: Redact.secrets(reason), at: t, record: &record)
                lines.append("connection \(c) refused: \(reason)")
            case .frame(let c, let outgoing, let text):
                // W2: mic audio sent before the first local wake (must be 0 in phrase mode).
                if outgoing, options.wake == .phrase, text.contains("input_audio_buffer.append"),
                   !(record.wakeEvents ?? []).contains(where: { $0.text == "eyesWake" }) {
                    record.audioBytesBeforeWake = (record.audioBytesBeforeWake ?? 0) + text.utf8.count
                }
                signals = wireRecorder.frame(connection: c, outgoing: outgoing, text: text, at: t, events: events, record: &record)
            case .closed(let c, let code, let reason, let dropped):
                signals = wireRecorder.closed(connection: c, code: code, reason: reason, dropped: dropped, at: t, record: &record)
                lines.append("connection \(c) closed \(code.map(String.init) ?? "-")\(dropped ? " (harness drop)" : "")")
            }
            for sig in signals {
                switch sig {
                case .connected(let c):
                    liveConnections.insert(c)
                    connected = true
                case .disconnected(let c):
                    liveConnections.remove(c)
                    if events {
                        connected = !liveConnections.isEmpty
                        if liveConnections.isEmpty, !tearingDown {
                            record.errors.append(.init(t: t, text: "disconnected (connection \(c))"))
                        }
                    }
                case .responseStarted:
                    if events { openResponses += 1 }
                case .responseDone(let usage, let counted):
                    guard events else { break }
                    if counted { openResponses = max(0, openResponses - 1) }
                    if let usage { spend.add(usage) }
                case .log(let line):
                    lines.append(line)
                }
            }
        }
        for line in lines { log(line) }
    }

    /// One of her sentences finished (real brain): kept for the item playing now.
    private func sentenceEvent(_ text: String, heard: Bool) {
        guard heard else { return }
        let t = now
        locked {
            let item = record.playback.filter { p in
                guard let s = p.started, s <= t + 0.05 else { return false }
                return p.ended.map { $0 >= t - 0.3 } ?? true
            }.max { ($0.started ?? 0) < ($1.started ?? 0) }?.itemID
            if let item { record.heardSentences[item, default: []].append(text) }
        }
    }

    private func brainEvent(_ e: CloudVoice.BrainEvent) {
        let t = now
        var line: String?
        locked {
            switch e {
            case .session(let s):
                switch s {
                case .connected(let sid, _):
                    connected = true
                    if record.connectedAt == nil { record.connectedAt = t }
                    if let sid { record.sessionIDs.append(sid) }
                case .disconnected(let code, let reason):
                    connected = false
                    record.errors.append(.init(t: t, text: "disconnected \(code.map(String.init) ?? "-") \(reason ?? "")"))
                case .userSpeechStarted(let item, let ms):
                    let i = userItemIndex(item, t: t)
                    record.userItems[i].speechStartedAt = t
                    record.userItems[i].audioStartMs = ms
                    line = "server: speech started \(item)"
                case .userCommitted(let item, _):
                    let i = userItemIndex(item, t: t)
                    record.userItems[i].committedAt = t
                    line = "server: committed \(item)"
                case .userTranscript(let item, let text):
                    let i = userItemIndex(item, t: t)
                    record.userItems[i].transcript = text
                    line = "server heard: “\(text)”"
                case .userTranscriptFailed(let item, let m):
                    let i = userItemIndex(item, t: t)
                    record.userItems[i].transcriptFailed = true
                    record.errors.append(.init(t: t, text: "transcript failed \(item): \(m ?? "")"))
                case .responseStarted(let id, let kind):
                    if !record.responses.contains(where: { $0.responseID == id }) {
                        var r = RunRecord.Response(responseID: id, kind: kind.rawValue)
                        r.startedAt = t
                        record.responses.append(r)
                        openResponses += 1
                    }
                case .assistantTranscript(let item, let text):
                    record.deeTranscripts[item] = text
                    line = "dee: “\(text)”"
                case .responseDone(let sum):
                    var r: RunRecord.Response
                    let idx = record.responses.firstIndex { $0.responseID != nil && $0.responseID == sum.responseID }
                    if let idx { r = record.responses[idx] } else { r = .init(responseID: sum.responseID, kind: sum.kind.rawValue) }
                    if idx != nil, r.doneAt == nil { openResponses = max(0, openResponses - 1) }
                    r.doneAt = t
                    r.status = sum.status
                    r.reason = sum.reason
                    r.itemIDs = sum.itemIDs
                    r.transcript = sum.transcript
                    r.audioMs = sum.audioMs
                    if let u = sum.usage {
                        var rec = RunRecord.UsageRecord()
                        rec.inputText = u.inputTokenDetails?.textTokens ?? 0
                        rec.inputAudio = u.inputTokenDetails?.audioTokens ?? 0
                        rec.cachedText = u.inputTokenDetails?.cachedTokensDetails?.textTokens ?? 0
                        rec.cachedAudio = u.inputTokenDetails?.cachedTokensDetails?.audioTokens ?? 0
                        rec.outputText = u.outputTokenDetails?.textTokens ?? 0
                        rec.outputAudio = u.outputTokenDetails?.audioTokens ?? 0
                        r.usage = rec
                        spend.add(rec)
                    }
                    if let idx { record.responses[idx] = r } else { record.responses.append(r) }
                    line = "response done \(sum.kind.rawValue) \(sum.status)\(sum.reason.map { " (\($0))" } ?? "") spent≈$\(String(format: "%.4f", spend.spent))"
                case .error(let issue):
                    record.errors.append(.init(t: t, text: "\(issue.kind.rawValue) \(issue.code ?? "") \(Redact.secrets(issue.message ?? ""))"))
                case .fallbackAdvised(let reason):
                    record.errors.append(.init(t: t, text: "fallback advised: \(reason)"))
                case .replyPreempted(let id):
                    record.notes.append(.init(t: t, text: "reply preempted \(id ?? "-")"))
                case .initiativeCancelled(let id):
                    record.notes.append(.init(t: t, text: "initiative cancelled \(id ?? "-")"))
                default:
                    break
                }
            case .sentenceFinished(let item, _, let text, let heard):
                if heard { record.heardSentences[item, default: []].append(text) }
            case .itemPlayed(let item, let ms, let cut):
                let i = playbackIndex(item)
                if record.playback[i].playedMs == nil { record.playback[i].playedMs = ms }
                if cut, record.playback[i].flushed == nil { record.playback[i].flushed = true }
            case .connection(let p):
                if let p { record.errors.append(.init(t: t, text: "connection: \(p.message)")) }
            default:
                break
            }
        }
        if let line { log(line) }
    }
}
