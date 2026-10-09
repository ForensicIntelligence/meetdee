import AVFAudio
import CoreMedia
import Foundation
import Speech

/// On-device speech-to-text with SpeechAnalyzer + SpeechTranscriber (iOS 26).
///
/// Device-only in practice: the transcriber model is downloaded through
/// AssetInventory and is not available in the simulator or on macOS test runs.
final class SpeechInput: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unavailable, unsupportedLocale, noAudioFormat
        var description: String {
            switch self {
            case .unavailable: "On-device speech recognition isn't available on this device."
            case .unsupportedLocale: "No supported English speech model."
            case .noAudioFormat: "Speech recognition couldn't agree on an audio format."
            }
        }
        /// Retrying won't help (no model for this device / language).
        var isPermanent: Bool {
            switch self {
            case .unavailable, .unsupportedLocale: true
            case .noAudioFormat: false
            }
        }
    }

    /// (text, isFinal)
    var onResult: (@Sendable (String, Bool) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    /// Serializes `feed` end to end: the converter isn't thread-safe and the
    /// analyzer must receive buffers in timeline order. Never taken inside `lock`'s
    /// critical sections the other way round (feed takes `feedLock`, then `lock`).
    private let feedLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: BufferConverter?
    private var sampleRate: Double = 16_000
    private var fedFrames: Int64 = 0
    private var discardBefore: Double = 0
    private var resultsTask: Task<Void, Never>?
    /// Bumped by every `start` and `stop`; a start whose session is no longer
    /// current (stopped mid-download / mid-prepare) must not install anything.
    private var session = 0
    private var running = false

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Seconds of audio fed so far, on the analyzer's timeline.
    var fedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(fedFrames) / sampleRate
    }

    /// Starts (or restarts, after `stop`) recognition. Throws `CancellationError`
    /// when `stop()` ran before it finished.
    func start(naturalFormat: AVAudioFormat?) async throws {
        let id = beginSession()
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        let locale = await Self.pickLocale()
        guard let locale else { throw Failure.unsupportedLocale }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        if status == .unsupported { throw Failure.unsupportedLocale }
        if status != .installed {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }
        guard isCurrent(id) else { throw CancellationError() }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: naturalFormat)
        else { throw Failure.noAudioFormat }

        let analyzer = SpeechAnalyzer(modules: modules,
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let task = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.isCurrent(id) else { return }
                    let end = result.range.end.seconds
                    if self.shouldDiscard(end: end.isFinite ? end : .infinity) { continue }
                    self.onResult?(String(result.text.characters), result.isFinal)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(id) else { return }
                self.onError?("Speech recognition stopped: \(error.localizedDescription)")
            }
        }
        guard install(session: id, analyzer: analyzer, continuation: continuation, format: format, task: task) else {
            // stop() ran while we were preparing: tear this one down, install nothing.
            task.cancel()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            if isCurrent(id) { stop() }
            throw error
        }
    }

    private func beginSession() -> Int {
        lock.lock(); defer { lock.unlock() }
        session += 1
        return session
    }

    private func isCurrent(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return session == id
    }

    private func install(session id: Int, analyzer: SpeechAnalyzer,
                         continuation: AsyncStream<AnalyzerInput>.Continuation,
                         format: AVAudioFormat, task: Task<Void, Never>) -> Bool {
        feedLock.lock(); defer { feedLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        guard session == id else { return false }
        self.analyzer = analyzer
        self.continuation = continuation
        self.converter = BufferConverter(target: format)
        self.sampleRate = format.sampleRate
        self.fedFrames = 0
        self.discardBefore = 0
        self.resultsTask = task
        self.running = true
        return true
    }

    private func shouldDiscard(end: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return end <= discardBefore + 0.02
    }

    /// Ignore results for audio fed before this moment (recognition paused/resumed).
    func discardResultsBeforeNow() {
        lock.lock(); defer { lock.unlock() }
        discardBefore = Double(fedFrames) / sampleRate
    }

    /// Normally called from the input tap thread; safe from any thread (serialized).
    func feed(_ buffer: AVAudioPCMBuffer) {
        feedLock.lock(); defer { feedLock.unlock() }
        lock.lock()
        guard running, let continuation, let converter else { lock.unlock(); return }
        let rate = sampleRate
        lock.unlock()
        guard let converted = converter.convert(buffer) else { return }
        lock.lock()
        let start = CMTime(value: fedFrames, timescale: CMTimeScale(rate.rounded()))
        fedFrames += Int64(converted.frameLength)
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Force the analyzer to finalize volatile text (the user went quiet, or Dee is
    /// about to talk and nothing said before the pause may merge with what follows).
    func finalizeVolatile() {
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        guard let analyzer else { return }
        Task { try? await analyzer.finalize(through: nil) }
    }

    /// Stops recognition, including a `start` still downloading or preparing.
    /// `start` may be called again afterwards.
    func stop() {
        feedLock.lock()
        lock.lock()
        session += 1
        let analyzer = self.analyzer
        let task = resultsTask
        continuation?.finish()
        continuation = nil
        converter = nil
        self.analyzer = nil
        resultsTask = nil
        running = false
        lock.unlock()
        feedLock.unlock()
        task?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    /// The user's English locale when supported, else US English.
    static func pickLocale() async -> Locale? {
        let current = Locale.current
        if current.language.languageCode?.identifier == "en",
           let l = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return l
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }
}
