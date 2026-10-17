import Foundation

/// $ per 1M tokens (OpenAI pricing page as captured in openai-realtime-research.md §5).
public struct Pricing: Codable, Sendable, Equatable {
    public var model: String
    public var audioIn: Double
    public var audioInCached: Double
    public var textIn: Double
    public var textInCached: Double
    public var audioOut: Double
    public var textOut: Double
    /// `gpt-transcribe` input transcription, $ per minute of committed user audio.
    public var transcribePerMinute: Double = 0.0045

    public static let mini = Pricing(model: "gpt-realtime-2.1-mini", audioIn: 10, audioInCached: 0.30,
                                     textIn: 0.60, textInCached: 0.06, audioOut: 20, textOut: 2.40)
    public static let full = Pricing(model: "gpt-realtime-2.1", audioIn: 32, audioInCached: 0.40,
                                     textIn: 4, textInCached: 0.40, audioOut: 64, textOut: 24)
    /// `gpt-4o-mini-tts`: $0.60 / 1M text in, $12 / 1M audio out (≈ 1200 tokens / min out).
    public static let ttsTextIn = 0.60
    public static let ttsAudioOut = 12.0

    public static func forModel(_ model: String) -> Pricing { model.hasSuffix("-mini") ? .mini : .full }

    public func dollars(_ u: RunRecord.UsageRecord) -> Double {
        let uncachedAudio = max(0, u.inputAudio - u.cachedAudio)
        let uncachedText = max(0, u.inputText - u.cachedText)
        let total = Double(uncachedAudio) * audioIn + Double(u.cachedAudio) * audioInCached
            + Double(uncachedText) * textIn + Double(u.cachedText) * textInCached
            + Double(u.outputAudio) * audioOut + Double(u.outputText) * textOut
        return total / 1_000_000
    }

    /// Conservative projection before a run: per reply ≈ 12 s of Dee's audio out, the
    /// whole conversation so far re-billed as (mostly cached) input, plus transcription.
    public func projected(replies: Int, userSeconds: Double) -> Double {
        var total = 0.0
        var contextAudioTokens = 0.0
        for _ in 0..<max(replies, 0) {
            let out = 12.0 * 20             // 20 audio tokens / s of Dee's speech
            let freshIn = 6.0 * 10          // ~6 s of user speech per turn at 10 tokens / s
            total += (out * audioOut + freshIn * audioIn + contextAudioTokens * audioInCached
                      + 1500 * textIn + 200 * textOut) / 1_000_000
            contextAudioTokens += out + freshIn
        }
        return total + userSeconds / 60 * transcribePerMinute
    }
}

public struct CostSummary: Codable, Sendable, Equatable {
    public var usage = RunRecord.UsageRecord()
    public var responsesDollars = 0.0
    public var transcriptionDollars = 0.0
    public var total: Double { responsesDollars + transcriptionDollars }

    public init() {}

    public static func of(_ runs: [RunRecord], pricing: Pricing) -> CostSummary {
        var c = CostSummary()
        for run in runs {
            for r in run.responses {
                guard let u = r.usage else { continue }
                c.usage.inputText += u.inputText; c.usage.inputAudio += u.inputAudio
                c.usage.cachedText += u.cachedText; c.usage.cachedAudio += u.cachedAudio
                c.usage.outputText += u.outputText; c.usage.outputAudio += u.outputAudio
                c.responsesDollars += pricing.dollars(u)
            }
            let userSeconds = run.utterances.reduce(0) { $0 + ($1.endOfSpeech - $1.onset) }
            c.transcriptionDollars += userSeconds / 60 * pricing.transcribePerMinute
        }
        return c
    }
}

/// The up-front spend check of `run`. The projection is deliberately pessimistic
/// (live runs cost ~80% of it), so `--over-projection` lets a run start whose
/// projection is above the cap: the live `SpendGuard` still stops it at the cap.
public enum SpendPlan {
    public enum Verdict: Equatable, Sendable { case go, goOverProjection, refuse(String) }

    public static func check(projected: Double, cap: Double, allowOverProjection: Bool) -> Verdict {
        guard projected > cap else { return .go }
        if allowOverProjection { return .goOverProjection }
        return .refuse(String(format: "projected spend $%.3f exceeds --max-usd %.2f (pass --over-projection to rely on the live cap)",
                              projected, cap))
    }
}
