import Foundation

/// A rendered Dee DNA split for a cascaded (LAN chat) brain — providers-wake-onboarding §2.
///
/// Measured on Ollama: every system message is hoisted to the top of the prompt, so a
/// per-response DNA system item between turns would invalidate the cached prefix on
/// every reply. The cascaded `ChatBackend` therefore sends the slow-changing sections
/// as one system message (resent only when its bytes change) and the per-turn ones
/// with the user message.
///
/// - `stable`: sections 1 IDENTITY, 2 TEMPERAMENT, 4 TOWARD THIS PERSON,
///   5 WHAT YOU KNOW ABOUT THEM, 6 WHO YOU ARE, 9 HOW TO RESPOND.
/// - `volatile`: the header (section 0: "DEE DNA …" and the never-say line),
///   3 FEELINGS NOW, 7 RIGHT NOW (with the host's "Keep in mind" notes), 8 THIS TURN.
///
/// Mode 1 (gpt-realtime) never uses this: it keeps the single DNA system item.
/// Pure: works on the text `DNAPrompt.render` produced; every line is kept exactly once.
public struct DNASplit: Sendable, Equatable {
    public static let stableSections: Set<Int> = [1, 2, 4, 5, 6, 9]

    public var stable: String
    public var volatile: String

    public init(_ dnaText: String) {
        let parts = Self.sections(of: dnaText)
        let order = parts.keys.sorted()
        stable = order.filter { Self.stableSections.contains($0) }.compactMap { parts[$0] }.joined(separator: "\n")
        volatile = order.filter { !Self.stableSections.contains($0) }.compactMap { parts[$0] }.joined(separator: "\n")
    }

    /// Section number → its lines (heading included), in text order. Lines before the
    /// first numbered heading are section 0. A heading is a line "N WORD…" with N 1–9
    /// and an upper-case first letter after the space (e.g. "7 RIGHT NOW").
    public static func sections(of dnaText: String) -> [Int: String] {
        var result: [Int: [Substring]] = [:]
        var current = 0
        for line in dnaText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let n = heading(line) { current = n }
            result[current, default: []].append(line)
        }
        return result.mapValues { $0.joined(separator: "\n") }
    }

    static func heading(_ line: Substring) -> Int? {
        let chars = Array(line.prefix(3))
        guard chars.count == 3, let d = chars[0].wholeNumberValue, (1...9).contains(d), chars[1] == " ",
              chars[2].isUppercase else { return nil }
        // "1 IDENTITY", not "3 cats" or a line of section text that happens to start with a digit.
        let word = line.dropFirst(2).prefix { !$0.isWhitespace && $0 != "(" }
        guard word.count >= 3, word.allSatisfy({ $0.isUppercase || $0 == "-" }) else { return nil }
        return d
    }
}
