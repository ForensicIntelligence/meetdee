import AVFAudio
import DeeMind
import DeeSelf
import DeeVoice
import Foundation
import Synchronization

/// How the user said this turn, measured on the device the moment the server
/// commits it (docs/DNA.md §1.9: fast mode needs prosody before any transcript).
///
/// A second consumer of Dee's microphone tap keeps the last 30 s as 40 ms frames
/// (energy, peak, voiced, pitch). The server reports each utterance's span on its
/// input timeline (`audio_start_ms` … `audio_end_ms`); that span is laid back onto
/// the local frames ending at the last voiced frame before the server said it
/// stopped. Only voiced frames count for loudness and pitch, so the server's
/// padding and trailing silence don't matter. RAM only; nothing is kept per
/// utterance after it was read.
public final class ProsodyTap: @unchecked Sendable {
    struct Frame {
        var t: Double
        var energy: Double
        var samples: Int
        var peak: Float
        var voiced: Bool
        var f0: Double?
        var rate: Double
    }

    private struct State {
        var frames: [Frame] = []
        var slicer = FrameSlicer(frameSize: 1)
        var rate = 0.0
        var vad = EnergyVAD()
        /// Server spans: item → (start ms, end ms, local time the stop arrived).
        var spans: [String: (start: Int, end: Int?, stoppedAt: Double?)] = [:]
        var order: [String] = []
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> Double
    static let keep = 30.0
    static let frameSeconds = 0.04

    /// - Parameter now: the clock of the tap's host times (`AudioGraph.now`).
    public init(now: @escaping @Sendable () -> Double) {
        self.now = now
    }

    /// Starts listening to `graph`'s microphone tap.
    public convenience init(graph: AudioGraph) {
        self.init(now: { graph.now })
        graph.addMicConsumer { [weak self] buffer, t in self?.add(buffer, at: t) }
    }

    /// One microphone buffer (`t`: host time of its last sample).
    public func add(_ buffer: AVAudioPCMBuffer, at t: Double) {
        let rate = buffer.format.sampleRate
        guard rate > 0, let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data[0], count: n))
        add(samples, sampleRate: rate, at: t)
    }

    /// Mono samples (`t`: host time of the last sample).
    public func add(_ samples: [Float], sampleRate rate: Double, at t: Double) {
        state.withLock { s in
            if s.rate != rate {
                s.rate = rate
                s.slicer = FrameSlicer(frameSize: max(1, Int(rate * Self.frameSeconds)))
            }
            let frames = s.slicer.push(samples)
            guard !frames.isEmpty else { return }
            let d = Double(frames[0].count) / rate
            for (k, f) in frames.enumerated() {
                let ft = t - Double(frames.count - 1 - k) * d
                var e = 0.0
                var p: Float = 0
                for v in f {
                    e += Double(v) * Double(v)
                    p = max(p, abs(v))
                }
                let db = Level.powerDB(e / Double(f.count))
                let voiced = s.vad.process(frameDB: db, frameDuration: d)
                var f0: Double?
                if voiced {
                    let (small, r) = PitchDetector.decimate(f, sampleRate: rate)
                    f0 = PitchDetector.yin(small, sampleRate: r)
                }
                s.frames.append(Frame(t: ft, energy: e, samples: f.count, peak: p, voiced: voiced, f0: f0, rate: rate))
            }
            let cutoff = t - Self.keep
            if let first = s.frames.firstIndex(where: { $0.t >= cutoff }), first > 0 { s.frames.removeFirst(first) }
        }
    }

    /// The server opened an utterance.
    public func speechStarted(item: String, audioStartMs: Int) {
        state.withLock { s in
            s.spans[item] = (audioStartMs, nil, nil)
            s.order.append(item)
            if s.order.count > 16 { s.spans[s.order.removeFirst()] = nil }
        }
    }

    /// The server closed it.
    public func speechStopped(item: String, audioEndMs: Int) {
        let t = now()
        state.withLock { s in
            let start = s.spans[item]?.start ?? audioEndMs
            s.spans[item] = (start, audioEndMs, t)
        }
    }

    /// The utterance's duration on the server's timeline (seconds), if known.
    public func duration(item: String) -> Double? {
        state.withLock { s in
            guard let span = s.spans[item], let end = span.end else { return nil }
            return Double(max(0, end - span.start)) / 1000
        }
    }

    /// Prosody of `item` (nil: never saw it, or nothing voiced). `text` gives the
    /// speech rate (words per voiced second); without it the rate is nil.
    public func prosody(item: String, text: String? = nil) -> (prosody: VoiceProsody, duration: Double, hasRate: Bool)? {
        state.withLock { s -> (VoiceProsody, Double, Bool)? in
            guard let span = s.spans[item], let end = span.end, let stoppedAt = span.stoppedAt else { return nil }
            let duration = Double(max(0, end - span.start)) / 1000
            // The utterance ends at the last voiced frame before the server's stop.
            guard let last = s.frames.lastIndex(where: { $0.voiced && $0.t <= stoppedAt }) else { return nil }
            let lastT = s.frames[last].t
            var acc = ProsodyAccumulator()
            var i = last
            while i >= 0, s.frames[i].t > lastT - duration {
                let f = s.frames[i]
                acc.add(energy: f.energy, samples: f.samples, peak: f.peak, voiced: f.voiced, f0: f.f0, sampleRate: f.rate)
                i -= 1
            }
            guard acc.voicedDuration > 0 else { return nil }
            let p = acc.prosody(text: text ?? "")
            return (p, duration, text.map { !$0.isEmpty } ?? false)
        }
    }

    /// `Prosody` for the mind (rate from the baseline when there are no words yet,
    /// so a missing transcript never reads as "slow").
    public func mindProsody(item: String, text: String?, baseline: Appraiser.VoiceBaseline) -> (Prosody, Double)? {
        guard let (p, duration, hasRate) = prosody(item: item, text: text) else { return nil }
        let rate = hasRate && p.speechRate > 0 ? p.speechRate : baseline.speechRate
        return (Prosody(loudnessDB: p.loudnessDB, peakDB: p.peakDB, speechRate: rate, pitchVariability: p.pitchVariability), duration)
    }

    /// The §1.9 read for the DNA.
    public func read(item: String, text: String?, baseline: Appraiser.VoiceBaseline) -> ProsodyRead? {
        mindProsody(item: item, text: text, baseline: baseline).map { Appraiser.prosodyOnly($0.0, baseline: baseline) }
    }

    /// Forgets everything (background).
    public func reset() {
        state.withLock { s in
            s.frames.removeAll()
            s.spans.removeAll()
            s.order.removeAll()
        }
    }
}
