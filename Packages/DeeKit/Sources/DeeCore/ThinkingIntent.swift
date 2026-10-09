import Foundation

/// Decides whether a user utterance is asking Dee to think harder.
///
/// Thinking is off by default (fast, chatty replies). Saying "think about it",
/// "take your time", "think it through" … turns it on for the rest of that
/// conversation; a new conversation turns it off again. The detector is
/// deliberately lexical: it runs on every utterance before the model sees it,
/// must cost nothing, and must be predictable enough to explain in a sentence.
public enum ThinkingIntent: Sendable, Equatable {
    case enable
    case disable
    case none

    public static func detect(in utterance: String) -> ThinkingIntent {
        var text = normalize(utterance)
        guard !text.isEmpty else { return .none }
        // "What do you think about cats?" asks for an opinion, not for deliberation.
        for pattern in opinionPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        for pattern in disablePatterns where text.range(of: pattern, options: .regularExpression) != nil {
            return .disable
        }
        for pattern in enablePatterns where text.range(of: pattern, options: .regularExpression) != nil {
            // "don't think about it", "no need to think" are the opposite request.
            if text.range(of: negation + pattern, options: .regularExpression) != nil { return .disable }
            return .enable
        }
        return .none
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Prefix that flips an enable phrase into a request *not* to think. Kept
    /// tight (immediately adjacent) so "not sure … take your time" or "stop and
    /// think about it" aren't misread as negations.
    static let negation = #"\b(don't|do not|dont|not|never|without|no need to|(don't|do not|dont) (need|have) to)\s+(really\s+|even\s+)?"#

    static let enablePatterns: [String] = [
        #"\bthink (about|on|over|through|it through|this through|that through|it over|this over|that over|carefully|hard|harder|deeply|long|properly|really hard|step by step|it out|this out)\b"#,
        #"\b(have|take) a (good |real |long |careful |quick |proper )?think\b"#,
        #"\bgive (it|this|that) (some |a little |more |careful |real |a bit of )?thought\b"#,
        #"\bput (some |more |real )?thought into\b"#,
        #"\bthink before (you )?(answer|answering|respond|responding|reply|replying)\b"#,
        #"\btake (your|a little|some|the) time\b"#,
        #"\b(reason|work|walk) (it |this |that )?(through|out) (carefully|step by step)\b"#,
        #"\b(reason|work) (it|this|that) (through|out)\b"#,
        #"\b(think|reason|solve (it|this|that)|figure (it|this|that) out|work (it|this|that) out) step by step\b"#,
        #"\b(mull|chew) (it|this|that) over\b"#,
        #"\b(ponder|deliberate|contemplate)\b"#,
        #"\buse your (brain|head|noggin|thinking cap)\b"#,
        #"\bput (on )?your thinking cap( on)?\b"#,
        #"\b(turn|switch) on (thinking|thinking mode)\b"#,
        #"\b(turn|switch) (thinking|thinking mode) on\b"#,
        #"\bthinking mode\b"#,
        #"\bsleep on it\b"#,
    ]

    /// Everyday uses of "think" that must not switch thinking mode on.
    static let opinionPatterns: [String] = [
        #"\blet (me|us) (\w+ )?(think|ponder|mull|sleep)\b"#,
        #"\b(can't|cannot|cant|couldn't|won't) stop thinking\b"#,
        #"\b(i|we|they|he|she|people)('ll|'d|'m going to| will| would| might| may| need to| have to| want to| should| am going to) (\w+ )?(think|ponder) (about|of|on|over|it)\b"#,
        #"\b(what|how|why|who|which|when|where) (do|did|does|would|will|should|could|can) (you|i|we|they|he|she|people) (\w+ )?think (about|of|on)\b"#,
        #"\b(do|did|does|would|will) (you|i|we|they|he|she) (ever |really |even )?think (about|of|on)\b"#,
        #"\b(i|we|they|he|she|people) (often |sometimes |never |always |usually |still |also )?(think|thought) (about|of|on|over)\b"#,
    ]

    static let disablePatterns: [String] = [
        #"\b(stop|quit|no more) (thinking|overthinking|pondering)\b"#,
        #"\b(turn|switch) (off|of) (thinking|thinking mode)\b"#,
        #"\b(turn|switch) (thinking|thinking mode) off\b"#,
        #"\b(just )?answer (quickly|fast|right away|immediately)\b"#,
        #"\b(don't|do not|dont) overthink\b"#,
        #"\b(don't|do not|dont|no need to) think (too |so )?(hard|much|long)\b"#,
    ]
}
