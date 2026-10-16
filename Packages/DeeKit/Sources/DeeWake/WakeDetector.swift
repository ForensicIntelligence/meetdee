import Foundation

/// The wake ear's decisions, pure (no recogniser): energy in, recogniser segments in,
/// hits / candidate cues / finalize requests out. `OnDeviceWakeEar` wraps it around
/// the real `OnDeviceSpeech`; tests drive it with scripted segments.
public struct WakeDetector: Sendable {
    public struct Output: Sendable, Equatable {
        public var hit: WakeHit?
        public var candidate = false
        /// Ask the recogniser to finalize through this frame (fast final at a hit).
        public var finalizeThrough: Int64?
    }

    public static let rate: Double = 24_000
    /// Per-word allowance + slack for how far before the phrase end an onset may lie.
    public static let secondsPerWord = 0.45
    public static let onsetSlack = 0.3
    /// After a volatile hit, wait this long for its final before hitting again.
    public static let finalWait: Int64 = 6 * 24_000
    /// Candidate cues at most this often.
    public static let candidateGap: Int64 = 36_000

    public private(set) var matcher: WakeMatcher
    public private(set) var ring = EnergyRing()
    private var awaitingFinalSince: Int64?
    private var lastPhraseEnd: Int64?
    private var lastHitDetected: Int64?
    private var lastCandidate: Int64?
    private var lastFinalEnd: Int64?
    private var lastFinalEndedWithBreak = true
    /// Newest fed frame (end of the last chunk).
    public private(set) var fedEnd: Int64 = 0

    public init(matcher: WakeMatcher) { self.matcher = matcher }

    public mutating func setMatcher(_ m: WakeMatcher) { matcher = m }

    /// Feed audio energy. Returns a frame to finalize through after a 0.3 s pause.
    public mutating func audio(_ pcm16k: [Int16], captureFrame24k: Int64) -> Int64? {
        fedEnd = captureFrame24k + Int64((Double(pcm16k.count) * 1.5).rounded())
        return ring.append(pcm16k, captureFrame24k: captureFrame24k)
    }

    /// The most frames an onset may lie before the phrase end (contract §3).
    public func onsetBudget() -> Int64 {
        Int64(((Double(matcher.phrase.words.count) * Self.secondsPerWord + Self.onsetSlack) * Self.rate).rounded())
    }

    public mutating func segment(_ s: SpeechSegment, detectedAt: Int64? = nil) -> Output {
        var out = Output()
        let detected = detectedAt ?? fedEnd
        if let since = awaitingFinalSince, detected - since > Self.finalWait { awaitingFinalSince = nil }
        let afterBreak = startsAfterBreak(s)
        if s.isFinal {
            if let e = s.endFrame { lastFinalEnd = max(lastFinalEnd ?? e, e) }
            lastFinalEndedWithBreak = s.text.trimmingCharacters(in: .whitespaces).last.map { WakeText.breakCharacters.contains($0) } ?? lastFinalEndedWithBreak
        }
        guard let m = matcher.match(s.texts, isFinal: s.isFinal, startsAfterBreak: afterBreak) else {
            if !s.isFinal, matcher.candidate(s.text), lastCandidate.map({ detected - $0 >= Self.candidateGap }) ?? true {
                lastCandidate = detected
                out.candidate = true
            }
            if s.isFinal, awaitingFinalSince != nil, let end = s.endFrame, let last = lastHitDetected, end >= last - 24_000 {
                awaitingFinalSince = nil
            }
            return out
        }
        let timing = m.textIndex == 0 ? Self.timing(of: m.wordRange, in: s) : nil
        let budget = onsetBudget()
        if s.isFinal {
            let refining = awaitingFinalSince != nil
            awaitingFinalSince = nil
            if !refining, let end = lastPhraseEnd, let t = timing, t.start < end { return out }   // same phrase again
            if !refining, timing == nil, let last = lastHitDetected, detected - last < 3 * 24_000 { return out }
            let onset: Int64
            var fromFinal = false
            if let t = timing {
                onset = max(t.start, t.end - budget)
                fromFinal = true
                lastPhraseEnd = t.end
            } else {
                let end = s.endFrame ?? detected
                onset = ring.onset(endingAt: end, notBefore: end - budget) ?? (end - budget)
            }
            if refining && !fromFinal { return out }    // nothing better than the volatile hit
            lastHitDetected = detected
            out.hit = WakeHit(onsetFrame: onset, onsetFromFinal: fromFinal, detectedFrame: detected, matched: m.matched, tier: m.tier,
                              phraseEndFrame: timing?.end)
            return out
        }
        // Volatile.
        if awaitingFinalSince != nil { return out }
        if let last = lastHitDetected, detected - last < 3 * 24_000 { return out }
        let end = min(timing?.end ?? detected, detected)
        let onset = ring.onset(endingAt: end, notBefore: end - budget) ?? (end - budget)
        awaitingFinalSince = detected
        lastHitDetected = detected
        out.hit = WakeHit(onsetFrame: onset, onsetFromFinal: false, detectedFrame: detected, matched: m.matched, tier: m.tier, phraseEndFrame: nil)
        out.finalizeThrough = detected
        out.candidate = lastCandidate.map { detected - $0 >= Self.candidateGap } ?? true
        if out.candidate { lastCandidate = detected }
        return out
    }

    /// Does this segment's text start after a pause / sentence end? The first result,
    /// a previous final ending in punctuation, ≥ 0.3 s between the previous final and
    /// this segment, or ≥ 0.3 s of quiet in the energy ring before it.
    func startsAfterBreak(_ s: SpeechSegment) -> Bool {
        guard let prevEnd = lastFinalEnd else { return true }
        if lastFinalEndedWithBreak { return true }
        guard let start = s.startFrame else { return true }
        if start - prevEnd >= 7_200 { return true }
        return ring.quietBefore(start) >= 7_200
    }

    /// Frames of the matched words from the segment's run timing.
    static func timing(of range: Range<Int>, in s: SpeechSegment) -> (start: Int64, end: Int64)? {
        guard !s.runs.isEmpty else { return nil }
        var index = 0
        var start: Int64?
        var end: Int64?
        for run in s.runs {
            let words = WakeText.words(run.text)
            guard !words.isEmpty else { continue }
            let runRange = index..<(index + words.count)
            if runRange.overlaps(range) {
                if start == nil { start = run.startFrame }
                end = run.endFrame
            }
            index += words.count
        }
        // Run words must line up with the text's words, or the timing is meaningless.
        guard index == WakeText.words(s.text).count, let start, let end, end > start else { return nil }
        return (start, end)
    }
}
