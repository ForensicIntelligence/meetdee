import AVFAudio
import Foundation
import HarnessCore
import SoundAnalysis

/// Calm: the offline SoundAnalysis pass over the non-speech fixtures (`voice-harness
/// sounds`). Apple's built-in classifier (`.version1`, the app's settings: 1.5 s
/// windows, 50 % overlap) must label each sound in `FixtureCatalog.expectedSoundLabel`
/// as its family with confidence ≥ `soundCheckMin`; a fixture that fails is
/// re-synthesized before any live run. No key, no network.
enum SoundCheck {
    struct Row {
        var id: String
        var expected: String?
        /// Median over `leads` of the expected family's best window (nil: no expectation).
        var confidence: Double?
        /// The expected family's best score at the luckiest lead.
        var best: Double? = nil
        /// Top labels over all windows (label, best confidence).
        var top: [(String, Double)]
        var ok: Bool { expected == nil || (confidence ?? 0) >= FixtureCatalog.soundCheckMin }
    }

    static let families: [String: Set<String>] = [
        "laughter": ["laughter", "baby_laughter", "giggling", "snicker", "belly_laugh", "chuckle_chortle"],
        "cough": ["cough"],
        "breathing": ["breathing", "sigh", "gasp"],
        "sneeze": ["sneeze"],
    ]

    /// Round 2: the classifier's 1.5 s windows make a short sound's score depend on
    /// where it falls in them (ns12: 0.09–0.52 over these leads). In the app the
    /// alignment is arbitrary, so a sound is scored at each lead and the median is its
    /// confidence (`best` is the luckiest alignment).
    static let leads: [Double] = [0.3, 0.45, 0.6, 0.75, 0.9, 1.05]

    /// Classifies `samples` (24 kHz mono), padded with `lead` s of silence before and
    /// 0.6 s after.
    static func classify(_ samples: [Float], sampleRate: Int = 24_000, lead: Double = 0.6) throws -> [String: Double] {
        let pad = [Float](repeating: 0, count: Int(0.6 * Double(sampleRate)))
        let x = [Float](repeating: 0, count: Int(lead * Double(sampleRate))) + samples + pad
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
            var best: [String: Double] = [:]
            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let r = result as? SNClassificationResult else { return }
                for c in r.classifications where c.confidence > (best[c.identifier] ?? 0) { best[c.identifier] = c.confidence }
            }
        }
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        let block = 4800
        var pos = 0
        while pos < x.count {
            let n = min(block, x.count - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            x.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress! + pos, count: n) }
            analyzer.analyze(buf, atAudioFramePosition: AVAudioFramePosition(pos))
            pos += n
        }
        analyzer.completeAnalysis()
        return collector.best
    }

    static func row(id: String, samples: [Float]) throws -> Row {
        let expected = FixtureCatalog.expectedSoundLabel[id]
        var merged: [String: Double] = [:]
        var family: [Double] = []
        for lead in leads {
            let best = try classify(samples, lead: lead)
            for (k, v) in best where v > (merged[k] ?? 0) { merged[k] = v }
            if let fam = expected { family.append((families[fam] ?? [fam]).compactMap { best[$0] }.max() ?? 0) }
        }
        let sorted = family.sorted()
        let median = sorted.isEmpty ? nil : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        let top = merged.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
        return Row(id: id, expected: expected, confidence: median, best: sorted.last, top: Array(top))
    }

    static func describe(_ r: Row) -> String {
        let top = r.top.map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: ", ")
        let exp = r.expected.map { String(format: "%@ median %.2f, best %.2f (need median ≥ %.1f)", $0, r.confidence ?? 0, r.best ?? 0, FixtureCatalog.soundCheckMin) } ?? "no expectation"
        return String(format: "%-4@ %@  %@  [top: %@]", r.ok ? "OK" : "FAIL", r.id, exp, top)
    }
}
