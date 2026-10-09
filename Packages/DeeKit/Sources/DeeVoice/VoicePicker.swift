import Foundation

/// A synthesizer voice, reduced to what matters for choosing one (testable without AVFoundation).
public struct VoiceCandidate: Sendable, Equatable {
    public enum Gender: Sendable, Equatable { case unspecified, male, female }

    public var identifier: String
    public var name: String
    public var language: String        // BCP-47, e.g. "en-US"
    /// 1 default, 2 enhanced, 3 premium (AVSpeechSynthesisVoiceQuality raw values).
    public var quality: Int
    public var gender: Gender
    public var isNovelty: Bool
    public var isPersonal: Bool

    public init(identifier: String, name: String, language: String, quality: Int,
                gender: Gender = .unspecified, isNovelty: Bool = false, isPersonal: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.gender = gender
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }
}

/// Picks Dee's voice: English only, best quality first (premium > enhanced >
/// default), then the user's own English region, then a female voice ("she"),
/// never novelty or Personal Voice voices.
public enum VoicePicker {
    public static func best(_ voices: [VoiceCandidate], preferredLanguage: String) -> VoiceCandidate? {
        let pref = preferredLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
        let english = voices.filter {
            $0.language.lowercased().hasPrefix("en") && !$0.isNovelty && !$0.isPersonal
        }
        return english.max { a, b in
            let sa = score(a, pref), sb = score(b, pref)
            if sa != sb { return sa < sb }
            return a.identifier > b.identifier   // deterministic: smaller identifier wins
        }
    }

    static func score(_ v: VoiceCandidate, _ pref: String) -> Int {
        var s = min(max(v.quality, 1), 3) * 1000
        let lang = v.language.replacingOccurrences(of: "_", with: "-").lowercased()
        if lang == pref { s += 200 } else if pref.hasPrefix("en"), lang == "en-us" { s += 100 }
        if v.gender == .female { s += 50 }
        return s
    }
}
