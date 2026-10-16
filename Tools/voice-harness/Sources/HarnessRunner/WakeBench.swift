import DeeWake
import Foundation
import HarnessCore
import Synchronization

/// The on-device half of the 0.6 wake suite: fixture audio mixed with a room bed is
/// fed, like a microphone, through the REAL wake ear (`DeeWake.OnDeviceWakeEar`:
/// Apple SpeechAnalyzer with on-device assets + the phrase matcher). Nothing here
/// touches the network (W1): no key, no socket, no request.
///
/// One ear per phrase listens to one continuous stream (trial after trial, each with a
/// bed lead-in and a tail), as the phone's mic would. Hits are attributed to a trial by
/// the audio they came from (the phrase's end frame from the final result, else the
/// onset, else the feed position), never by wall time.
public final class WakeBench: @unchecked Sendable {
    public enum Pace: String, Sendable {
        /// As fast as the recogniser keeps up (≤ `maxLead` s of audio ahead of its
        /// results). Accept / false-wake counts only: latencies are not measured.
        case fast
        /// Paced like a microphone (20 ms blocks in real time): latencies are real.
        case realtime
    }

    public struct Options: Sendable {
        public var pace: Pace = .fast
        /// Bed before the fixture, and after it (the recogniser lags ~2 s behind speech).
        public var lead = 1.0
        public var tail = 3.5
        /// Fast pace: audio is fed this many times faster than real time.
        public var speedup = 4.0
        /// Fast pace: after a trial, how long (s, real) to wait for the recogniser's
        /// results to reach the end of the fixture's speech.
        public var maxLead = 2.0
        public var locale = Locale(identifier: "en-US")
        public var log: (@Sendable (String) -> Void)?
        public init() {}
    }

    static let rate = 24_000
    static let block = 480

    let library: FixtureLibrary
    let options: Options

    public init(library: FixtureLibrary, options: Options = Options()) {
        self.library = library
        self.options = options
    }

    /// What the ear says about the device before anything runs (assets, permission).
    public static func availability(locale: Locale = Locale(identifier: "en-US")) async -> EarAvailability {
        await OnDeviceSpeech.availability(locale: locale, requireAuthorization: false)
    }

    private final class Observer: @unchecked Sendable {
        let lock = NSLock()
        var hits: [WakeHit] = []
        var candidates: [Int64] = []
        var resultEnd: Int64 = 0
        var fed: Int64 = 0
        func with<T>(_ body: (Observer) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }

    /// Runs `trials` (all for `phrase`) then the bed `exposures`, on one ear.
    public func run(phrase text: String, trials: [WakeSuite.Trial], exposures: [Scenario.Noise],
                    exposureSeconds: Double) async throws -> (trials: [WakeTrialResult], exposures: [WakeExposureResult]) {
        let phrase = try WakePhrase(validating: text)
        let ear = OnDeviceWakeEar(locale: options.locale, requireAuthorization: false)
        let obs = Observer()
        let hitsTask = Task { for await h in ear.hits { obs.with { $0.hits.append(h) } } }
        let candTask = Task { for await _ in ear.candidates { obs.with { $0.candidates.append($0.fed) } } }
        let results = await ear.speech.results()
        let resTask = Task {
            for await s in results {
                if let e = s.endFrame ?? s.runs.last?.endFrame { obs.with { $0.resultEnd = max($0.resultEnd, e) } }
            }
        }
        defer { hitsTask.cancel(); candTask.cancel(); resTask.cancel() }
        await ear.start(phrase: phrase)
        guard ear.isListening else {
            await ear.stop()
            throw HarnessError("wake ear not listening (\(await Self.availability(locale: options.locale)))")
        }
        var down = Downsampler24to16()
        var frame: Int64 = 0
        var start = ProcessInfo.processInfo.systemUptime

        /// Feeds `samples` (24 kHz float) as the mic, paced.
        func feed(_ samples: [Float]) async {
            var i = 0
            while i < samples.count {
                let n = min(Self.block, samples.count - i)
                let chunk = samples[i..<(i + n)].map { Int16(max(-1, min(1, $0)) * 32767) }
                let (out, first) = down.process(chunk, firstFrame24k: frame)
                if let first, !out.isEmpty { ear.consume(out, captureFrame24k: first) }
                frame += Int64(n)
                i += n
                obs.with { $0.fed = frame }
                switch options.pace {
                case .realtime:
                    let due = start + Double(frame) / Double(Self.rate)
                    let now = ProcessInfo.processInfo.systemUptime
                    if due > now { try? await Task.sleep(for: .seconds(due - now)) }
                case .fast:
                    // `speedup` × real time (results only come on speech, so they can't pace it).
                    let due = start + Double(frame) / Double(Self.rate) / options.speedup
                    let now = ProcessInfo.processInfo.systemUptime
                    if due > now { try? await Task.sleep(for: .seconds(due - now)) }
                }
            }
        }

        /// Fast pace: let the recogniser finish what was fed (the final after the tail).
        func drain(until target: Int64) async {
            guard options.pace == .fast else { return }
            var waited = 0.0
            while waited < options.maxLead, obs.with({ $0.resultEnd }) < target {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 0.01
            }
            // Re-anchor the pacing clock after the wait (no burst).
            start = ProcessInfo.processInfo.systemUptime - Double(frame) / Double(Self.rate) / options.speedup
        }

        var out: [WakeTrialResult] = []
        for t in trials {
            let (u, speech) = try library.utterance(t.fixture)
            let mixer = MicMixer(sampleRate: Self.rate)
            if let n = t.noise { mixer.setBed(try library.bed(n.bed), snrDB: n.snrDb) }
            let leadFrames = Int(options.lead * Double(Self.rate))
            mixer.schedule(speech, id: t.fixture, at: leadFrames)
            let total = leadFrames + speech.count + Int(options.tail * Double(Self.rate))
            let base = frame
            let hitsBefore = obs.with { $0.hits.count }
            let candBefore = obs.with { $0.candidates.count }
            await feed(mixer.next(total).mic)
            let onset = base + Int64(leadFrames + u.onsetSample)
            let eos = base + Int64(leadFrames + u.endOfSpeechSample)
            await drain(until: eos)
            let end = base + Int64(total)
            // Attribute by the audio the hit came from.
            let mine = obs.with { o in Array(o.hits.dropFirst(hitsBefore)) }.filter { h in
                let at = h.phraseEndFrame ?? h.onsetFrame ?? h.detectedFrame
                return at >= base && at < end
            }
            var r = WakeTrialResult(trial: t, hit: !mine.isEmpty, phraseEnd: Double(eos - base) / Double(Self.rate))
            if let h = mine.first {
                r.tier = "\(h.tier)"
                r.matched = h.matched
                r.fromFinal = h.onsetFromFinal
                if options.pace == .realtime { r.hitAt = Double(h.detectedFrame - base) / Double(Self.rate) }
                if let o = h.onsetFrame { r.onsetError = Double(o - onset) / Double(Self.rate) }
            }
            if options.pace == .realtime, let c = obs.with({ Array($0.candidates.dropFirst(candBefore)) }).first(where: { $0 >= base && $0 < end }) {
                r.candidateAt = Double(c - base) / Double(Self.rate)
            }
            out.append(r)
            options.log?("\(t.correct(r) ? "ok  " : "MISS") \(t.phrase) \(t.fixture)@\(t.condition) \(t.expect.rawValue)"
                         + (r.hit ? " hit “\(r.matched ?? "")” \(r.tier ?? "")\(r.latency.map { String(format: " %.2f s", $0) } ?? "")" : ""))
        }

        var exp: [WakeExposureResult] = []
        for n in exposures where exposureSeconds > 0 {
            let mixer = MicMixer(sampleRate: Self.rate)
            mixer.setBed(try library.bed(n.bed), snrDB: n.snrDb)
            let base = frame
            let hitsBefore = obs.with { $0.hits.count }
            var left = Int(exposureSeconds * Double(Self.rate))
            while left > 0 {
                let k = min(left, 10 * Self.rate)
                await feed(mixer.next(k).mic)
                left -= k
            }
            await drain(until: frame - Int64(2 * Self.rate))
            let hits = obs.with { o in Array(o.hits.dropFirst(hitsBefore)) }
            var e = WakeExposureResult(phrase: text, bed: n.bed, snrDb: n.snrDb, seconds: exposureSeconds)
            e.falseWakes = hits.map { Double(($0.phraseEndFrame ?? $0.onsetFrame ?? $0.detectedFrame) - base) / Double(Self.rate) }
            e.matched = hits.map(\.matched)
            exp.append(e)
            options.log?("exposure \(text) / \(n.bed) \(Int(exposureSeconds)) s: \(hits.count) false wake(s) \(e.matched.prefix(4))")
        }
        await ear.stop()
        return (out, exp)
    }
}

extension WakeSuite.Trial {
    func correct(_ r: WakeTrialResult) -> Bool { r.hit == (expect == .accept) }
}
