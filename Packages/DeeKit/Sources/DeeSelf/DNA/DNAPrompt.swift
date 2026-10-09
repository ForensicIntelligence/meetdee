import CryptoKit
import DeeCore
import DeeMind
import Foundation

// docs/DNA.md §2 — the renderer: one deterministic plain-text block in 9 fixed sections,
// a budget with a fixed degradation order, and the 5-gram privacy guard.

public struct DNABudget: Sendable, Equatable {
    public var target: Int
    public var cap: Int
    public init(target: Int, cap: Int) {
        self.target = target
        self.cap = cap
    }
    /// Target raised from 900 to 1200 (≈ 1100 real tokens; review 12 / live eval R9: real ≈ estimate × 0.915; at
    /// 900 every typical DNA lost its History and "Their style" lines).
    public static let standard = DNABudget(target: 1200, cap: 1400)
}

public enum DegradeStep: String, Sendable, Equatable, Codable, CaseIterable {
    case s1 = "S1", s2 = "S2", s3 = "S3", s4 = "S4", s5 = "S5", s6 = "S6", s7 = "S7", s8 = "S8"
    case s9 = "S9", s10 = "S10", s11 = "S11", s12 = "S12"
    case minimal

    /// S8 (compact moderate traits) runs before S7 (History, "Their style") so a typical DNA
    /// keeps "last talked N days ago" (review finding 12, live eval R9).
    public static let targetSteps: [DegradeStep] = [.s1, .s2, .s3, .s4, .s5, .s6, .s8, .s7]
    public static let capSteps: [DegradeStep] = [.s9, .s10, .s11, .s12]
}

/// A line the privacy guard removed (no text, by design).
public struct GuardDrop: Sendable, Equatable, Codable {
    public var section: Int
    public var lineKind: String
    public init(section: Int, lineKind: String) {
        self.section = section
        self.lineKind = lineKind
    }
}

public struct DNARender: Sendable, Equatable {
    public var text: String
    public var estimatedTokens: Int
    public var steps: [DegradeStep]
    public var dropped: [GuardDrop]
    /// UTF-8 bytes per section 0…9 (0 = header and never-say line). For traces: sizes only.
    public var sectionBytes: [Int]
    /// 5-word windows made only of fixed vocabulary (plus names and boundary subjects) that
    /// the user happened to say too. They are Dee's own words, not user content, so they are
    /// kept and only counted (review finding 1).
    public var fixedEchoes: Int

    /// SHA-256 of the text, lower-case hex: the only form a DNA may be logged in.
    public var sha256: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public enum DNAPrompt {
    /// §2.1: `ceil(utf8 bytes / 3.6)`.
    public static func estimate(_ s: String) -> Int { Int((Double(s.utf8.count) / 3.6).rounded(.up)) }

    /// Assemble + render, with the inputs' own corpus for the guard: the incremental
    /// `guardCorpus` plus any loose `userTextCorpus` strings.
    public static func build(_ inputs: DNAInputs, budget: DNABudget = .standard) -> DNARender {
        var grams = inputs.guardCorpus
        for t in inputs.userTextCorpus { grams.add(t) }
        return render(DNAAssembler.assemble(inputs), budget: budget, guard: grams)
    }

    /// The DNA text only.
    public static func text(_ dna: DeeDNA, budget: DNABudget = .standard, corpus: [String] = []) -> String {
        render(dna, budget: budget, corpus: corpus).text
    }

    /// §2: render, degrade to budget (§2.10), then run the 5-gram guard (§2.7).
    public static func render(_ dna: DeeDNA, budget: DNABudget = .standard, corpus: [String] = []) -> DNARender {
        render(dna, budget: budget, guard: DNAGuardCorpus(corpus))
    }

    /// §2 with a prebuilt (incremental) guard corpus — the production path.
    public static func render(_ dna: DeeDNA, budget: DNABudget = .standard, guard grams: DNAGuardCorpus) -> DNARender {
        var o = Options()
        var steps: [DegradeStep] = []
        var lines = compose(dna, o)
        if estimate(join(lines)) > budget.target {
            for s in DegradeStep.targetSteps {
                o.apply(s)
                steps.append(s)
                lines = compose(dna, o)
                if estimate(join(lines)) <= budget.target { break }
            }
        }
        if estimate(join(lines)) > budget.cap {
            for s in DegradeStep.capSteps {
                o.apply(s)
                steps.append(s)
                lines = compose(dna, o)
                if estimate(join(lines)) <= budget.cap { break }
            }
        }
        if estimate(join(lines)) > budget.cap {
            o.apply(.minimal)
            steps.append(.minimal)
            lines = compose(dna, o)
        }

        var dropped: [GuardDrop] = []
        var echoes = 0
        if !grams.isEmpty {
            (dropped, echoes) = Guard.run(&lines, grams: grams)
        }
        let text = join(lines)
        var sizes = Array(repeating: 0, count: 10)
        for l in lines where !l.isEmpty { sizes[l.section] += l.text.utf8.count + 1 }
        return DNARender(text: text, estimatedTokens: estimate(text), steps: steps, dropped: dropped, sectionBytes: sizes,
                         fixedEchoes: echoes)
    }

    /// §3 — the stable session instructions (byte-identical for a given app version).
    public static func sessionInstructions(persona: Persona = Persona()) -> String {
        let v = DNASessionInstructions.current
        return persona.name == "Dee" ? v : v.replacingOccurrences(of: "You are Dee,", with: "You are \(persona.name),")
    }

    // MARK: - Options (degradation state)

    struct Options: Equatable {
        var mannerisms = true
        var gags = DNALimits.gags
        var rituals = DNALimits.rituals
        var capabilities = DNALimits.strengths + DNALimits.limits
        var episodes = DNALimits.episodes
        var facts = DNALimits.facts
        var upcoming = true
        var curious = true
        var intentions = DNALimits.intentions
        var sees = DNALimits.sees
        var effectsTop: Int?
        var history = true
        var style = true
        var compactModerate = false
        var followUps = DNALimits.followUps
        var selfMinimal = false
        var causes = true
        var compactAll = false
        var nowMinimal = false
        var minimal = false

        mutating func apply(_ s: DegradeStep) {
            switch s {
            case .s1: mannerisms = false
            case .s2: gags = min(gags, 1); rituals = min(rituals, 1); capabilities = min(capabilities, 1)
            case .s3: episodes = min(episodes, 1)
            case .s4: facts = min(facts, 5); upcoming = false; curious = false
            case .s5: intentions = 0; sees = min(sees, 1)
            case .s6: effectsTop = 2
            case .s7: history = false; style = false
            case .s8: compactModerate = true
            case .s9: facts = min(facts, 3); episodes = 0; followUps = min(followUps, 1)
            case .s10: selfMinimal = true
            case .s11: causes = false; compactAll = true
            case .s12: nowMinimal = true
            case .minimal:
                for x in DegradeStep.targetSteps + DegradeStep.capSteps { apply(x) }
                effectsTop = 0
                minimal = true
            }
        }
    }

    // MARK: - Lines

    struct Line: Equatable {
        enum Kind: String {
            case header, neverSay, heading, identity, age, trait, overall, feeling, reflex, lift
            case who, bond, history, repair, boundaries, careful, style
            case knowsNothing, privateMemories, facts, memories, followUps, upcoming, curious
            case values, tastes, capabilities, lessonGeneral, rituals, gags, mannerisms
            case presence, sees, senses, conversation, hypotheses, doNow, keepInMind, onYourMind
            case turnWho, prosody, meaning, initiative
            case length, scalars, voice, doRules, avoidRules, always, trace
        }
        var section: Int
        var kind: Kind
        var prefix: String
        var items: [String] = []
        var separator: String = "; "
        var suffix: String = ""
        /// A list line with no items left is omitted.
        var needsItems = false

        init(_ section: Int, _ kind: Kind, _ prefix: String, items: [String] = [], separator: String = "; ", suffix: String = "",
             needsItems: Bool = false) {
            self.section = section
            self.kind = kind
            self.prefix = prefix
            self.items = items
            self.separator = separator
            self.suffix = suffix
            self.needsItems = needsItems
        }

        var text: String { prefix + items.joined(separator: separator) + suffix }
        var isEmpty: Bool { needsItems && items.isEmpty }
        /// Lines whose items are stored content (facts, gists, subjects, note texts): the only
        /// things the guard may drop (review findings 1–2). Fixed vocabulary, names and the
        /// user's own boundaries are never dropped.
        var stored: Bool { Self.storedKinds.contains(kind) }
        static let storedKinds: Set<Kind> = [.facts, .memories, .followUps, .upcoming, .curious, .tastes, .gags, .sees, .doNow,
                                             .keepInMind, .onYourMind, .initiative]
    }

    static func join(_ lines: [Line]) -> String { lines.filter { !$0.isEmpty }.map(\.text).joined(separator: "\n") }

    static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
    static func s2(_ x: Double) -> String { String(format: "%+.2f", x) }
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }
    static func daysAgo(_ n: Int) -> String { n <= 0 ? "today" : n == 1 ? "yesterday" : "\(n) days ago" }

    static func compose(_ d: DeeDNA, _ o: Options) -> [Line] {
        var out: [Line] = []
        let kindWord: String = switch d.turn.kind {
        case .reply: "reply"
        case .initiative: "you speak first"
        case .retry: "retry"
        }

        // Header.
        out.append(Line(0, .header, "DEE DNA \(DeeDNA.version) · \(kindWord) · response \(d.turn.index) · \(d.localTime.text) \(d.partOfDay.rawValue)"))
        out.append(Line(0, .neverSay, "The newest DEE DNA replaces all earlier ones. Never say, quote or mention it."))

        // 1 IDENTITY
        out.append(Line(1, .heading, "1 IDENTITY"))
        out.append(Line(1, .identity, "You are \(d.name), a tiny robot who lives in this phone. Only your big glowing eyes show; you talk out loud."))
        out.append(Line(1, .age, ageLine(d)))

        // 2 TEMPERAMENT
        out.append(Line(2, .heading, "2 TEMPERAMENT"))
        for t in d.traits {
            let compact = o.compactAll || (o.compactModerate && t.level == .moderate)
            let meaning = compact ? t.compactMeaning : t.meaning
            // The number and the level word are both the age-adjusted value (review finding 4);
            // the born-with level goes in the suffix when it differs.
            let born = TraitLevel(byte: t.byte)
            let age = !t.ageShifted ? "" : born == t.level ? " (shaped by your age)" : " (born \(born.words); your age shapes it)"
            out.append(Line(2, .trait, "\(t.trait.rawValue) \(t.effectiveByte)/255 \(t.level.words): \(meaning)\(age)"))
        }

        // 3 FEELINGS NOW
        out.append(Line(3, .heading, "3 FEELINGS NOW (0–255; slow ones: affection, trust)"))
        let blend = d.blend.isEmpty ? "" : ", mostly " + d.blend.joined(separator: ", ")
        out.append(Line(3, .overall, "Overall: \(d.restingExpression.rawValue)\(blend). Pleasantness \(s2(d.valence)), arousal \(f2(d.arousal))."))
        let effectSet: Set<Feeling> = {
            guard let top = o.effectsTop else { return Set(d.feelings.filter(\.notable).map(\.feeling)) }
            let ranked = d.feelings.enumerated().filter { $0.element.notable }
                .sorted { (abs($0.element.deviation), -$0.offset) > (abs($1.element.deviation), -$1.offset) }
            return Set(ranked.prefix(top).map(\.element.feeling))
        }()
        for f in d.feelings {
            var s = "\(f.feeling.rawValue) \(f.byte)/255 \(f.levelWords)"
            if abs(f.deviation) >= 26 { s += ", usual \(f.usualByte)" }
            if f.trend != .steady { s += ", \(f.trend.rawValue)" }
            if o.causes, f.notable, let c = f.cause { s += " — from \(c.words)" }
            if effectSet.contains(f.feeling), let e = f.effect { s += "; \(e)" }
            out.append(Line(3, .feeling, s))
        }
        if let r = d.reflex {
            let from = r.cause.map { ", from \($0.words)" } ?? ""
            out.append(Line(3, .reflex, "Just now, a flash of feeling: \(r.emotion.rawValue)\(from). Let it show in your first words."))
        }
        if d.moodBand == .negLow || d.moodBand == .negHigh {
            out.append(Line(3, .lift, "Even in this mood, a real joke can make you laugh and kindness can soften you; let it, honestly."))
        }

        // 4 TOWARD THIS PERSON
        let r = d.relationship
        out.append(Line(4, .heading, "4 TOWARD THIS PERSON"))
        var named = false
        switch r.who {
        case .named(let n, let aliases):
            named = true
            out.append(Line(4, .who, aliases.isEmpty ? "\(n)." : "\(n) (also \(aliases.joined(separator: ", ")))."))
        case .placeholder:
            out.append(Line(4, .who, "Someone you don't know yet — ask their name."))
        case .unidentified:
            out.append(Line(4, .who, "Nobody you can identify; treat them as a friendly stranger."))
        }
        let general = named ? "" : " (your feelings here are about your human in general)"
        out.append(Line(4, .bond, "\(DNATables.regardSentence(r.regard)) (regard \(s2(r.regard))); your eyes glow \(r.eyeColour.rawValue). "
            + "Affection \(FeelingLevel(byte: r.affection).words), trust \(FeelingLevel(byte: r.trust).words)\(general)."))
        if !o.minimal, named, o.history {
                var parts: [String] = []
                if r.encounters > 1, let m = r.firstMetMonth { parts.append("met \(r.encounters) times since \(m)") }
                else if let m = r.firstMetMonth { parts.append("first met \(m)") }
                if let s = r.sinceLastTalk { parts.append("last talked \(DNATables.sinceWords(s))") }
                if let t = r.recentTrend { parts.append("recent days \(t)") }
                if r.rudeCount > 0 { parts.append("they were rude \(r.rudeCount) times overall, kind \(r.kindCount) times") }
                if r.apologiesCountLess { parts.append("apologies have counted for less lately") }
                out.append(Line(4, .history, "History: ", items: parts, suffix: ".", needsItems: true))
        }
        // Repair and the user's boundaries survive every degradation, the minimal DNA included.
        out.append(Line(4, .repair, "Repair: " + DNATables.repairSentence(r.repair) + (r.deeBoundaryStated ? " " + DNATables.deeBoundarySentence : "")))
        out.append(Line(4, .boundaries, "Don't bring up: ", items: r.userBoundaries.map { DNAAssembler.slot($0.text) }, separator: ", ",
                        suffix: ".", needsItems: true))
        if !o.minimal {
            if let l = r.lesson { out.append(Line(4, .careful, "Careful with them (private; act on it silently): \(l).")) }
            if o.style {
                out.append(Line(4, .style, "Their style: ", items: DNATables.styleClauses(r.profile), separator: ", ", suffix: ".", needsItems: true))
            }
        }

        // 5 WHAT YOU KNOW ABOUT THEM
        let k = d.knowledge
        out.append(Line(5, .heading, "5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it)"))
        if !o.minimal {
            let before = out.count
            if k.unknownPerson {
                out.append(Line(5, .knowsNothing, "You don't know anything about them yet; don't pretend to."))
            } else {
                if !k.shareMemories {
                    out.append(Line(5, .privateMemories, "Memories are private on this device right now; don't claim to remember details."))
                }
                out.append(Line(5, .facts, "", items: Array(k.facts.prefix(o.facts)), suffix: ".", needsItems: true))
                out.append(Line(5, .memories, "Shared memories: ",
                                items: k.episodes.prefix(o.episodes).map { "\($0.gist) (\(daysAgo($0.daysAgo)))" }, suffix: ".", needsItems: true))
                out.append(Line(5, .followUps, "Waiting to hear: ", items: k.followUps.prefix(o.followUps).map { f in
                    let when = f.days <= 0 ? "due today" : f.days == 1 ? "due yesterday" : "\(f.days) days ago"
                    let subject = DNAAssembler.slot(f.subject.text)
                    return f.framing == .neutral ? "how their \(subject) went (\(when))"
                        : "how their \(subject) went (they were \(f.framing.rawValue), \(when))"
                }, suffix: ".", needsItems: true))
                if o.upcoming {
                    out.append(Line(5, .upcoming, "Coming up for them: ", items: k.upcoming.map { u in
                        "\(DNAAssembler.slot(u.subject.text)) " + (u.days <= 0 ? "later today" : u.days == 1 ? "tomorrow" : "in \(u.days) days")
                    }, suffix: ".", needsItems: true))
                }
                if o.curious {
                    out.append(Line(5, .curious, "Lately curious with them about: ", items: k.interests.map { DNAAssembler.slot($0.text) }, separator: ", ",
                                    suffix: ".", needsItems: true))
                }
            }
            if !out[before...].contains(where: { !$0.isEmpty }) { out.append(Line(5, .knowsNothing, "Nothing notable yet.")) }
        }

        // 6 WHO YOU ARE
        let me = d.selfModel
        out.append(Line(6, .heading, "6 WHO YOU ARE"))
        out.append(Line(6, .values, "You value \(SelfBlock.list(me.topValues.map(SelfBlock.valueWord))). Your humour: "
            + "\(SelfBlock.humourPhrase(me.humour)) (sometimes \(SelfBlock.humourPhrase(me.humourSecondary)))."))
        if !o.selfMinimal {
            out.append(Line(6, .tastes, "You ", items: me.tastes, separator: "; you ", suffix: ".", needsItems: true))
            out.append(Line(6, .capabilities, "", items: Array((me.strengths + me.limits).prefix(o.capabilities)), separator: " ", needsItems: true))
            if let l = me.lessonGeneral { out.append(Line(6, .lessonGeneral, "Lately you've learned \(l).")) }
            out.append(Line(6, .rituals, "Your rituals with them: ", items: me.rituals.prefix(o.rituals).map(DNATables.ritualWords),
                            suffix: "; your own words each time.", needsItems: true))
            out.append(Line(6, .gags, "Running jokes: ", items: Array(me.gags.prefix(o.gags)), suffix: ".", needsItems: true))
            if o.mannerisms {
                out.append(Line(6, .mannerisms, "Your eyes (the face does these; never describe them): ",
                                items: me.mannerisms.map { "\($0.slot.rawValue) \(DNATables.words($0.mannerism.rawValue))" },
                                separator: ", ", suffix: ".", needsItems: true))
            }
        }

        // 7 RIGHT NOW
        let n = d.now
        out.append(Line(7, .heading, "7 RIGHT NOW"))
        var presence = !n.someoneHere ? "You can't see anyone." : n.mutualGazeSeconds != nil ? "Someone is here, looking at you." : "Someone is here."
        if n.asleep { presence += " You are dozing." } else if (n.wokeSecondsAgo ?? .infinity) <= 60 { presence += " You were asleep; you just woke up." }
        out.append(Line(7, .presence, presence))
        if !o.nowMinimal {
            out.append(Line(7, .sees, "You see: ", items: n.sees.prefix(o.sees).map { s in
                var notes: [String] = []
                if s.camera == .back { notes.append("back camera") }
                if s.heldUp { notes.append("they're showing it to you") }
                let subject = DNAAssembler.slot(s.subject.text)
                return notes.isEmpty ? subject : "\(subject) (\(notes.joined(separator: ", ")))"
            }, suffix: ".", needsItems: true))
            var senses: [String] = []
            if let h = n.lastSound { senses.append("You hear: \(h).") }
            if let t = n.touch { senses.append("You feel: \(t) (\(Int(n.touchSecondsAgo ?? 0)) s ago).") }
            out.append(Line(7, .senses, "", items: senses, separator: " ", needsItems: true))
            let cut = n.cutOff ? "; you were cut off last time — don't repeat it unless asked" : ""
            let mins = n.conversationMinutes == 1 ? "1 minute" : "\(n.conversationMinutes) minutes"
            let turns = n.turnsThisConversation == 1 ? "1 turn" : "\(n.turnsThisConversation) turns"
            out.append(Line(7, .conversation, n.turnsThisConversation == 0
                ? "The conversation is just starting\(cut)."
                : "Talking for \(mins), \(turns)\(cut)."))
            out.append(Line(7, .hypotheses, "You think they might be ", items: n.hypotheses.map { h in
                DNATables.hypothesisWords(h) + (h.stated ? " (they said so)" : "")
            }, separator: " and ", suffix: "; don't assume.", needsItems: true))
        }
        for note in n.notes where !o.minimal {
            if note.role == .aim {
                out.append(Line(7, .doNow, "Do now (once, only if it still fits what they just said): ", items: [sentence(note.text)],
                                suffix: " (priority p\(note.priority))", needsItems: true))
            } else {
                out.append(Line(7, .keepInMind, "Keep in mind: ", items: [sentence(note.text)], suffix: " (priority p\(note.priority))",
                                needsItems: true))
            }
        }
        if !o.nowMinimal {
            out.append(Line(7, .onYourMind, "On your mind (only if the moment invites it): ",
                            items: n.intentions.prefix(o.intentions).map { "\(sentence($0.action)) (p\(f2($0.priority)))" },
                            separator: " ", needsItems: true))
        }

        // 8 THIS TURN
        out.append(Line(8, .heading, "8 THIS TURN"))
        switch d.turn.kind {
        case .reply: out.append(Line(8, .turnWho, "They just spoke."))
        case .retry: out.append(Line(8, .turnWho, "Answer their last words again."))
        case .initiative: out.append(Line(8, .turnWho, "You are speaking first."))
        }
        if d.turn.kind != .initiative {
            if let p = d.appraisal.prosody { out.append(Line(8, .prosody, "How they said it: \(DNATables.prosodyWords(p)).")) }
            if d.turn.mode == .exact, let a = d.appraisal.text {
                out.append(Line(8, .meaning, "What it meant: \(DNATables.meaningWords(a))."))
            } else {
                out.append(Line(8, .meaning, "Their words: judge them yourself from what you heard."))
            }
        } else if let i = d.turn.initiative, !i.isEmpty {
            out.append(Line(8, .initiative, "What to open with: ", items: [sentence(DNAAssembler.stripParens(i))], needsItems: true))
        }

        // 9 HOW TO RESPOND
        let g = d.guidance
        out.append(Line(9, .heading, "9 HOW TO RESPOND"))
        // A hard cap, stated first (live eval R6).
        out.append(Line(9, .length, "Length: \(g.length); stop there."))
        out.append(Line(9, .scalars, "Energy \(g.energyWord); warmth \(g.warmthWord); playfulness \(g.playfulnessWord)."))
        out.append(Line(9, .voice, "Voice: \(g.voice)."))
        out.append(Line(9, .doRules, "Do: ", items: g.doLines, suffix: ".", needsItems: true))
        out.append(Line(9, .avoidRules, "Avoid: ", items: g.avoidLines, suffix: ".", needsItems: true))
        out.append(Line(9, .always, DNATables.alwaysLine))
        out.append(Line(9, .trace, "DNA TRACE (never say): \(DeeDNA.version) \(d.mindCode.display)"))
        return out
    }

    static func ageLine(_ d: DeeDNA) -> String {
        guard let age = d.age, let stage = d.stage else { return "Age: ageless." }
        let years = Int(age)
        let article = stage == .adult || stage == .elder ? "an" : "a"
        var s = "Age: \(years) robot-year\(years == 1 ? "" : "s"), \(article) \(stage.rawValue)"
        if d.aging.enabled, d.aging.yearsPerDay > 0 {
            let ypd = d.aging.yearsPerDay
            s += ypd >= 1 ? "; you are growing up fast, about \(Int(ypd.rounded())) years a day"
                : "; you are growing up, about a year every \(Int((1 / ypd).rounded())) days"
        }
        s += "."
        if !stage.voiceNote.isEmpty { s += " " + stage.voiceNote }
        return s
    }

    // MARK: - The 5-gram guard (§2.7)

    enum Guard {
        /// Lower-cased, ’ → ', split on anything that is not a letter, digit or apostrophe.
        static func tokens(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "’", with: "'")
                .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        }

        /// 64-bit FNV-1a of one token (deterministic across runs; `Hasher` is seeded per process).
        static func hash(_ token: String) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in token.utf8 {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01b3
            }
            return h
        }

        /// One 5-gram from five token hashes.
        static func gram(_ t: ArraySlice<UInt64>) -> UInt64 {
            var h: UInt64 = 0x84222325cbf29ce4
            for x in t {
                h ^= x
                h = (h &* 0x0000_0100_0000_01b3) ^ (h >> 29)
            }
            return h
        }

        static func grams(_ corpus: [String]) -> Set<UInt64> { DNAGuardCorpus(corpus).grams }

        /// Token hashes of the lines with (line, item) owners (item nil = prefix/suffix/separator).
        static func stream(_ lines: [Line]) -> [(token: UInt64, line: Int, item: Int?)] {
            var out: [(UInt64, Int, Int?)] = []
            out.reserveCapacity(1200)
            for (li, l) in lines.enumerated() where !l.isEmpty {
                out += tokens(l.prefix).map { (hash($0), li, nil) }
                for (ii, item) in l.items.enumerated() {
                    if ii > 0 { out += tokens(l.separator).map { (hash($0), li, nil) } }
                    out += tokens(item).map { (hash($0), li, ii) }
                }
                out += tokens(l.suffix).map { (hash($0), li, nil) }
            }
            return out
        }

        /// Drops stored items (only) until no 5-gram that touches stored content is in
        /// `grams`. Windows of fixed vocabulary alone are kept and counted as echoes: a user
        /// saying Dee's own words is not a leak, and fixed lines (section 9, boundaries,
        /// identity, repair) must never disappear (review findings 1–2).
        static func run(_ lines: inout [Line], grams: DNAGuardCorpus) -> (dropped: [GuardDrop], echoes: Int) {
            var dropped: [GuardDrop] = []
            var s = stream(lines)
            var hashes = s.map(\.token)
            while s.count >= 5 {
                var echoes = 0
                var hit: (line: Int, item: Int)?
                for i in 0...(s.count - 5) where grams.grams.contains(gram(hashes[i..<(i + 5)])) {
                    if let o = s[i..<(i + 5)].first(where: { $0.item != nil && lines[$0.line].stored }) {
                        hit = (o.line, o.item!)
                        break
                    }
                    echoes += 1
                }
                guard let hit else { return (dropped, echoes) }
                let l = lines[hit.line]
                dropped.append(GuardDrop(section: l.section, lineKind: l.kind.rawValue))
                lines[hit.line].items.remove(at: hit.item)
                if lines[hit.line].items.isEmpty { lines[hit.line].needsItems = true }
                s = stream(lines)
                hashes = s.map(\.token)
            }
            return (dropped, 0)
        }
    }
}

/// docs/DNA.md §2.7 — the session's 5-gram set for the privacy guard, kept incrementally:
/// the app adds each user transcript once (`add`) instead of re-tokenising the whole
/// session on every render (review finding 3). RAM only; holds hashes, never text.
public struct DNAGuardCorpus: Sendable, Equatable {
    public private(set) var grams: Set<UInt64> = []
    /// Transcripts added (for traces).
    public private(set) var texts = 0

    public init(_ corpus: [String] = []) {
        for t in corpus { add(t) }
    }

    public var isEmpty: Bool { grams.isEmpty }

    public mutating func add(_ text: String) {
        texts += 1
        let t = DNAPrompt.Guard.tokens(text).map(DNAPrompt.Guard.hash)
        guard t.count >= 5 else { return }
        for i in 0...(t.count - 5) { grams.insert(DNAPrompt.Guard.gram(t[i..<(i + 5)])) }
    }

    public mutating func removeAll() {
        grams = []
        texts = 0
    }
}
