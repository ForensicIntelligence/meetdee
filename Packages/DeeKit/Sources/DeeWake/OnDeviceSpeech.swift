@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

/// One transcription result from the on-device recogniser. Frames are on the 24 kHz
/// capture clock (the analyzer's `bufferStartTime` is the capture frame, timescale
/// 24000, so its times map 1:1 onto PCM16Capture positions).
public struct SpeechSegment: Sendable, Equatable, Codable {
    /// Which on-device module wrote it.
    public enum Source: String, Sendable, Equatable, Codable { case dictation, speech }

    public struct Run: Sendable, Equatable, Codable {
        public var text: String
        public var startFrame: Int64
        public var endFrame: Int64
    }

    public var text: String
    public var alternatives: [String]
    public var isFinal: Bool
    /// The result's range. Reliable on finals; on volatile results it is the start of
    /// the volatile region, not of these words (measured, wake-map-sdk).
    public var startFrame: Int64?
    public var endFrame: Int64?
    /// Per-run word timing (finals: ±50 ms).
    public var runs: [Run]
    public var source: Source

    public init(text: String, alternatives: [String] = [], isFinal: Bool, startFrame: Int64? = nil, endFrame: Int64? = nil, runs: [Run] = [],
                source: Source = .dictation) {
        self.source = source
        self.text = text
        self.alternatives = alternatives
        self.isFinal = isFinal
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.runs = runs
    }

    /// Best text first, then the alternatives (what the matcher searches).
    public var texts: [String] { [text] + alternatives }
}

/// SpeechDetector (voice activity) output on the capture clock.
public struct SpeechActivity: Sendable, Equatable {
    public var speechDetected: Bool
    public var startFrame: Int64
    public var endFrame: Int64
}

public enum OnDeviceSpeechError: Error, Sendable, Equatable {
    case unsupportedLocale(String)
    case assetsMissing
    case noAudioFormat
    case notAuthorized
    case analyzer(String)

    public var availability: EarAvailability {
        switch self {
        case .unsupportedLocale, .noAudioFormat: .unsupported
        case .assetsMissing: .assetsMissing
        case .notAuthorized: .denied
        case .analyzer: .unsupported
        }
    }
}

/// The on-device recogniser: one Apple `SpeechAnalyzer` with a `DictationTranscriber`
/// (`.shortForm`, `.farField`, contextual strings, `.frequentFinalization`) and,
/// optionally, a `SpeechDetector` sharing it. Never server recognition: SpeechAnalyzer
/// runs in the local speech service on installed assets (no network sockets measured
/// during recognition — wake-map-sdk).
///
/// Shared: the wake ear listens to it while dormant; the cascaded `.onDevice` STT
/// backend and the mode-3 turn detector subscribe to the same `results()` /
/// `activity()` while a window is open. Any number of subscribers.
public actor OnDeviceSpeech {
    public struct Configuration: Sendable, Equatable {
        public var locale: Locale
        public var contextualStrings: [String]
        /// Add a SpeechDetector (voice activity) to the same analyzer.
        public var detector: Bool
        /// Punctuated text (the STT backend wants it; the wake matcher ignores it).
        public var punctuation: Bool
        /// Also run a SpeechTranscriber in the same analyzer (its segments have
        /// `source == .speech`; the STT backend reads `.dictation` only).
        public var speechTranscriber: Bool

        public init(locale: Locale = Locale(identifier: "en-US"), contextualStrings: [String] = [], detector: Bool = false, punctuation: Bool = true,
                    speechTranscriber: Bool = false) {
            self.speechTranscriber = speechTranscriber
            self.locale = locale
            self.contextualStrings = contextualStrings
            self.detector = detector
            self.punctuation = punctuation
        }
    }

    public static let captureRate: Double = 24_000

    private struct Feed: @unchecked Sendable {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var format: AVAudioFormat?
        var fedFrames: Int64 = 0
    }

    private nonisolated let feedState = Mutex(Feed())
    private let resultCast = Broadcast<SpeechSegment>()
    private let activityCast = Broadcast<SpeechActivity>()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var tasks: [Task<Void, Never>] = []
    public private(set) var configuration: Configuration?
    public private(set) var lastError: String?

    private var users: [String: Configuration] = [:]

    public init() {}

    public var isRunning: Bool { analyzer != nil }

    // MARK: - Sharing

    /// Use the recogniser as `user` ("wake", "stt", "turns"). The running configuration
    /// is the union of every user's (contextual strings, detector, punctuation; the
    /// first user's locale); it restarts only when that union changes.
    public func acquire(_ user: String, _ config: Configuration) async throws(OnDeviceSpeechError) {
        users[user] = config
        try await applyUsers()
    }

    /// Stop using it; the analyzer stops when nobody uses it.
    public func release(_ user: String) async {
        guard users.removeValue(forKey: user) != nil else { return }
        if users.isEmpty { await stop() } else { try? await applyUsers() }
    }

    public var activeUsers: Set<String> { Set(users.keys) }

    private func applyUsers() async throws(OnDeviceSpeechError) {
        let sorted = users.sorted { $0.key < $1.key }.map(\.value)
        guard var merged = sorted.first else { return }
        for c in sorted.dropFirst() {
            merged.detector = merged.detector || c.detector
            merged.punctuation = merged.punctuation || c.punctuation
            merged.speechTranscriber = merged.speechTranscriber || c.speechTranscriber
            for s in c.contextualStrings where !merged.contextualStrings.contains(s) { merged.contextualStrings.append(s) }
        }
        if merged == configuration, analyzer != nil { return }
        if let current = configuration, analyzer != nil, current.locale == merged.locale, current.detector == merged.detector,
           current.punctuation == merged.punctuation, current.speechTranscriber == merged.speechTranscriber {
            await setContextualStrings(merged.contextualStrings)
            return
        }
        try await start(merged)
    }

    // MARK: - Availability / assets

    /// Whether the ear can run: permission, a supported locale, installed assets, heat.
    /// - Parameter requireAuthorization: treat an unasked speech permission as
    ///   `.notAsked` (iOS until a device check shows SpeechAnalyzer doesn't need it).
    public static func availability(locale: Locale = Locale(identifier: "en-US"), requireAuthorization: Bool = defaultRequiresAuthorization) async -> EarAvailability {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .thermalBackoff }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: return .denied
        case .notDetermined: if requireAuthorization { return .notAsked }
        default: break
        }
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let module = DictationTranscriber(locale: supported, preset: .shortDictation)
        switch await assetStatus(module, locale: supported) {
        case .installed: return .ready
        case .downloading: return .assetsDownloading(0)
        case .supported: return .assetsMissing
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Asset status after reserving the locale for this process. Measured: a process
    /// that hasn't reserved sees `.supported` for installed assets (and a nil install
    /// request); after `reserve(locale:)` the same assets read `.installed`. Reserving
    /// is local (no download).
    static func assetStatus(_ module: DictationTranscriber, locale: Locale) async -> AssetInventory.Status {
        let first = await AssetInventory.status(forModules: [module])
        guard first == .supported else { return first }
        _ = try? await AssetInventory.reserve(locale: locale)
        let second = await AssetInventory.status(forModules: [module])
        if second == .supported, (try? await AssetInventory.assetInstallationRequest(supporting: [module])) == nil {
            return .installed   // nothing to download
        }
        return second
    }

    #if os(iOS)
    public static let defaultRequiresAuthorization = true
    #else
    public static let defaultRequiresAuthorization = false
    #endif

    /// One-time model download for `locale` (never audio). Progress 0…1.
    public static func installAssets(locale: Locale = Locale(identifier: "en-US"), progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw OnDeviceSpeechError.unsupportedLocale(locale.identifier)
        }
        let module = DictationTranscriber(locale: supported, preset: .shortDictation)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { progress(1); return }
        let p = request.progress
        let poll = Task {
            while !Task.isCancelled {
                progress(p.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    // MARK: - Lifecycle

    /// Start (or restart with) `config`. Throws when the locale is unsupported or the
    /// assets aren't installed — the caller stays DORMANT and shows the problem.
    public func start(_ config: Configuration) async throws(OnDeviceSpeechError) {
        await stop()
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: config.locale) else {
            throw .unsupportedLocale(config.locale.identifier)
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm, .farField],
            transcriptionOptions: config.punctuation ? [.punctuation] : [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions, .frequentFinalization],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        var modules: [any SpeechModule] = [transcriber]
        let speechModule = config.speechTranscriber ? SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
            attributeOptions: [.audioTimeRange]) : nil
        if let speechModule { modules.append(speechModule) }
        let detector = config.detector ? SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true) : nil
        if let detector { modules.append(detector) }
        guard await Self.assetStatus(transcriber, locale: locale) == .installed else { throw .assetsMissing }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { throw .noAudioFormat }
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        do {
            if !config.contextualStrings.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = config.contextualStrings
                try await analyzer.setContext(ctx)
            }
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            throw .analyzer(String(describing: error))
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let cast = resultCast
        let resultsTask = Task {
            do {
                for try await r in transcriber.results { cast.yield(Self.segment(r)) }
            } catch {}
        }
        var tasks = [resultsTask]
        if let speechModule {
            tasks.append(Task {
                do {
                    for try await r in speechModule.results {
                        cast.yield(Self.segment(text: r.text, alternatives: r.alternatives, isFinal: r.isFinal, range: r.range, source: .speech))
                    }
                } catch {}
            })
        }
        if let detector {
            let acast = activityCast
            tasks.append(Task {
                do {
                    for try await r in detector.results {
                        acast.yield(SpeechActivity(speechDetected: r.speechDetected, startFrame: Self.frame(r.range.start), endFrame: Self.frame(r.range.end)))
                    }
                } catch {}
            })
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            resultsTask.cancel()
            throw .analyzer(String(describing: error))
        }
        feedState.withLock { $0 = Feed(continuation: continuation, format: format, fedFrames: 0) }
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.tasks = tasks
        self.configuration = config
    }

    /// Stop at once (results so far stay delivered).
    public func stop() async {
        let c = feedState.withLock { s -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { s = Feed() }
            return s.continuation
        }
        c?.finish()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        for t in tasks { t.cancel() }
        tasks = []
        analyzer = nil
        transcriber = nil
        configuration = nil
    }

    /// Finish the input, finalize everything, wait for the last results (files/tests).
    public func finish() async {
        let c = feedState.withLock { s -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        for t in tasks { await t.value }
        tasks = []
        analyzer = nil
        transcriber = nil
        configuration = nil
    }

    public func setContextualStrings(_ strings: [String]) async {
        guard let analyzer else { return }
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = strings
        try? await analyzer.setContext(ctx)
        configuration?.contextualStrings = strings
    }

    /// Finalize everything before this capture frame (fast finals at a pause / commit).
    public func finalize(throughFrame24k frame: Int64?) async {
        guard let analyzer else { return }
        try? await analyzer.finalize(through: frame.map { CMTime(value: $0, timescale: CMTimeScale(Self.captureRate)) })
    }

    // MARK: - Audio

    /// 16 kHz mono PCM16 whose first sample is at `captureFrame24k`. Cheap, callable
    /// from the mic consumer; dropped when not running.
    public nonisolated func feed(_ pcm16k: [Int16], captureFrame24k: Int64) {
        guard !pcm16k.isEmpty else { return }
        feedState.withLock { s in
            guard let c = s.continuation, let format = s.format else { return }
            guard let buffer = Self.buffer(pcm16k, format: format) else { return }
            c.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: captureFrame24k, timescale: CMTimeScale(Self.captureRate))))
            s.fedFrames += Int64(pcm16k.count)
        }
    }

    public nonisolated var fedSamples: Int64 { feedState.withLock { $0.fedFrames } }

    public func results() -> AsyncStream<SpeechSegment> { resultCast.stream }
    public func activity() -> AsyncStream<SpeechActivity> { activityCast.stream }

    // MARK: - Helpers

    static func frame(_ t: CMTime) -> Int64 {
        guard t.isNumeric else { return 0 }
        return Int64((t.seconds * captureRate).rounded())
    }

    static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        if format.commonFormat == .pcmFormatInt16, let dst = b.int16ChannelData?[0] {
            samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        } else if format.commonFormat == .pcmFormatFloat32, let dst = b.floatChannelData?[0] {
            for i in 0..<samples.count { dst[i] = Float(samples[i]) / 32768 }
        } else {
            return nil
        }
        return b
    }

    static func segment(_ r: DictationTranscriber.Result) -> SpeechSegment {
        segment(text: r.text, alternatives: r.alternatives, isFinal: r.isFinal, range: r.range, source: .dictation)
    }

    static func segment(text: AttributedString, alternatives: [AttributedString], isFinal: Bool, range: CMTimeRange, source: SpeechSegment.Source) -> SpeechSegment {
        var runs: [SpeechSegment.Run] = []
        for run in text.runs {
            guard let r = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let t = String(text[run.range].characters)
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            runs.append(.init(text: t, startFrame: frame(r.start), endFrame: frame(r.end)))
        }
        return SpeechSegment(
            text: String(text.characters),
            alternatives: alternatives.map { String($0.characters) },
            isFinal: isFinal,
            startFrame: frame(range.start),
            endFrame: frame(range.end),
            runs: runs,
            source: source)
    }
}
