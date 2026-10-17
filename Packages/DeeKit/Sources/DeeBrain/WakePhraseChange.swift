import DeeCore
import DeeWake
import Foundation

/// "Change your wake phrase to X" by voice (providers-wake-onboarding §4): Dee repeats
/// the phrase and asks; "yes" within `confirmWindow` saves it, "no" keeps the old one,
/// anything else (or silence past the window) drops the proposal. An invalid phrase is
/// refused at once with Dee's reason. Pure: the host speaks the lines (local clips or the
/// open session) and persists the saved phrase.
public struct WakePhraseChange: Sendable, Equatable {
    public static let confirmWindow: TimeInterval = 20

    public struct Pending: Sendable, Equatable {
        public var phrase: WakePhrase
        public var at: Date
    }

    public enum Prompt: Sendable, Equatable {
        /// Asks to confirm: "My wake phrase will be “X”. Is that right?"
        case confirm(WakePhrase, line: String)
        /// Refused at once with Dee's reason.
        case invalid(line: String)
        /// The phrase Dee already has.
        case unchanged(line: String)
    }

    public enum Outcome: Sendable, Equatable {
        case saved(WakePhrase, line: String)
        case kept(line: String)
    }

    public private(set) var pending: Pending?

    public init() {}

    public mutating func propose(_ raw: String, current: WakePhrase, at now: Date) -> Prompt {
        pending = nil
        let phrase: WakePhrase
        do {
            phrase = try WakePhrase(validating: raw)
        } catch {
            return .invalid(line: "I can't use that as my wake phrase. \(error.reason)")
        }
        if phrase.words == current.words { return .unchanged(line: "That's already my wake phrase.") }
        pending = Pending(phrase: phrase, at: now)
        var line = "My wake phrase will be “\(phrase.text)”. Is that right?"
        if phrase.isShort { line += " " + WakePhrase.shortPhraseWarning }
        return .confirm(phrase, line: line)
    }

    /// The answer to the confirmation, or nil when nothing is pending, it expired, or
    /// the words are not a yes or a no (the proposal is dropped and the words are
    /// ordinary conversation).
    public mutating func answer(_ utterance: String, current: WakePhrase, at now: Date) -> Outcome? {
        guard let p = pending else { return nil }
        guard now.timeIntervalSince(p.at) <= Self.confirmWindow else {
            pending = nil
            return nil
        }
        guard let yes = SpokenCommand.confirmation(utterance) else {
            pending = nil
            return nil
        }
        pending = nil
        return yes ? .saved(p.phrase, line: "Okay! Say “\(p.phrase.text)” when you want me.")
            : .kept(line: "Okay, I'll keep “\(current.text)”.")
    }

    public var isPending: Bool { pending != nil }
}
