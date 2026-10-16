import Foundation

/// Why a wake phrase was refused. `reason` is short and speakable (she says it when
/// the phrase was changed by voice; settings show it under the field).
public enum WakePhraseError: Error, Sendable, Equatable {
    case empty
    case tooManyWords(Int)
    case tooLong(Int)
    case invalidCharacters
    /// The phrase is (or contains only) one of her commands: "stop", "go to sleep" …
    case isCommand(String)

    public var reason: String {
        switch self {
        case .empty: "A wake phrase needs at least one word."
        case .tooManyWords: "A wake phrase can be one to four words."
        case .tooLong: "That's too long for a wake phrase. Keep it under 32 letters."
        case .invalidCharacters: "A wake phrase can only use letters, spaces, apostrophes and hyphens."
        case .isCommand(let c): "\"\(c)\" is one of my commands, so it can't wake me."
        }
    }
}

/// The phrase that wakes her, heard only on the device.
///
/// One to four words of letters (plus `'` and `-`), at most 32 characters, and not one
/// of her commands. `aliases` are explicit alternative spellings the recogniser writes
/// for the phrase (the only tier that may match fewer words than the phrase has).
public struct WakePhrase: Sendable, Equatable, Hashable, CustomStringConvertible {
    public static let defaultText = "Hey Dee"
    public static let `default` = try! WakePhrase(validating: defaultText)
    public static let shortPhraseWarning = "Short phrases wake her by accident more often."
    public static let maxWords = 4
    public static let maxCharacters = 32

    /// As typed: trimmed, inner whitespace collapsed ("Hey Dee").
    public let text: String
    /// Normalised words (`["hey", "dee"]`).
    public let words: [String]

    public init(validating raw: String) throws(WakePhraseError) {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { throw .empty }
        guard collapsed.count <= Self.maxCharacters else { throw .tooLong(collapsed.count) }
        let allowed = collapsed.allSatisfy { $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" || $0 == "-" }
        guard allowed else { throw .invalidCharacters }
        let spaced = collapsed.split(separator: " ")
        guard spaced.count <= Self.maxWords else { throw .tooManyWords(spaced.count) }
        let normal = WakeText.words(collapsed)
        guard !normal.isEmpty else { throw .empty }
        guard normal.count <= Self.maxWords else { throw .tooManyWords(normal.count) }
        let joined = normal.joined(separator: " ")
        if Self.commands.contains(joined) { throw .isCommand(collapsed) }
        text = collapsed
        words = normal
    }

    public var description: String { text }

    /// Normalised phrase ("hey dee").
    public var normalized: String { words.joined(separator: " ") }

    public var key: PhoneticKey { PhoneticKey(words: words) }

    /// One word whose sound key has three letters or fewer ("Dee", "Bob", "Max").
    public var isShort: Bool { words.count == 1 && key.value.count <= 3 }

    /// Normalised alternative spellings. Every phrase has its words joined ("heydee",
    /// "heyrobo"); the default phrase also has the measured recogniser spellings.
    public var aliases: [String] {
        var a: [String] = []
        if words.count > 1 { a.append(words.joined()) }
        if let known = Self.knownAliases[normalized] { a += known }
        return a
    }

    /// Strings for the analyzer's contextual vocabulary (helps DictationTranscriber
    /// write "Hey Dee" instead of "Hey D" — measured, wake-map-sdk).
    public var contextualStrings: [String] {
        var s = [text]
        if words.count > 1, let last = text.split(separator: " ").last { s.append(String(last)) }
        if !s.contains(where: { $0.caseInsensitiveCompare("Dee") == .orderedSame }) { s.append("Dee") }
        return s
    }

    /// Measured recogniser spellings (wake-map-sdk, WakeCorpus). Normalised.
    static let knownAliases: [String: [String]] = [
        "hey dee": ["heidi", "haidee", "kd", "hey d", "hi dee", "haydee", "hey de"],
        "hi dee": ["hi d", "hey dee", "haidee", "heidi"],
        "okay pixel": ["okay pixels"],
        "hey robo": ["hey robot", "hey roboh"],
    ]

    /// Her local commands; a wake phrase can't be one (normalised).
    static let commands: Set<String> = [
        "stop", "stop talking", "stop it", "stop that", "be quiet", "quiet", "shush", "hush", "enough", "thats enough",
        "go to sleep", "goodnight", "good night", "time to sleep", "go to bed", "stop listening", "thats all",
        "start over", "new conversation", "keep going", "go on", "wait", "hold on", "yes", "no", "okay",
    ]
}

extension WakePhrase: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do { self = try WakePhrase(validating: s) } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: error.reason)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}
