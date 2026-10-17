import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// docs/DNA.md §5.1–§5.3 — completeness, determinism, budget and degradation.
@Suite struct DNACompletenessTests {
    static let headings = ["1 IDENTITY", "2 TEMPERAMENT", "3 FEELINGS NOW (0–255; slow ones: affection, trust)", "4 TOWARD THIS PERSON",
                           "5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it)", "6 WHO YOU ARE", "7 RIGHT NOW",
                           "8 THIS TURN", "9 HOW TO RESPOND"]

    /// The 26 parameter lines in order, with their bytes and level words, and section 9.
    static func checkParameters(_ text: String, code: MindCode, age: Double?, _ tag: String) {
        let lines = text.split(separator: "\n").map(String.init)
        let traitLines = lines.filter { l in Trait.allCases.contains { l.hasPrefix("\($0.rawValue) ") && l.contains("/255 ") } }
        let feelingLines = lines.filter { l in Feeling.allCases.contains { l.hasPrefix("\($0.rawValue) ") && l.contains("/255 ") } }
        #expect(traitLines.count == 13, "\(tag): \(traitLines.count) trait lines")
        #expect(feelingLines.count == 13, "\(tag): \(feelingLines.count) feeling lines")
        let eff = EmotionEngine.effective(code.personality, age: age)
        for (t, l) in zip(Trait.allCases, traitLines) {
            // Number and level word are the same (age-adjusted) value (review finding 4).
            let e = DNAAssembler.quantize(eff[t])
            let level = TraitLevel(byte: e)
            #expect(l.hasPrefix("\(t.rawValue) \(e)/255 \(level.words): "), "\(tag): \(l)")
            let born = TraitLevel(byte: Int(code[t]))
            if abs(e - Int(code[t])) >= 13 && born != level { #expect(l.hasSuffix("(born \(born.words); your age shapes it)"), "\(tag): \(l)") }
        }
        for (f, l) in zip(Feeling.allCases, feelingLines) {
            let b = Int(code[f])
            let words = f == .energy ? FeelingLevel.energyWords(byte: b) : FeelingLevel(byte: b).words
            #expect(l.hasPrefix("\(f.rawValue) \(b)/255 \(words)"), "\(tag): \(l)")
        }
        for prefix in ["Length: ", "Energy ", "Voice: ", "Do: ", "Avoid: ", "Always: ", "DNA TRACE (never say): \(DeeDNA.version) "] {
            #expect(lines.contains { $0.hasPrefix(prefix) }, "\(tag): missing \(prefix)")
        }
        // Headings in order.
        let idx = headings.map { h in lines.firstIndex(of: h) ?? -1 }
        #expect(!idx.contains(-1) && idx == idx.sorted(), "\(tag): headings \(idx)")
        // Trace decodes.
        let trace = lines.last { $0.hasPrefix("DNA TRACE") } ?? ""
        let hex = trace.split(separator: " ").last.map { $0.replacingOccurrences(of: "·", with: "") } ?? ""
        #expect(MindCode(hex: hex) == code, "\(tag): trace")
    }

    @Test func randomCodesRenderAll26ParametersAndSection9() {
        var rng = Rand(seed: 26)
        let base = DNAKit.fondMorning().inputs
        for i in 0..<10_000 {
            let bytes = (0..<26).map { _ in Double(rng.index(256)) / 255 }
            var p = Personality(), f = Feelings()
            for (j, t) in Trait.allCases.enumerated() { p[t] = bytes[j] }
            for (j, x) in Feeling.allCases.enumerated() { f[x] = bytes[13 + j] }
            let age: Double? = i % 3 == 0 ? Double(rng.index(100)) : nil
            var inputs = base
            inputs.mind = MindSnapshot(code: MindCode(personality: p, feelings: f), age: age)
            inputs.moment.ongoing.mind = inputs.mind
            let text = DNAPrompt.render(DNAAssembler.assemble(inputs)).text
            Self.checkParameters(text, code: inputs.mind.code, age: age, "code \(i)")
        }
    }

    @Test func everyArchetypeIsComplete() {
        for a in DNAKit.all {
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            Self.checkParameters(r.text, code: a.inputs.mind.code, age: a.inputs.mind.age, a.name)
            #expect(!r.text.contains("[") && !r.text.contains("]") && !r.text.contains("<") && !r.text.contains(">"), "\(a.name): brackets")
        }
    }

    /// After every degradation step (forced by a tiny budget) the 26 lines and section 9 survive.
    @Test func everyDegradationStepKeepsTheCore() {
        let dna = DNAAssembler.assemble(DNAKit.maxLength())
        var o = DNAPrompt.Options()
        var previous = DNAPrompt.estimate(DNAPrompt.join(DNAPrompt.compose(dna, o)))
        for s in DegradeStep.allCases {
            o.apply(s)
            let text = DNAPrompt.join(DNAPrompt.compose(dna, o))
            Self.checkParameters(text, code: dna.mindCode, age: dna.age, s.rawValue)
            let e = DNAPrompt.estimate(text)
            #expect(e <= previous, "\(s.rawValue) raised the estimate \(previous) → \(e)")
            previous = e
            // Notes survive every step but the minimal DNA (review finding 14) …
            let notes = text.contains("Do now (once, only if it still fits what they just said): ") && text.contains("Keep in mind: ")
            #expect(notes == (s != .minimal), "\(s.rawValue): notes \(notes)")
            // … and boundaries and repair survive every step, the minimal DNA included.
            #expect(text.contains("Don't bring up: ") && text.contains("Repair: "), "\(s.rawValue): boundaries or repair dropped")
        }
        // A budget nothing fits forces every step and the minimal DNA, which still has the core.
        let r = DNAPrompt.render(dna, budget: DNABudget(target: 10, cap: 20))
        #expect(r.steps == DegradeStep.targetSteps + DegradeStep.capSteps + [.minimal])
        Self.checkParameters(r.text, code: dna.mindCode, age: dna.age, "minimal")
    }

    @Test func maxLengthFixtureFitsTheCapWithoutMinimal() {
        let dna = DNAAssembler.assemble(DNAKit.maxLength())
        let full = DNAPrompt.estimate(DNAPrompt.join(DNAPrompt.compose(dna, DNAPrompt.Options())))
        #expect(full > DNABudget.standard.target, "full render \(full)")
        let r = DNAPrompt.render(dna)
        #expect(r.estimatedTokens <= DNABudget.standard.cap, "after degradation \(r.estimatedTokens)")
        #expect(!r.steps.contains(.minimal), "\(r.steps)")
        // Steps in order; S9–S12 only when still over the cap after S8.
        let order = DegradeStep.targetSteps + DegradeStep.capSteps + [.minimal]
        #expect(r.steps == r.steps.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        // Every max-fixture rule except the mutually exclusive fast/initiative ones fires.
        #expect(Set(dna.guidance.rules).isSuperset(of: [.g1, .g2, .g3, .g5, .g6, .g9, .g10, .g12, .g15, .g16]))
    }

    @Test func stepsStopAtTargetAndCapStepsNeedTheCap() {
        let dna = DNAAssembler.assemble(DNAKit.maxLength())
        let full = DNAPrompt.estimate(DNAPrompt.join(DNAPrompt.compose(dna, DNAPrompt.Options())))
        // Between target and cap: only S1…S8 may run.
        let r = DNAPrompt.render(dna, budget: DNABudget(target: 400, cap: full + 1))
        #expect(!r.steps.contains { DegradeStep.capSteps.contains($0) || $0 == .minimal }, "\(r.steps)")
        // Under target: nothing runs.
        let none = DNAPrompt.render(dna, budget: DNABudget(target: full, cap: full))
        #expect(none.steps.isEmpty)
        // The steps list matches what shortened the text.
        var o = DNAPrompt.Options()
        for s in r.steps { o.apply(s) }
        #expect(DNAPrompt.join(DNAPrompt.compose(dna, o)) == r.text)
    }

    @Test func deterministicAndPure() {
        for a in DNAKit.all {
            let x = DNAPrompt.build(a.inputs)
            let y = DNAPrompt.build(a.inputs)
            #expect(x == y)
            #expect(x.sha256 == y.sha256 && x.sha256.count == 64)
            // The corpus never changes the text unless the guard dropped something.
            var b = a.inputs
            b.userTextCorpus = ["completely unrelated words about the weather today and nothing else"]
            let z = DNAPrompt.build(b)
            #expect(z.dropped.isEmpty && z.text == x.text)
        }
    }

    /// Local time comes only from `utcOffset`: the DNA sources never touch the device's
    /// locale, calendar or time zone (and the DeeSelf purity lint covers the folder).
    @Test func noLocaleCalendarOrTimeZoneInDNASources() throws {
        let dir = PolicyTests.sources.appendingPathComponent("DNA")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for banned in ["Locale", "TimeZone", "Calendar", "DateFormatter", "Hasher"] {
                let code = text.split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
                #expect(!code.contains(banned), "\(f.lastPathComponent) uses \(banned)")
            }
        }
    }

    @Test func localTimeIsCivil() {
        let t = LocalTime(DNAKit.local(1, 40), utcOffset: DNAKit.offset)
        #expect(t.text == "Friday 9 October 2026, 1:40" && t.partOfDay == .lateNight)
        let u = LocalTime(Date(timeIntervalSince1970: 951_782_400), utcOffset: 0)   // 2000-02-29 00:00 UTC
        #expect(u.year == 2000 && u.month == 2 && u.day == 29 && u.weekday == 2)
        #expect(DNAAssembler.dayNumber("2000-02-29") == 951_782_400 / 86_400)
        #expect(DNAKit.dayString(0) == "2026-10-09")
    }

    // MARK: §5.1 field coverage (review finding 13)

    /// How a snapshot field reaches the model.
    enum Use {
        /// Changing it changes the text.
        case rendered((inout DeeDNA) -> Void)
        /// Read by `DNAAssembler.guidance` (§2.9): changing it changes section 9.
        case guidanceInput((inout DeeDNA) -> Void)
        /// Collected but deliberately not rendered (reason).
        case notRendered(String)
    }

    /// Every leaf of `DeeDNA` (nested readings expanded) with how it is used. A new field
    /// fails `everyDeeDNAFieldIsCovered` until it is listed here, and every "rendered" or
    /// "guidance input" claim is checked by perturbing the field.
    static var coverage: [String: Use] {
        func subj(_ s: String) -> Subject { DNAKit.subject(s) }
        return [
            "turn": .rendered { $0.turn.kind = .retry },
            "name": .rendered { $0.name = "Zed" },
            "localTime": .rendered { $0.localTime = LocalTime(DNAKit.local(23, 59), utcOffset: DNAKit.offset) },
            "partOfDay": .rendered { $0.partOfDay = .night },
            "age": .rendered { $0.age = 40; $0.stage = .adult },
            "stage": .rendered { $0.age = 6; $0.stage = .child },
            "aging": .rendered { $0.age = 6; $0.stage = .child; $0.aging = AgingInputs(enabled: true, yearsPerDay: 0.1) },
            "mindCode": .rendered { $0.mindCode = MindCode(personality: Personality(), feelings: Feelings()) },
            "traits": .rendered { $0.traits[0].meaning = "zz" },
            "feelings": .rendered { $0.feelings[0].byte = 0 },
            "valence": .rendered { $0.valence = -0.9 },
            "arousal": .rendered { $0.arousal = 0.01 },
            "restingExpression": .rendered { $0.restingExpression = .grumpy },
            "blend": .rendered { $0.blend = ["sad"] },
            "reflex": .rendered { $0.reflex = ReflexReading(emotion: .surprised, secondsAgo: 1, cause: nil) },
            "moodBand": .rendered { $0.moodBand = .negLow },
            "mood": .guidanceInput { $0.mood.playfulness = 0 },
            "urgeToTalk": .guidanceInput { $0.turn.kind = .initiative; $0.urgeToTalk = 0 },
            "inner": .notRendered("assembled into relationship.rudeCount / kindCount / apologiesCountLess; reoffense, hostileRecent, kindRecent and lastApologyAt drive the mind, not the words"),
            "relationship.who": .rendered { $0.relationship.who = .unidentified },
            "relationship.regard": .rendered { $0.relationship.regard = -0.9 },
            "relationship.regardWords": .notRendered("the bond line re-derives the same words from regard (DNATables.regardSentence)"),
            "relationship.eyeColour": .rendered { $0.relationship.eyeColour = .red },
            "relationship.affection": .rendered { $0.relationship.affection = 0 },
            "relationship.trust": .rendered { $0.relationship.trust = 0 },
            "relationship.repair": .rendered { $0.relationship.repair = .ruptured },
            "relationship.awkwardness": .notRendered("the repair phase (strained) and the awkward-repair note carry it"),
            "relationship.userBoundaries": .rendered { $0.relationship.userBoundaries = [subj("money")] },
            "relationship.deeBoundaryStated": .rendered { $0.relationship.deeBoundaryStated = true },
            "relationship.profile": .rendered { $0.relationship.profile.humorReceptiveness = 0.1 },
            "relationship.lesson": .rendered { $0.relationship.lesson = "zz" },
            "relationship.waitBeforeAnswering": .notRendered("a timing behaviour the app applies (live eval R2)"),
            "relationship.encounters": .rendered { $0.relationship.encounters = 99 },
            "relationship.firstMetMonth": .rendered { $0.relationship.firstMetMonth = "May 2020" },
            "relationship.sinceLastTalk": .rendered { $0.relationship.sinceLastTalk = 9 * 86_400 },
            "relationship.recentTrend": .rendered { $0.relationship.recentTrend = "cooler" },
            "relationship.rudeCount": .rendered { $0.relationship.rudeCount = 77 },
            "relationship.kindCount": .rendered { $0.relationship.kindCount = 1 },
            "relationship.apologiesCountLess": .rendered { $0.relationship.apologiesCountLess = true },
            "knowledge.facts": .rendered { $0.knowledge.facts = ["zz"] },
            "knowledge.episodes": .rendered { $0.knowledge.episodes = [] },
            "knowledge.followUps": .rendered { $0.knowledge.followUps = [FollowUpLine(subject: subj("exam"), framing: .neutral, days: 1)] },
            "knowledge.upcoming": .rendered { $0.knowledge.upcoming = [] },
            "knowledge.interests": .rendered { $0.knowledge.interests = [] },
            "knowledge.shareMemories": .rendered { $0.knowledge.shareMemories = false },
            "knowledge.unknownPerson": .rendered { $0.knowledge.unknownPerson = true },
            "selfModel.topValues": .rendered { $0.selfModel.topValues.reverse() },
            "selfModel.humour": .rendered { $0.selfModel.humour = $0.selfModel.humour == .deadpan ? .wordplay : .deadpan },
            "selfModel.humourSecondary": .rendered { $0.selfModel.humourSecondary = $0.selfModel.humourSecondary == .deadpan ? .wordplay : .deadpan },
            "selfModel.tastes": .rendered { $0.selfModel.tastes = [] },
            "selfModel.strengths": .rendered { $0.selfModel.strengths = [] },
            "selfModel.limits": .rendered { $0.selfModel.limits = ["You can't fly."] },
            "selfModel.lessonGeneral": .rendered { $0.selfModel.lessonGeneral = "to zz" },
            "selfModel.rituals": .rendered { $0.selfModel.rituals = [] },
            "selfModel.gags": .rendered { $0.selfModel.gags = ["zz"] },
            "selfModel.mannerisms": .rendered { $0.selfModel.mannerisms = [] },
            "now.someoneHere": .rendered { $0.now.someoneHere = false },
            "now.mutualGazeSeconds": .rendered { $0.now.mutualGazeSeconds = nil },
            "now.asleep": .rendered { $0.now.asleep = true },
            "now.wokeSecondsAgo": .rendered { $0.now.wokeSecondsAgo = 10 },
            "now.sees": .rendered { $0.now.sees = [SeenThing(subject: subj("cup"), camera: .front, sharedWithUser: false, heldUp: false)] },
            "now.focus": .notRendered("the attention target's name; a sound focus is rendered through now.lastSound"),
            "now.lastSound": .rendered { $0.now.lastSound = "a dog barking" },
            "now.touch": .rendered { $0.now.touch = "a tap"; $0.now.touchSecondsAgo = 3 },
            "now.touchSecondsAgo": .rendered { $0.now.touch = "a tap"; $0.now.touchSecondsAgo = 9 },
            "now.floor": .notRendered("turn-taking state; the app's floor keeper acts on it, the model does not"),
            "now.cutOff": .rendered { $0.now.cutOff = true },
            "now.hypotheses": .rendered { $0.now.hypotheses = [HypothesisLine(kind: .busy, value: "busy", stated: true)] },
            "now.distressLive": .guidanceInput { $0.now.distressLive = true },
            "now.playGate": .guidanceInput { $0.now.playGate = false },
            "now.notes": .rendered { $0.now.notes = [] },
            "now.intentions": .rendered { $0.now.intentions = [IntentionLine(action: "Ask about the zz.", priority: 0.5, reason: "r")] },
            "now.turnsThisConversation": .rendered { $0.now.turnsThisConversation = 0 },
            "now.conversationMinutes": .rendered { $0.now.conversationMinutes = 33 },
            "now.reunion": .guidanceInput { $0.now.reunion = true },
            "appraisal": .rendered { $0.appraisal.prosody = nil },
            "guidance.length": .rendered { $0.guidance.length = "zz" },
            "guidance.energyLevel": .notRendered("rendered as guidance.energyWord"),
            "guidance.energyWord": .rendered { $0.guidance.energyWord = "zz" },
            "guidance.warmth": .notRendered("rendered as guidance.warmthWord"),
            "guidance.warmthWord": .rendered { $0.guidance.warmthWord = "zz" },
            "guidance.playfulness": .notRendered("rendered as guidance.playfulnessWord"),
            "guidance.playfulnessWord": .rendered { $0.guidance.playfulnessWord = "zz" },
            "guidance.voiceEmotion": .notRendered("rendered as guidance.voice"),
            "guidance.voice": .rendered { $0.guidance.voice = "zz" },
            "guidance.rules": .notRendered("rendered as guidance.doLines / avoidLines"),
            "guidance.doLines": .rendered { $0.guidance.doLines = ["zz"] },
            "guidance.avoidLines": .rendered { $0.guidance.avoidLines = ["zz"] },
            // The persona preset: its identity line, pronouns and age (Classic → Mira).
            "persona": .rendered { $0.persona = PersonaCatalog.mira },
        ]
    }

    /// Leaf paths of a snapshot: top-level fields, with the five readings expanded.
    static func leafPaths(_ dna: DeeDNA) -> [String] {
        let expand: Set<String> = ["relationship", "knowledge", "selfModel", "now", "guidance"]
        return Mirror(reflecting: dna).children.flatMap { c -> [String] in
            guard let label = c.label else { return [] }
            guard expand.contains(label) else { return [label] }
            return Mirror(reflecting: c.value).children.compactMap(\.label).map { "\(label).\($0)" }
        }
    }

    @Test func everyDeeDNAFieldIsCovered() {
        let inputs = DNAKit.fondMorning().inputs
        let base = DNAAssembler.assemble(inputs)
        let paths = Self.leafPaths(base)
        #expect(Set(paths) == Set(Self.coverage.keys),
                "unlisted: \(Set(paths).subtracting(Self.coverage.keys).sorted()); stale: \(Set(Self.coverage.keys).subtracting(paths).sorted())")
        let wide = DNABudget(target: 100_000, cap: 100_000)
        let baselines = EmotionEngine.baselines(personality: inputs.mind.code.personality, age: inputs.mind.age)
        let baseText = DNAPrompt.render(base, budget: wide).text
        for (path, use) in Self.coverage.sorted(by: { $0.key < $1.key }) {
            var d = base
            switch use {
            case .rendered(let change):
                change(&d)
                #expect(DNAPrompt.render(d, budget: wide).text != baseText, "\(path) is claimed rendered but changing it changes nothing")
            case .guidanceInput(let change):
                change(&d)
                d.guidance = DNAAssembler.guidance(d, stance: inputs.stance, mind: inputs.mind, baselines: baselines)
                #expect(d.guidance != base.guidance, "\(path) is claimed a guidance input but changing it changes nothing")
                #expect(DNAPrompt.render(d, budget: wide).text != baseText, "\(path): section 9 unchanged")
            case .notRendered(let why):
                #expect(!why.isEmpty)
            }
        }
    }

    /// Spec §5.2: the render never depends on the device locale or time zone. The test
    /// suite is also run with `LANG=fr_FR.UTF-8 TZ=Asia/Kolkata` (docs/DNA.md §5.2); here
    /// the archetypes are rendered once per environment value we can vary in-process.
    @Test func renderIgnoresTheProcessLocaleAndZone() throws {
        let env = ProcessInfo.processInfo.environment
        for a in DNAKit.all {
            let golden = try String(contentsOf: DNAGoldenTests.root.appendingPathComponent("\(a.name).dna.txt"), encoding: .utf8)
            #expect(DNAPrompt.build(a.inputs).text + "\n" == golden || DNAGoldenTests.recording,
                    "\(a.name) differs under TZ=\(env["TZ"] ?? "-") LANG=\(env["LANG"] ?? "-")")
        }
    }

    @Test func prosodyOnlyMatchesTheAppraiserVoiceTerms() {
        let base = Appraiser.VoiceBaseline()
        for p in [Prosody(loudnessDB: -15, peakDB: -6, speechRate: 4.2, pitchVariability: 5),
                  Prosody(loudnessDB: -44, peakDB: -38, speechRate: 1.6, pitchVariability: 1.0),
                  Prosody(loudnessDB: -32, peakDB: -22, speechRate: 2.6)] {
            let read = Appraiser.prosodyOnly(p, baseline: base)
            let full = Appraiser(baseline: base).peek("okay", prosody: p)
            #expect(abs(read.loudness - full.loudness) < 1e-9)
            #expect(read.intensity <= full.intensity + 1e-9)
        }
        #expect(DNATables.prosodyWords(ProsodyRead(loudness: 0.9, pace: 0.4, pitchVariability: 5, dominance: 0.45)) == "shouting, fast, very animated pitch, forceful")
        #expect(DNATables.prosodyWords(ProsodyRead(loudness: -0.4, pace: -0.3, pitchVariability: 1, dominance: -0.3)) == "soft, slow, flat pitch, hesitant")
    }

    @Test func trendAndCauseRules() {
        #expect(Trend(delta: 51) == .risingFast && Trend(delta: 13) == .rising && Trend(delta: 12) == .steady)
        #expect(Trend(delta: -13) == .easing && Trend(delta: -51) == .fallingFast)
        var slap = Appraisal.touch(.slap(force: 0.8))
        #expect(CauseLabel.classify(slap) == .slap)
        slap.touch = nil
        #expect(CauseLabel.classify(slap) == .rudeness)
        #expect(CauseLabel.classify(Appraisal.sound(label: "siren", unexpected: true, loudness: 0.8)) == .alarmingSound)
        #expect(CauseLabel.classify(Appraisal.sound(label: "laughter", unexpected: false, loudness: 0.5)) == .laughter)
        #expect(CauseLabel.classify(Appraisal.sight(novelty: 1)) == .sawSomethingNew)
        #expect(CauseLabel.classify(Appraisal.internal(relief: 0.8)) == .relief)
        var rings = DNARings()
        let c = MindCode(personality: Personality(), feelings: Feelings())
        rings.sample(c, at: DNAKit.day, force: true)
        rings.sample(c, at: DNAKit.day.addingTimeInterval(10))
        #expect(rings.history.count == 1)
        for i in 0..<45 { rings.sample(c, at: DNAKit.day.addingTimeInterval(Double(31 * (i + 1)))) }
        #expect(rings.history.count == DNARings.historyCapacity)
    }
}
