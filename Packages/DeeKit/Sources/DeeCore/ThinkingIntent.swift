import Foundation

/// Decides whether a user utterance is asking Dee to think harder.
///
/// Thinking is off by default (fast, chatty replies). Asking Dee to — "think hard",
/// "take your time and think", "could you think it through?" — makes Dee think for
/// *that* reply only (`.enable`); the next turn is fast again. Only an explicit
/// switch ("turn on thinking mode") keeps it on for the rest of the conversation
/// (`.enableMode`), and a new conversation turns that off again. The detector is
/// deliberately lexical: it runs on every utterance before the model sees it, must
/// cost nothing, and must be predictable enough to explain in a sentence:
///
/// **Only a request addressed to Dee enables thinking.** The phrase has to open a
/// clause, as an imperative ("Think hard.", "Dee, think it over") or a request
/// ("can you…", "I want you to…", "you should…"), optionally after a lead-in such as
/// "okay", "hey Dee" or "please". Narration never does: "I think about my dad a
/// lot", "I just think about food", "let me think about it", "my teacher told me
/// to think hard" are the user talking about *their* thinking (audit C7: each of
/// those used to switch on 30–90 s silences for the rest of the conversation).
///
/// **Everyday imperatives need more.** "Think about it" and "take your time" are
/// mostly rhetorical or polite ("Well, think about it.", "Think about it, cats are
/// tiny lions.", "Oh, take your time."). As a request to think they count only when
/// the utterance asks something ("Think about it: is 7 prime?"), names Dee ("Think
/// about it, Dee!"), or is nothing but the request ("Think about it."); "take your
/// time" only with a question in the utterance, or joined to "and think" / "to
/// answer".
public enum ThinkingIntent: Sendable, Equatable {
    /// Think before answering this utterance.
    case enable
    /// Think on every reply from now on ("turn on thinking mode").
    case enableMode
    /// Stop thinking (this reply, and the mode if it was on).
    case disable
    case none

    public static func detect(in utterance: String) -> ThinkingIntent {
        var text = normalize(utterance)
        guard !text.isEmpty else { return .none }
        // "What do you think about cats?", "I never think about it": everyday uses of
        // "think" go first, so they can't read as a (negated) request below.
        for pattern in opinionPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        for pattern in disablePatterns where text.range(of: pattern, options: .regularExpression) != nil {
            return .disable
        }
        // "don't think about it", "no need to think" are the opposite request.
        for phrase in requestPhrases + [jointlessPhrase, takeTimePhrase] where text.range(of: negation + "(" + phrase + ")", options: .regularExpression) != nil {
            return .disable
        }
        let parts = clauses(of: utterance)
        for part in parts where opens(part.text, with: modePhrases, leadIns: leadIns) {
            return .enableMode
        }
        for (i, part) in parts.enumerated() {
            if isRequest(part.text) { return .enable }
            if isWeakRequest(at: i, in: parts, utterance: utterance) { return .enable }
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

    /// One part of an utterance between punctuation marks, normalised.
    struct Clause: Equatable {
        let text: String
        /// Ends in "?" or opens like a question ("will it rain today").
        let isQuestion: Bool
    }

    /// The utterance split at punctuation, each part normalised: "I'm not sure. Take
    /// your time." is two clauses, and the second one is a request.
    static func clauses(of utterance: String) -> [Clause] {
        var result: [Clause] = []
        var current = ""
        func close(_ terminator: Character?) {
            let text = normalize(current)
            current = ""
            guard !text.isEmpty else { return }
            let asks = terminator == "?" || text.range(of: questionOpening, options: .regularExpression) != nil
            result.append(Clause(text: text, isQuestion: asks))
        }
        for ch in utterance {
            if delimiters.contains(ch) { close(ch) } else { current.append(ch) }
        }
        close(nil)
        return result
    }

    static let delimiters = Set(".?!;:,\n—–()\"")
    static let questionOpening = #"^(what|why|how|who|whom|whose|which|when|where|is|are|was|were|am|do|does|did|can|could|would|will|should|shall|has|have|may|might|isn't|aren't|don't|doesn't|didn't)\b"#

    /// The clause opens with a request to think, addressed to Dee.
    static func isRequest(_ clause: String) -> Bool {
        if opens(clause, with: requestPhrases, leadIns: leadIns) { return true }
        // "Let's think it through" is a request; "let's think about dinner" is planning.
        let joint = "(" + requestPhrases.joined(separator: "|") + ")"
        return clause.range(of: "^((" + leadIns + ") )*(let's|let us) ((" + softeners + ") )*" + joint + #"\b"#, options: .regularExpression) != nil
    }

    /// "Think about it" / "take your time" as a real request (see the type's notes).
    static func isWeakRequest(at i: Int, in parts: [Clause], utterance: String) -> Bool {
        let clause = parts[i].text
        // Asked outright ("can you think about it", "I want you to think about that").
        if clause.range(of: "^((" + leadIns + ") )*(" + requests + ") ((" + softeners + ") )*" + jointlessPhrase + #"\b"#,
                        options: .regularExpression) != nil {
            return true
        }
        // Imperatives only after a plain lead-in: "and then think about the money",
        // "well, think about it", "oh take your time" are conversation.
        let imperative = "^((" + plainLeadIns + ") )*((please|first) )*"
        let asks = parts[i...].contains(where: \.isQuestion)
        if clause.range(of: imperative + jointlessPhrase + #"\b"#, options: .regularExpression) != nil {
            let alone = parts.indices.allSatisfy { $0 == i || parts[$0].text.range(of: "^((" + plainLeadIns + ") ?)+$", options: .regularExpression) != nil }
            return asks || alone || normalize(utterance).split(separator: " ").contains("dee")
        }
        if clause.range(of: imperative + takeTimePhrase + #"\b"#, options: .regularExpression) != nil {
            return parts.contains(where: \.isQuestion)
        }
        return false
    }

    /// The clause opens (after lead-ins, a request form and softeners) with one of `phrases`.
    static func opens(_ clause: String, with phrases: [String], leadIns: String) -> Bool {
        let opening = "^((" + leadIns + ") )*((" + requests + ") )?((" + softeners + ") )*"
        return clause.range(of: opening + "(" + phrases.joined(separator: "|") + ")" + #"\b"#, options: .regularExpression) != nil
    }

    /// Prefix that flips a request into a request *not* to think. Kept tight
    /// (immediately adjacent) so "not sure … take your time" or "stop and think about
    /// it" aren't misread as negations.
    static let negation = #"\b(don't|do not|dont|not|never|without|no need to|(don't|do not|dont) (need|have) to)\s+(really\s+|even\s+)?"#

    /// Words that may open a clause before a clear request.
    static let leadIns = "ok|okay|alright|all right|so|now|well|hmm+|hm+|um+|uh+|and|but|then|dee|hey|hi|please|just|really|actually|oh|right|first|look|listen|come on|stop and|go on and|go ahead and"

    /// Lead-ins that keep an everyday imperative a request: address and politeness,
    /// not the "and / but / so / well / oh" of someone making a point.
    static let plainLeadIns = "ok|okay|alright|all right|hmm+|hm+|um+|uh+|dee|hey|hi|please|first|come on|stop and|go on and|go ahead and"

    /// Ways of asking Dee to do something.
    static let requests = "can you|could you|would you|will you|won't you|i want you to|i'd like you to|i would like you to|i need you to|you should|you need to|you have to|you'd better|you better|try to|why don't you|how about you"

    /// Fillers between the request and the verb ("could you please really think…").
    static let softeners = "please|just|really|maybe|actually|try to|first"

    /// "think about / on / over / through …": a request only as an imperative, never
    /// after "let's" (that is planning out loud, not asking Dee to deliberate), and
    /// only with a question, Dee's name, or on its own (`isWeakRequest`).
    static let jointlessPhrase = #"think (about|on|over|through)"#

    /// "take your time": usually politeness ("oh, take your time"); a request to think
    /// only with a question in the utterance (`isWeakRequest`).
    static let takeTimePhrase = #"take (your|a little|some) time"#

    /// Switches thinking on for the rest of the conversation.
    static let modePhrases: [String] = [
        #"(turn|switch) on (thinking|thinking mode)"#,
        #"(turn|switch) (thinking|thinking mode) on"#,
        #"(use|enable|activate) thinking mode"#,
    ]

    /// Requests to deliberate, valid as imperatives and after "let's".
    static let requestPhrases: [String] = [
        #"think (it|this|that) (through|over|out)"#,
        #"think (carefully|hard|harder|deeply|long|properly|really hard|step by step)"#,
        #"think before (you )?(answer|answering|respond|responding|reply|replying)"#,
        #"(have|take) a (good |real |long |careful |quick |proper )?think"#,
        #"give (it|this|that) (some |a little |more |careful |real |a bit of )?thought"#,
        #"put (some |more |real )?thought into"#,
        #"take (your|a little|some) time (and|to) (think|answer|reason|work|consider)"#,
        #"take (your|a little|some) time (thinking|answering|before (you )?(answer|answering|respond|responding|reply|replying))"#,
        #"(reason|work|walk) (it |this |that )?(through|out) (carefully|step by step)"#,
        #"(reason|work) (it|this|that) (through|out)"#,
        #"(reason|solve (it|this|that)|figure (it|this|that) out|work (it|this|that) out) step by step"#,
        #"(mull|chew) (it|this|that) over"#,
        #"(ponder|deliberate|contemplate)"#,
        #"use your (brain|head|noggin|thinking cap)"#,
        #"put (on )?your thinking cap"#,
    ]

    /// Everyday uses of "think" that must not read as a (negated) request.
    static let opinionPatterns: [String] = [
        #"\blet (me|us) (\w+ )?(think|ponder|mull|sleep)\b"#,
        #"\b(can't|cannot|cant|couldn't|won't) stop thinking\b"#,
        #"\b(i|we|they|he|she|people)('ll|'d|'m going to| will| would| might| may| need to| have to| want to| should| am going to) (\w+ )?(think|ponder) (about|of|on|over|it)\b"#,
        #"\b(what|how|why|who|which|when|where) (do|did|does|would|will|should|could|can) (you|i|we|they|he|she|people) (\w+ )?think (about|of|on)\b"#,
        #"\b(do|did|does|would|will) (you|i|we|they|he|she) (ever |really |even )?think (about|of|on)\b"#,
        #"\b(i|we|they|he|she|people) (often |sometimes |never |always |usually |still |also |don't |do not |dont |didn't |did not )?(think|thought) (about|of|on|over)\b"#,
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

/// How hard the realtime model reasons before it speaks (`reasoning.effort`).
/// The raw values are the API's.
public enum ReasoningEffort: String, Sendable, Equatable, CaseIterable {
    case minimal, low, medium, high, xhigh
}

/// Thinking for one conversation: the explicit mode ("turn on thinking mode") and
/// what each utterance asks for. Thinking never means long silences any more: a
/// turn that thinks is answered with a higher reasoning effort for that response
/// only (`reasoningEffort`), everything else at the brisk default.
public struct ThinkingMode: Sendable, Equatable {
    /// What one utterance gets.
    public struct Turn: Sendable, Equatable {
        /// This reply thinks first.
        public var thinks: Bool
        /// The mode switched with this utterance (on or off), for the transcript
        /// and the "thinking mode on/off" UI; nil when it did not change.
        public var modeChanged: Bool?
        /// The `reasoning.effort` for this response.
        public var reasoningEffort: ReasoningEffort { thinks ? ThinkingMode.thinkingEffort : ThinkingMode.chatEffort }
    }

    /// Effort for ordinary, chatty replies (the session default).
    public static let chatEffort = ReasoningEffort.low
    /// Effort for a reply that was asked to think.
    public static let thinkingEffort = ReasoningEffort.medium

    /// Thinking mode: every reply thinks until it is switched off or a new
    /// conversation starts.
    public private(set) var isOn: Bool

    public init(isOn: Bool = false) { self.isOn = isOn }

    /// Switches the mode directly (the debug toggle).
    public mutating func set(_ on: Bool) { isOn = on }

    /// Reads one utterance: "think hard about this" thinks for this reply only,
    /// "turn on thinking mode" switches the mode on (and thinks now), "stop
    /// thinking" switches it off and answers this reply without thinking.
    public mutating func turn(for utterance: String) -> Turn {
        let intent = ThinkingIntent.detect(in: utterance)
        var changed: Bool?
        switch intent {
        case .enableMode where !isOn:
            isOn = true
            changed = true
        case .disable where isOn:
            isOn = false
            changed = false
        default:
            break
        }
        return Turn(thinks: intent == .enable || (isOn && intent != .disable), modeChanged: changed)
    }

    /// The effort for a reply requested before its words are known (fast mode:
    /// the reply is requested on the server's commit and the transcript arrives
    /// later): the mode as it stands. Call `wordsArrived(_:answeredAt:)` when the
    /// words come in.
    public var effortBeforeWords: ReasoningEffort { isOn ? Self.thinkingEffort : Self.chatEffort }

    /// Fast mode: the words of a turn already answered at `effort` arrived. The
    /// mode updates exactly as with `turn(for:)`; `rethink` says the user asked
    /// for more thought than that reply got ("think hard about this", "turn on
    /// thinking mode"), so the brain may withdraw the reply if it has no audio yet
    /// and ask again at `turn.reasoningEffort`. A reply that thought when the user
    /// said "stop thinking" is not worth redoing: `rethink` is false.
    public mutating func wordsArrived(_ utterance: String, answeredAt effort: ReasoningEffort) -> (turn: Turn, rethink: Bool) {
        let t = turn(for: utterance)
        let order = ReasoningEffort.allCases
        let wanted = order.firstIndex(of: t.reasoningEffort) ?? 0
        let got = order.firstIndex(of: effort) ?? 0
        return (t, wanted > got)
    }
}
