import Foundation

// SELF.md §6.2 — the note catalogue. Every note is a template with short slots;
// slot caps keep each rendered note ≤ 30 tokens (`ceil(chars/3)`, worst case).

public struct Note: Sendable, Equatable {
    public enum Role: String, Sendable, Codable { case aim, context }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case deeBoundary, reconciled, userBoundary, cutOff, misread, lesson, followUp, followUpGentle,
             deixisResolved, deixisAmbiguous, deixisUnknown, recall, intention, hypothesis, hesitation,
             tasteReveal, gagCallback, reunion, awkwardRepair

        /// Lower = more important (§6.2).
        public var priority: Int {
            switch self {
            case .deeBoundary: 1
            case .reconciled: 2
            case .userBoundary: 3
            case .cutOff: 4
            case .misread: 5
            case .lesson: 6
            case .followUp, .followUpGentle: 7
            case .deixisResolved, .deixisAmbiguous, .deixisUnknown: 8
            case .recall: 9
            case .intention: 10
            case .hypothesis: 11
            case .hesitation: 12
            case .tasteReveal: 13
            case .gagCallback: 14
            case .reunion: 15
            case .awkwardRepair: 16
            }
        }

        public var role: Role {
            switch self {
            case .deeBoundary, .reconciled, .misread, .followUp, .followUpGentle, .deixisAmbiguous, .deixisUnknown,
                 .intention, .gagCallback, .awkwardRepair: .aim
            case .userBoundary, .cutOff, .lesson, .deixisResolved, .recall, .hypothesis, .hesitation, .tasteReveal, .reunion: .context
            }
        }

        /// Kinds dropped while a distress hypothesis is live (§6.3). A cheerful
        /// follow-up ("ask how their party went") is too (review finding 5); the gentle
        /// one stays.
        public var playfulOrTopical: Bool {
            switch self {
            case .tasteReveal, .gagCallback, .recall, .intention, .followUp: true
            default: false
            }
        }
    }

    public var kind: Kind
    /// Slot values, already lexicon-safe (labels, subjects, templates).
    public var slots: [String]
    /// Chosen by NotePicker (seeded, no immediate repeat).
    public var variant: Int
    /// The intention this aim serves (marked issued when the note is emitted).
    public var intention: UUID?
    /// The episode a recall note cites (cooldown key).
    public var episode: UUID?
    /// The facet a taste reveal reveals.
    public var facet: UUID?
    /// The gag a callback uses.
    public var gag: UUID?
    /// The sub-reducer that raised it (`Ongoing.raise(_:by:)` sets it). Every reducer's
    /// `noteIssued` sees every issued note; the owner does the bookkeeping.
    public var owner: String?
    /// When it was raised (Cortex stamps it after the step). Context-bound kinds go
    /// stale after `NotePicker.staleAfter` (review finding 18). Not part of `==`.
    public var raisedAt: Date?

    public static func == (a: Note, b: Note) -> Bool {
        a.kind == b.kind && a.slots == b.slots && a.variant == b.variant && a.intention == b.intention && a.episode == b.episode
            && a.facet == b.facet && a.gag == b.gag && a.owner == b.owner
    }

    public init(_ kind: Kind, slots: [String] = [], variant: Int = 0, intention: UUID? = nil, episode: UUID? = nil, facet: UUID? = nil,
                gag: UUID? = nil, owner: String? = nil) {
        self.kind = kind
        self.slots = slots
        self.variant = variant
        self.intention = intention
        self.episode = episode
        self.facet = facet
        self.gag = gag
        self.owner = owner
    }

    public var role: Role { kind.role }
    public var priority: Int { kind.priority }
    /// The rendered, parenthesised note.
    public var text: String { NoteTemplates.render(kind, slots: slots, variant: variant) }

    // MARK: Factories (one per catalogue row)

    public static func deeBoundary() -> Note { Note(.deeBoundary) }
    public static func reconciled() -> Note { Note(.reconciled) }
    public static func userBoundary(_ topic: Subject) -> Note { Note(.userBoundary, slots: [topic.text]) }
    /// Several boundary topics in one note ("job, money"), cut at a whole topic to fit the slot.
    public static func userBoundaries(_ topics: [Subject]) -> Note {
        var parts: [String] = []
        for t in topics where (parts + [t.text]).joined(separator: ", ").count <= Subject.maxCharacters { parts.append(t.text) }
        return Note(.userBoundary, slots: [parts.joined(separator: ", ")])
    }
    public static func cutOff() -> Note { Note(.cutOff) }
    public static func misread(notX: String) -> Note { Note(.misread, slots: [notX]) }
    public static func lesson(_ doInstead: String) -> Note { Note(.lesson, slots: [doInstead]) }
    public static func followUp(_ subject: Subject, framing: Expectation.Framing, gentle: Bool = false, intention: UUID? = nil) -> Note {
        gentle ? Note(.followUpGentle, intention: intention)
               : Note(.followUp, slots: [subject.text, framing.rawValue], intention: intention)
    }
    public static func deixisResolved(_ label: Subject) -> Note { Note(.deixisResolved, slots: [label.text]) }
    public static func deixisAmbiguous(_ a: Subject, _ b: Subject) -> Note { Note(.deixisAmbiguous, slots: [a.text, b.text]) }
    public static func deixisUnknown() -> Note { Note(.deixisUnknown) }
    public static func recall(gist: String, episode: UUID) -> Note { Note(.recall, slots: [gist], episode: episode) }
    public static func intention(nextAction: String, intention: UUID) -> Note { Note(.intention, slots: [nextAction], intention: intention) }
    public static func hypothesis(_ value: String) -> Note { Note(.hypothesis, slots: [value]) }
    public static func hesitation() -> Note { Note(.hesitation) }
    public static func tasteReveal(_ subject: Subject, loves: Bool, facet: UUID) -> Note {
        Note(.tasteReveal, slots: [loves ? "love" : "odd", subject.text], facet: facet)
    }
    /// `hook`: the gag's rendered hook ("the dentist incident"); when given, the note
    /// names the joke itself so the model has something real to call back to.
    public static func gagCallback(_ topic: Subject, style: HumourStyle, hook: String? = nil, gag: UUID) -> Note {
        Note(.gagCallback, slots: [topic.text, style.rawValue] + (hook.map { [$0] } ?? []), gag: gag)
    }
    public static func reunion() -> Note { Note(.reunion) }
    public static func awkwardRepair() -> Note { Note(.awkwardRepair) }
}

public enum NoteTemplates {
    /// Number of wording variants per kind.
    public static func variants(_ kind: Note.Kind) -> Int {
        switch kind {
        case .cutOff, .reunion, .hesitation, .awkwardRepair: 2
        default: 1
        }
    }

    /// Maximum characters per slot, chosen so the longest render is ≤ 90 characters
    /// (30 tokens at `ceil(chars/3)`).
    public static func slotCaps(_ kind: Note.Kind) -> [Int] {
        switch kind {
        case .userBoundary: [Subject.maxCharacters]
        case .misread: [11]
        case .lesson: [76]
        case .followUp: [Subject.maxCharacters, 7]
        case .deixisResolved: [Subject.maxCharacters]
        case .deixisAmbiguous: [24, 24]
        case .recall: [72]
        case .intention: [88]
        case .hypothesis: [24]
        case .tasteReveal: [4, Subject.maxCharacters]
        case .gagCallback: [24, 20, 40]
        default: []
        }
    }

    /// Longest legal slot values (for the ≤ 30-token test).
    public static func longestSlots(_ kind: Note.Kind) -> [String] {
        switch kind {
        case .tasteReveal: ["odd", String(repeating: "x", count: Subject.maxCharacters)]
        case .gagCallback: [String(repeating: "x", count: 24), HumourStyle.selfDeprecatingRobot.rawValue, String(repeating: "x", count: 40)]
        case .followUp: [String(repeating: "x", count: Subject.maxCharacters), "neutral"]
        default: slotCaps(kind).map { String(repeating: "x", count: $0) }
        }
    }

    /// Cuts `s` to `cap` characters at a word boundary (no partial words).
    public static func fit(_ s: String, _ cap: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > cap else { return t }
        let cut = String(t.prefix(cap))
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]).trimmingCharacters(in: .punctuationCharacters) }
        return cut
    }

    static func gagStyle(_ raw: String) -> String {
        switch HumourStyle(rawValue: raw) {
        case .wordplay: "with a pun"
        case .deadpan: "deadpan"
        case .absurd: "absurdly"
        case .gentleTeasing: "teasing gently"
        case .selfDeprecatingRobot: "at your own expense"
        case nil: "lightly"
        }
    }

    public static func render(_ kind: Note.Kind, slots raw: [String], variant: Int) -> String {
        let caps = slotCaps(kind)
        let s: [String] = caps.enumerated().map { i, cap in i < raw.count ? fit(raw[i], cap) : "" }
        let v = variants(kind) > 1 ? abs(variant) % variants(kind) : 0
        switch kind {
        case .deeBoundary: return "(Calmly say you don't like being spoken to that way.)"
        case .reconciled: return "(They made up with you. Accept warmly and briefly; don't dwell.)"
        case .userBoundary: return "(Don't bring up \(s[0]).)"
        case .cutOff:
            return v == 0 ? "(You were cut off mid-reply; don't repeat it unless asked.)"
                          : "(They cut in while you were talking; let it go unless they ask.)"
        case .misread: return "(You misread them: not \(s[0]). Own it in a few words, then check what they meant.)"
        case .lesson: return "(Careful: \(s[0]).)"
        case .followUp:
            // "They were neutral about it" says nothing (review finding 10).
            return s[1] == Expectation.Framing.neutral.rawValue || s[1].isEmpty
                ? "(Ask how their \(s[0]) went.)" : "(Ask how their \(s[0]) went. They were \(s[1]) about it.)"
        case .followUpGentle: return "(Gently ask how they've been feeling.)"
        case .deixisResolved: return "(\"That\" is probably the \(s[0]).)"
        case .deixisAmbiguous: return "(\"That\" might be the \(s[0]) or the \(s[1]); ask which.)"
        case .deixisUnknown: return "(You can't tell what they mean; ask them to show you.)"
        case .recall: return "(You remember: \(s[0]).)"
        case .intention: return "(\(s[0]))"
        case .hypothesis: return "(Maybe they're \(s[0]); don't assume.)"
        case .hesitation:
            return v == 0 ? "(They hesitated; be gentle and patient.)" : "(They're finding their words; be patient and gentle.)"
        case .tasteReveal:
            return s[0] == "love" ? "(You happen to love \(s[1]).)" : "(You happen to find \(s[1]) a bit odd.)"
        case .gagCallback:
            if !s[2].isEmpty { return "(Maybe a quick callback to your running joke: \(s[2]).)" }
            return "(Maybe a quick callback to your \(s[0]) joke, \(gagStyle(s[1])).)"
        case .reunion:
            return v == 0 ? "(They're back; be glad to see them. Never guilt them for being away.)"
                          : "(They're back; be happy to see them. Never guilt them for being away.)"
        case .awkwardRepair:
            return v == 0 ? "(That was a bit awkward; a light word about it is fine.)"
                          : "(That felt a little awkward; a light word about it is fine.)"
        }
    }
}
