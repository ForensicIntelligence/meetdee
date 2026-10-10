import Foundation

/// Whether the words someone said over Dee's voice are a backchannel — "keep
/// going", "go on", "mm-hm", "yeah" — that means *go on*, never a turn of their
/// own and never a reason to stop.
///
/// `CloudVoice` uses it to settle a held barge-in (`FloorHold`): a backchannel
/// lets her go on from exactly where she paused; anything else ("stop", "wait",
/// a question) ends her reply there. The brain's floor logic uses the same
/// classification (one rule for both, so she never resumes for words the brain
/// then answers, nor stops for words the brain lets pass).
///
/// The rule: every clause is a continuer (fillers like "Dee", "please", "just",
/// "so", "well", "no", "now" aside), at most 8 words, and no question — except
/// the continuers "really?", "yeah?", "and?", "and then?", "then what?".
public enum Backchannel {
    /// Whole-clause continuers.
    public static let continuers: Set<String> = [
        "keep going", "go on", "go ahead", "carry on", "continue", "don't stop", "do not stop", "please continue",
        "i'm listening", "im listening", "i am listening", "listening", "i'm still listening", "still listening",
        "mm hm", "mm hmm", "mhm", "mmhm", "mmhmm", "mm", "mmm", "uh huh", "uh-huh", "uhhuh", "yeah", "yeah yeah", "yep", "yes",
        "right", "okay", "ok", "sure", "i see", "got it", "cool", "nice", "wow", "oh", "ah", "aha", "really", "interesting",
        "and then", "then what", "what else", "tell me more", "more", "yes go on", "sure go on",
        "keep talking", "you can keep going", "you can go on", "please go on", "i'm here", "go for it",
        "keep on going", "keep it going",
        // How "keep going" comes back from transcription when said softly (tune 2 live: "Cheap, going.").
        "cheap going", "cheap", "going", "keep go",
    ]

    /// Words that don't change what a clause means here.
    public static let fillers: Set<String> = ["dee", "d", "please", "just", "so", "well", "no", "now", "a", "an", "uh", "um"]

    static let questionContinuers: Set<String> = ["really?", "yeah?", "and?", "and then?", "then what?"]

    /// `text` is only a backchannel ("Keep going, I'm listening.", "Mm-hm.",
    /// "Don't stop, keep going."). "Stop", "wait", "no", a question or anything
    /// else make it a real turn.
    public static func isBackchannel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("?") || questionContinuers.contains(trimmed.lowercased()) else { return false }
        let all = words(trimmed.replacingOccurrences(of: "-", with: " "))
        guard !all.isEmpty, all.count <= 8 else { return false }
        let clauses = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .split { ",.!?;…".contains($0) }
            .map { words(String($0)) }
            .filter { !$0.filter { !fillers.contains($0) }.isEmpty }
        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { raw in
            let kept = raw.filter { !fillers.contains($0) }
            return continuers.contains(raw.joined(separator: " ")) || continuers.contains(kept.joined(separator: " "))
                || kept.allSatisfy(isHum)
        }
    }

    /// A hum however it is spelled: "mm-hm", "mhm", "hmm", "mmhn" (tune 2 live:
    /// "Mm-hm." came back as "MMHN.").
    static func isHum(_ w: String) -> Bool {
        w.count >= 2 && w.count <= 6 && w.allSatisfy { "mhnu".contains($0) } && w.contains("m")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
