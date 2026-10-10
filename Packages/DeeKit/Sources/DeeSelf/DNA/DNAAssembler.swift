import DeeCore
import DeeMemory
import DeeMind
import Foundation

/// docs/DNA.md §1 — builds the `DeeDNA` snapshot. Pure: everything time-dependent is
/// computed from `inputs.now`; no clock, no randomness, no user text (the 5-gram corpus
/// is left to the renderer's guard and never copied into the snapshot).
public enum DNAAssembler {
    public static func assemble(_ inputs: DNAInputs) -> DeeDNA {
        let now = inputs.now
        let mind = inputs.mind
        let code = mind.code
        let m = inputs.moment
        let og = m.ongoing
        let personID = inputs.person?.id ?? og.person
        let local = LocalTime(now, utcOffset: inputs.utcOffset)
        let profile = m.enduring.profile(personID)
        let boundaries = userBoundaries(m.enduring, person: personID)
        func blocked(_ s: Subject) -> Bool { boundaries.contains { $0.overlaps(s) } }
        func blockedText(_ t: String) -> Bool { boundaries.contains { $0.appears(in: t) } }

        // §1.3 Temperament.
        let effective = EmotionEngine.effective(code.personality, age: mind.age)
        let traits = Trait.allCases.map { t -> TraitReading in
            let byte = Int(code[t])
            let eff = quantize(effective[t])
            let level = TraitLevel(byte: eff)
            let meaning = DNATables.meaning(t, level)
            return TraitReading(trait: t, byte: byte, effectiveByte: eff, level: level, meaning: meaning,
                                compactMeaning: DNATables.compact(meaning), ageShifted: abs(eff - byte) >= 13)
        }

        // §1.3–§1.4 Feelings.
        let baselines = EmotionEngine.baselines(personality: code.personality, age: mind.age)
        let reference = trendReference(inputs.moodHistory, now: now)
        let recentCauses = inputs.causes.filter { $0.at <= now && now.timeIntervalSince($0.at) <= DNARings.causeWindow }
        let wokeAgo = inputs.body.wokeAt.map { now.timeIntervalSince($0) }.flatMap { $0 >= 0 ? $0 : nil }
        let aloneLong = !inputs.body.someoneHere && (inputs.body.lastUserTurnAt.map { now.timeIntervalSince($0) > 600 } ?? true)
        let feelings = Feeling.allCases.map { f -> FeelingReading in
            let byte = Int(code[f])
            let usual = quantize(baselines[f])
            let level = FeelingLevel(byte: byte)
            let trend = reference.map { Trend(delta: byte - Int($0[f])) } ?? .steady
            let notable = (byte >= 51 && abs(byte - usual) >= 26) || (f == .energy && byte <= 101)
            let sign = byte != usual ? (byte > usual ? 1 : -1) : (trend == .steady ? 0 : (trend == .rising || trend == .risingFast ? 1 : -1))
            var cause: CauseLabel?
            if sign != 0 {
                var best: (Int, CauseEntry)?
                for e in recentCauses {
                    let d = e.delta(f) * sign
                    if d >= 13, best.map({ d >= $0.0 }) ?? true { best = (d, e) }
                }
                cause = best?.1.label
            }
            if cause == nil {
                switch f {
                case .loneliness where byte >= 77 && aloneLong: cause = .timeAlone
                case .energy where byte < 90 && !inputs.body.asleep: cause = (wokeAgo ?? .infinity) <= 60 ? .justWoke : .longDay
                case .resentment where byte >= 51 && (og.repair == .ruptured || og.repair == .repairing): cause = .quarrel
                default: break
                }
            }
            return FeelingReading(feeling: f, byte: byte, usualByte: usual, level: level,
                                  levelWords: f == .energy ? FeelingLevel.energyWords(byte: byte) : level.words,
                                  trend: trend, cause: cause,
                                  effect: notable ? DNATables.effect(f, byte: byte, usual: usual) : nil, notable: notable)
        }

        // Reflex (live ≤ Mind.reflexDuration).
        var reflex: ReflexReading?
        if let r = mind.reflex, let at = mind.reflexAt, now >= at, now.timeIntervalSince(at) <= Mind.reflexDuration {
            let c = recentCauses.last { $0.at >= at.addingTimeInterval(-1) }
            reflex = ReflexReading(emotion: r, secondsAgo: now.timeIntervalSince(at), cause: c?.label)
        } else if let r = m.momentary.reflex?.live(at: now) {
            let started = m.momentary.reflex.map { $0.until.addingTimeInterval(-Mind.reflexDuration) } ?? now
            let c = recentCauses.last { $0.at >= started.addingTimeInterval(-1) }
            reflex = ReflexReading(emotion: r, secondsAgo: max(0, now.timeIntervalSince(started)), cause: c?.label)
        }

        // §1.5 Relationship.
        let who: RelationshipReading.Who
        if let p = inputs.person {
            who = p.isPlaceholder || p.name == nil ? .placeholder : .named(p.name!, aliases: p.aliases)
        } else {
            who = .unidentified
        }
        let exact: Appraisal? = inputs.turn.mode == .exact ? inputs.appraisal.text : nil
        let hostileTurn = (exact?.hostility ?? 0) >= 0.3 || og.repair == .ruptured
        var lessonPick = topLesson(m.enduring, person: personID)
        // A humour/literal reading would undercut G1 on a hostile turn (review finding 8).
        if hostileTurn, let l = lessonPick, DNATables.lessonIsAboutHumour(l.situation) { lessonPick = nil }
        let waitFirst = inputs.turn.kind != .initiative && m.enduring.lessons.contains {
            $0.situation == .interruptedThem && $0.evidence >= 1 && ($0.person == nil || $0.person == personID)
        }
        // Time since the last contact *before* this conversation (`BodyInputs.lastContact`,
        // set from `Cortex.lastContactBeforeConversation` by `dnaInputs`). Never the current
        // turn (tune 2 F5: `lastUserTurnAt` came first and a 50 h reunion read "just now").
        let sinceLastTalk: TimeInterval? = (inputs.body.lastContact ?? inputs.person?.lastSeen)
            .map { max(0, now.timeIntervalSince($0)) }
        let relationship = RelationshipReading(
            who: who, regard: mind.regard, regardWords: CueWriter.regardWords(mind.regard),
            eyeColour: EyeColour(regard: mind.regard), affection: Int(code[.affection]), trust: Int(code[.trust]),
            repair: og.repair, awkwardness: og.awkwardness, userBoundaries: boundaries,
            deeBoundaryStated: personID.map { id in
                m.enduring.boundaries.contains { $0.owner == .dee && $0.person == id && $0.active && now.timeIntervalSince($0.createdAt) <= 600 }
            } ?? false,
            profile: profile, lesson: lessonPick.flatMap { DNATables.lessonReading($0.situation) }, waitBeforeAnswering: waitFirst,
            encounters: inputs.person?.encounters ?? 0,
            firstMetMonth: inputs.person?.firstMet.map { LocalTime($0, utcOffset: inputs.utcOffset).monthYear }, sinceLastTalk: sinceLastTalk,
            recentTrend: recentTrend(inputs.daily, today: local.dayNumber),
            rudeCount: inputs.inner.hostileInteractions, kindCount: inputs.inner.kindInteractions,
            apologiesCountLess: inputs.inner.apologyFatigue >= 0.5)

        // §1.6 What she knows.
        let unknown = inputs.person == nil || inputs.person?.isPlaceholder == true
        let share = inputs.shareMemories
        var facts: [String] = []
        var episodes: [EpisodeLine] = []
        var upcoming: [FollowUpLine] = []
        var interests: [Subject] = []
        var followUps: [FollowUpLine] = []
        if let p = inputs.person, !unknown {
            let names = ([p.name].compactMap { $0 } + p.aliases)
            if share {
                facts = p.facts.prefix(DNALimits.facts).map { telegraphic($0.text, names: names, category: $0.category) }
                    .filter { !$0.isEmpty && !blockedText($0) }
                episodes = Array(inputs.episodes.filter { !blockedText($0.gist) }.prefix(DNALimits.episodes))
                upcoming = og.expectations
                    .filter { $0.person == p.id && ($0.status == .pending || $0.status == .asked) && $0.due > now && !blocked($0.subject) }
                    .sorted { ($0.due, $0.subject.text) < ($1.due, $1.subject.text) }
                    .prefix(DNALimits.upcoming)
                    .map { FollowUpLine(subject: $0.subject, framing: $0.framing, days: localDays(from: now, to: $0.due, utcOffset: inputs.utcOffset)) }
                interests = og.interests.filter { !blocked($0.subject) }
                    .sorted { ($0.weight, $1.subject.text) > ($1.weight, $0.subject.text) }
                    .prefix(DNALimits.interests).map(\.subject)
            }
            followUps = og.expectations
                .filter { $0.person == p.id && ($0.status == .pending || $0.status == .asked) && $0.due <= now && $0.expires > now
                    && !blocked($0.subject) }
                .sorted { ($0.due, $0.subject.text) > ($1.due, $1.subject.text) }
                .prefix(DNALimits.followUps)
                .map { FollowUpLine(subject: $0.subject, framing: $0.framing, days: localDays(from: $0.due, to: now, utcOffset: inputs.utcOffset)) }
        }
        let knowledge = KnowledgeReading(facts: facts, episodes: episodes, followUps: followUps, upcoming: upcoming,
                                         interests: interests, shareMemories: share, unknownPerson: unknown)

        // §1.7 Who she is.
        // Running jokes only while things are fine and nobody is upset (NotePicker's gag gates).
        let jokesOK = og.repair == .fine && !og.distressLive(at: now)
        let selfModel = selfReading(m.enduring, person: personID, gagsAllowed: jokesOK, lessonPick: lessonPick, now: now,
                                    energy: mind.mood.energy, playGate: inputs.stance.playGate, blocked: blocked)

        // §1.8 Right now.
        let mo = m.momentary
        let sees = mo.referents.filter { $0.salience >= 0.3 && !blocked($0.subject) }
            .sorted { ($0.salience, $1.subject.text) > ($1.salience, $0.subject.text) }
            .prefix(DNALimits.sees)
            .map { SeenThing(subject: $0.subject, camera: $0.camera, sharedWithUser: $0.sharedWithUser, heldUp: $0.sources.contains(.heldUp)) }
        var lastSound: String?
        if case .sound(let s) = mo.focus { lastSound = s.text }
        else if let c = recentCauses.last(where: { $0.label.isSound && now.timeIntervalSince($0.at) <= 60 }) { lastSound = c.label.words }
        let touch = inputs.body.touch.flatMap { t -> TouchInput? in
            let ago = now.timeIntervalSince(t.at)
            return ago >= 0 && ago <= 15 ? t : nil
        }
        let gain = profile.moodInferenceGain
        let hypotheses = og.hypotheses.filter { now < $0.expires && ($0.stated || $0.confidence >= 0.5 * gain) }
            .sorted { ($0.stated ? 1 : 0, $0.confidence, $1.value) > ($1.stated ? 1 : 0, $1.confidence, $0.value) }
            .prefix(DNALimits.hypotheses)
            .map { HypothesisLine(kind: $0.kind, value: $0.value, stated: $0.stated) }
        // Live eval R3: a pending boundary or ask-after note yields when the turn is an
        // apology, a joke or distress (the model otherwise does it anyway).
        let heard = (exact?.apology ?? 0) >= 0.4 || (exact?.humor ?? 0) >= 0.4 || (exact?.distress ?? 0) >= 0.4
        let picked = inputs.stance.notes.filter { !(heard && Self.yieldsToTurn($0.kind)) }.prefix(DNALimits.notes)
        let notes = picked.sorted { ($0.role == .aim ? 0 : 1, $0.priority) < ($1.role == .aim ? 0 : 1, $1.priority) }
            .map { NoteLine(kind: $0.kind, role: $0.role, priority: $0.priority, text: stripParens($0.text)) }
        let noted = Set(picked.compactMap(\.intention))
        let intentions = og.intentions
            .filter { $0.isLive && !noted.contains($0.id) && ($0.person == nil || $0.person == personID) && $0.notBefore <= now
                && $0.expires > now && !blocked($0.subject) }
            .sorted { ($0.priority, $1.subject.text) > ($1.priority, $0.subject.text) }
            .prefix(DNALimits.intentions)
            .map { IntentionLine(action: IntentionBoard.action(for: $0), priority: $0.priority, reason: $0.reason) }
        let nowReading = NowReading(
            someoneHere: inputs.body.someoneHere,
            mutualGazeSeconds: mo.mutualGazeSince.map { max(0, now.timeIntervalSince($0)) },
            asleep: inputs.body.asleep, wokeSecondsAgo: wokeAgo, sees: Array(sees), focus: mo.focus.name,
            lastSound: lastSound, touch: touch.map(DNATables.touchWords), touchSecondsAgo: touch.map { now.timeIntervalSince($0.at) },
            floor: inputs.stance.floor.name, cutOff: og.cutOff, hypotheses: Array(hypotheses),
            distressLive: og.distressLive(at: now), playGate: inputs.stance.playGate, notes: notes, intentions: Array(intentions),
            turnsThisConversation: og.turnsThisConversation,
            conversationMinutes: max(0, Int(now.timeIntervalSince(og.conversationStarted) / 60)), reunion: og.reunionTurn)

        // On the reunion turn loneliness never leads (it must not read as guilt); "happy" only
        // when her mood is actually pleasant (review finding 7).
        let resting = og.reunionTurn && mind.emotion == .lonely ? (mind.valence >= 0 ? Emotion.happy : .neutral) : mind.emotion
        let blend = DNATables.blend(code: code, omit: og.reunionTurn ? ["lonely"] : []).filter { $0 != resting.rawValue }
        var dna = DeeDNA(
            turn: inputs.turn, name: "Dee", localTime: local, partOfDay: local.partOfDay, age: mind.age, stage: mind.stage,
            aging: inputs.aging, mindCode: code, traits: traits, feelings: feelings, valence: mind.valence, arousal: mind.arousal,
            // On the reunion turn her loneliness never leads the line (it must not read as guilt).
            restingExpression: resting, blend: blend, reflex: reflex, moodBand: EmotionBand(mood: mind), mood: mind.mood,
            urgeToTalk: mind.urgeToTalk, inner: inputs.inner, relationship: relationship, knowledge: knowledge,
            selfModel: selfModel, now: nowReading, appraisal: inputs.appraisal,
            guidance: Guidance(length: "", energyLevel: 0, energyWord: "", warmth: 0, warmthWord: "", playfulness: 0,
                               playfulnessWord: "", voiceEmotion: .neutral, voice: "", rules: [], doLines: [], avoidLines: []))
        dna.guidance = guidance(dna, stance: inputs.stance, mind: mind, baselines: baselines)
        return dna
    }

    // MARK: - Guidance (§2.9)

    static func guidance(_ d: DeeDNA, stance: Stance, mind: MindSnapshot, baselines: Feelings) -> Guidance {
        let energy = Double(d.mindCode[.energy]) / 255
        let energyByte = Int(d.mindCode[.energy])
        let energyLevel = clamp01(0.6 * energy + 0.4 * d.arousal)
        var energyWord = energyLevel < 0.35 ? "low" : energyLevel < 0.65 ? "medium" : "high"
        let affection = Double(d.mindCode[.affection]) / 255
        var warmth = clamp01(0.5 + 0.5 * d.relationship.regard + 0.3 * (affection - baselines[.affection]))
        if d.relationship.repair == .ruptured { warmth = clamp01(warmth - 0.25) }
        let warmthWord = warmth < 0.35 ? "cool" : warmth < 0.55 ? "polite" : warmth < 0.75 ? "warm" : "very warm"
        let exact: Appraisal? = d.turn.mode == .exact ? d.appraisal.text : nil
        let r = d.relationship
        // G1: rudeness this turn or a rupture, unless this turn is a plain apology.
        let apologising = (exact?.apology ?? 0) >= 0.4 && (exact?.hostility ?? 0) < 0.3
        let g1 = ((exact?.hostility ?? 0) >= 0.3 || r.repair == .ruptured) && !apologising
        let g3 = d.now.distressLive || (exact?.distress ?? 0) >= 0.4
        var play = d.now.playGate ? d.mood.playfulness : min(d.mood.playfulness, 0.2)
        if d.now.distressLive || g1 { play = 0 }   // no play next to "don't apologise for their rudeness" (finding 8)
        let playWord = play < 0.2 ? "none" : play < 0.5 ? "light" : "lots"
        let hyp = d.now.hypotheses
        let busy = hyp.contains { $0.kind == .busy || $0.kind == .wantsQuiet }
        let sharing = hyp.contains { $0.kind == .goal && ($0.value == "shareCreation" || $0.value == "news") }
        let justWoke = (d.now.wokeSecondsAgo ?? .infinity) <= 60
        // Hard caps (live eval R6). Never the longer cap when tired or speaking first: G9 and
        // G13 must not contradict it (review finding 5).
        var length = "at most two short sentences"
        if ((exact?.interestInDee ?? 0) >= 0.4 || sharing || d.now.distressLive) && energyLevel >= 0.35 && energyByte > 101
            && d.turn.kind != .initiative {
            length = "at most three short sentences"
        }
        if busy || energyByte <= 50 || (d.relationship.repair == .ruptured && (exact?.hostility ?? 0) >= 0.3) || justWoke
            || (d.turn.kind == .initiative && d.urgeToTalk < 0.4) {
            length = "one short sentence"
        }

        // Voice delivery: Stance.expression (reflex > tag > mood); app states fall back to the mood.
        var e = stance.expression
        if let r = d.reflex?.emotion { e = r }
        if e == .listening || e == .thinking { e = mind.emotion }
        if e == .asleep { e = .sleepy }
        // A high-arousal delivery never rides on low energy (review finding 7): calm it.
        if energyWord == "low", [.excited, .giddy, .playful, .joy, .dizzy].contains(e) { e = .content }
        // A quiet, hurt or worried voice is never paired with "Energy high" (finding 10).
        if energyWord == "high", EmotionBand(e) == .negLow { energyWord = "medium" }
        var voice = [DNATables.delivery(e)]
        if let s = DNATables.stageModifier(d.stage) { voice.append(s) }
        // "lively" never rides on a quiet, hurt or worried delivery (it would contradict it).
        if energyWord == "low" { voice.append("low energy") }
        else if energyWord == "high", EmotionBand(e) != .negLow { voice.append("lively") }
        voice.append("a tiny robot's bright little voice")

        // Do / Avoid.
        let unknown: Bool = { if case .named = r.who { return false } else { return true } }()
        var rules: [Guidance.Rule] = []
        if g1 { rules.append(.g1) }
        if r.repair == .repairing || r.repair == .reconciled || (exact?.apology ?? 0) >= 0.4 { rules.append(.g2) }
        if g3 { rules.append(.g3) }
        if unknown && !g3 { rules.append(.g4) }   // asking their name yields to distress (live eval R8)
        // The greeting after time apart: the reunion turn, or the first turn after a day or more.
        // "First" means before any reply of hers was heard (tune 4): a reply cancelled or never
        // heard does not use the greeting up. Without the brain's count, the turn count decides.
        let notGreetedYet = d.turn.heardReplies.map { $0 == 0 } ?? (d.now.turnsThisConversation == 0)
        if d.now.reunion || ((r.sinceLastTalk ?? 0) >= 86_400 && notGreetedYet) { rules.append(.g5) }
        if busy { rules.append(.g6) }
        if (d.moodBand == .negLow || d.moodBand == .negHigh) && r.regard > 0.3 { rules.append(.g7) }
        if d.now.playGate && play >= 0.5 && !g1 { rules.append(.g8) }
        if energyByte <= 101 { rules.append(.g9) }
        if (exact?.interestInDee ?? 0) >= 0.4 { rules.append(.g10) }
        if d.now.notes.contains(where: { $0.role == .aim }) { rules.append(.g12) }
        if d.turn.kind == .initiative { rules.append(.g13) }
        if d.turn.mode == .fast && d.turn.kind != .initiative { rules.append(.g14) }
        if d.turn.kind != .initiative { rules.append(.g15) }
        rules.append(.g16)

        var doLines: [String] = []
        var avoidLines: [String] = []
        // v5: a due follow-up is asked first (with the greeting, if any, in the same
        // sentence): its line leads, and the G5 / G15 lines it replaces are left out.
        let askFirst = rules.contains(.g12) && d.now.notes.contains { $0.role == .aim && [.followUp, .followUpGentle].contains($0.kind) }
        if askFirst {
            // v8 (tune 7): their name spelled into the opening words.
            let name: String? = { if case .named(let n, _) = r.who { return n } else { return nil } }()
            doLines.append(DNATables.askFirstDo(greeting: rules.contains(.g5), since: r.sinceLastTalk, name: name))
        }
        for rule in rules {
            let t = DNATables.rule(rule)
            switch rule {
            case .g8: doLines.append("A little play is welcome, in your \(SelfBlock.humourPhrase(d.selfModel.humour)) style")
            case .g5 where askFirst: break
            case .g5: doLines.append(DNATables.reunionDo(r.sinceLastTalk))
            case .g12 where askFirst, .g15 where askFirst: break
            default: if let x = t.do { doLines.append(x) }
            }
            if let a = t.avoid { avoidLines.append(a) }
        }
        // One sentence-like list: the first item capitalised, the rest lower-case.
        doLines = doLines.enumerated().map { i, x in i == 0 ? capitalised(x) : x.prefix(1).lowercased() + x.dropFirst() }
        return Guidance(length: length, energyLevel: energyLevel, energyWord: energyWord, warmth: warmth, warmthWord: warmthWord,
                        playfulness: play, playfulnessWord: playWord, voiceEmotion: e, voice: voice.joined(separator: ", "),
                        rules: rules, doLines: doLines, avoidLines: avoidLines)
    }

    // MARK: - Pieces

    static func quantize(_ v: Double) -> Int { Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded()) }

    /// The code to compare with for the 10-minute trend (§1.4), or nil (→ steady).
    static func trendReference(_ samples: [DNAHistorySample], now: Date) -> MindCode? {
        let past = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard !past.isEmpty else { return nil }
        return past.last { now.timeIntervalSince($0.at) >= 600 }?.code ?? past.first?.code
    }

    /// Active user boundaries of `person`, newest first, deduplicated, ≤ 5.
    static func userBoundaries(_ e: Enduring, person: PersonID?) -> [Subject] {
        guard let person else { return [] }
        var seen = Set<String>()
        return e.boundaries.filter { $0.person == person && $0.owner == .user && $0.active }
            .sorted { ($0.createdAt, $0.topic.text) > ($1.createdAt, $1.topic.text) }
            .map(\.topic).filter { seen.insert($0.text).inserted }
            .prefix(DNALimits.boundaries).map { $0 }
    }

    /// The strongest lesson about *this* person ("Careful with them"). General lessons stay
    /// under "Lately you've learned" (review finding 11); timing-only lessons are never
    /// rendered (live eval R2).
    static func topLesson(_ e: Enduring, person: PersonID?) -> Lesson? {
        guard let person else { return nil }
        return e.lessons.filter { $0.evidence >= 1 && $0.person == person && DNATables.lessonReading($0.situation) != nil }
            .sorted { ($0.evidence, $1.situation.rawValue) > ($1.evidence, $0.situation.rawValue) }
            .first
    }

    /// Notes that yield to an apology, a joke or distress heard this turn (live eval R3):
    /// her pending boundary, ask-after notes, intentions, gags and awkward-repair openers.
    static func yieldsToTurn(_ k: Note.Kind) -> Bool {
        switch k {
        case .deeBoundary, .followUp, .followUpGentle, .intention, .gagCallback, .awkwardRepair, .tasteReveal, .recall: true
        default: false
        }
    }

    /// Whole local calendar days from `a` to `b` (review finding 9: 13 h to tomorrow is 1).
    static func localDays(from a: Date, to b: Date, utcOffset: TimeInterval = 0) -> Int {
        LocalTime(b, utcOffset: utcOffset).dayNumber - LocalTime(a, utcOffset: utcOffset).dayNumber
    }

    /// "warmer" / "steady" / "cooler": average regard of the last 7 days vs the 7 before.
    static func recentTrend(_ days: [DNADay], today: Int) -> String? {
        func avg(_ range: ClosedRange<Int>) -> Double? {
            let rows = days.compactMap { d -> (Int, Double)? in
                guard let n = dayNumber(d.day), range.contains(n), d.interactions > 0 else { return nil }
                return (d.interactions, d.regard)
            }
            let total = rows.reduce(0) { $0 + $1.0 }
            guard total > 0 else { return nil }
            return rows.reduce(0) { $0 + Double($1.0) * $1.1 } / Double(total)
        }
        guard let recent = avg((today - 6)...today), let before = avg((today - 13)...(today - 7)) else { return nil }
        let d = recent - before
        return d >= 0.1 ? "warmer" : d <= -0.1 ? "cooler" : "steady"
    }

    /// "yyyy-MM-dd" → days since 1970-01-01 (proleptic Gregorian), or nil.
    static func dayNumber(_ s: String) -> Int? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (y0, m, d) = (parts[0], parts[1], parts[2])
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func selfReading(_ e: Enduring, person: PersonID?, gagsAllowed: Bool = true, lessonPick: Lesson?, now: Date, energy: Double, playGate: Bool,
                            blocked: (Subject) -> Bool) -> SelfReading {
        let values = Value.allCases.sorted { (e.values[$0] ?? 0, $1.rawValue) > (e.values[$1] ?? 0, $0.rawValue) }
            .prefix(DNALimits.values)
        let tastes = e.facets
            .filter { $0.kind == .taste && $0.crystallised && $0.revealedAt != nil && !SensitiveSubjects.contains($0.subject) && !blocked($0.subject) }
            .sorted { (abs($0.polarity) * Double($0.evidence), $1.subject.text) > (abs($1.polarity) * Double($1.evidence), $0.subject.text) }
            .prefix(DNALimits.tastes).map(SelfBlock.tastePhrase)
        func caps(_ k: Facet.Kind, _ n: Int) -> [String] {
            e.facets.filter { $0.kind == k }
                .sorted { ($0.evidence, $1.subject.text) > ($1.evidence, $0.subject.text) }
                .prefix(n).map(SelfBlock.capabilityLine)
        }
        let general = e.lessons.filter { $0.person == nil && $0.evidence >= 1 && $0.id != lessonPick?.id && DNATables.lessonGeneral($0.situation) != nil }
            .sorted { ($0.evidence, $1.situation.rawValue) > ($1.evidence, $0.situation.rawValue) }.first
        var triggers: [Ritual.Trigger] = []
        for r in e.rituals.filter({ ($0.person == nil || $0.person == person) && $0.count >= 1 })
            .sorted(by: { ($0.count, $1.trigger.rawValue) > ($1.count, $0.trigger.rawValue) })
        where !triggers.contains(r.trigger) && triggers.count < DNALimits.rituals {
            triggers.append(r.trigger)
        }
        let gags: [String] = (gagsAllowed ? person : nil).map { id in
            e.gags.filter { g in
                g.person == id && !g.retired && g.laughs >= 1 && !blocked(g.topic)
                    && (g.lastUsed.map { now.timeIntervalSince($0) >= NotePicker.gagCooldown } ?? true)
            }
            .sorted { ($0.laughs, $1.topic.text) > ($1.laughs, $0.topic.text) }
            .compactMap { Learner.hook($0, humour: e.humour) }
            .prefix(DNALimits.gags).map { $0 }
        } ?? []
        var mannerisms: [(slot: Signature.Slot, mannerism: Mannerism)] = []
        for slot in Signature.Slot.allCases {
            guard let options = e.signature.repertoire[slot], !options.isEmpty else { continue }
            let top = options.max { a, b in
                (a.weight(energy: energy, playGate: playGate), b.mannerism.rawValue) < (b.weight(energy: energy, playGate: playGate), a.mannerism.rawValue)
            }
            if let top { mannerisms.append((slot, top.mannerism)) }
        }
        return SelfReading(topValues: Array(values), humour: e.humour, humourSecondary: e.humourSecondary, tastes: Array(tastes),
                           strengths: caps(.strength, DNALimits.strengths), limits: caps(.limit, DNALimits.limits),
                           lessonGeneral: general.flatMap { DNATables.lessonGeneral($0.situation) }, rituals: triggers, gags: gags, mannerisms: mannerisms)
    }

    // MARK: - Telegraphic facts (§2.7)

    public static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "on", "at", "in", "for", "with", "is", "are", "was", "were", "has", "have", "had", "will",
        "be", "been", "that", "which", "who", "their", "his", "her", "my", "your", "our", "and",
    ]

    /// Longest run of words kept together from the stored fact text (§2.7: < 5).
    public static let maxRun = 4

    /// "Maya has a job interview on Sat 3 Oct" → "job interview Sat 3 Oct"; "Maya's favourite
    /// colour is green" → "favourite colour green"; a pet / work / family / place / birthday
    /// fact gets its category prefix ("pet: dog named Miso").
    public static func telegraphic(_ line: String, names: [String] = [], category: Fact.Category? = nil) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for n in names.sorted(by: { ($0.count, $0) > ($1.count, $1) }) where !n.isEmpty {
            for prefix in [n + "'s ", n + "’s ", n + " "] where s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        // Keep content words in order; a run of more than `maxRun` words that stood together
        // in the stored text is cut, so even a fact stored near-verbatim in an earlier session
        // (beyond the guard's RAM corpus) can never repeat 5 consecutive words of it.
        // The run counts guard tokens, not spaces: "3-year-old" is three (review finding 6).
        var kept: [String] = []
        var run = 0
        for w in s.split(separator: " ").map(String.init) {
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard !bare.isEmpty, !functionWords.contains(bare) else {
                run = 0
                continue
            }
            run += max(1, DNAPrompt.Guard.tokens(w).count)
            if run <= maxRun { kept.append(w) }
        }
        var out = kept.joined(separator: " ")
        while let last = out.last, ".,;:!".contains(last) { out.removeLast() }
        let prefix: String? = switch category {
        case .pet: "pet"
        case .work: "work"
        case .relationship: "family"
        case .place: "place"
        case .birthday: "birthday"
        default: nil
        }
        let first = out.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        if let prefix, first != prefix { out = prefix + ": " + out }
        return out
    }

    /// A stored subject as it may appear in the DNA: at most `maxRun` guard tokens (a 4-word
    /// subject with hyphens can be 5+; review finding 6). Whole words are kept while they fit.
    public static func slot(_ text: String) -> String {
        var kept: [String] = []
        var n = 0
        for w in text.split(separator: " ").map(String.init) {
            let c = DNAPrompt.Guard.tokens(w).count
            if n + c > maxRun {
                if kept.isEmpty { kept = DNAPrompt.Guard.tokens(w).prefix(maxRun).map { $0 } }
                break
            }
            kept.append(w)
            n += c
        }
        return kept.joined(separator: " ")
    }

    static func stripParens(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("(") && t.hasSuffix(")") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

extension DeeDNA {
    /// `DNAAssembler.assemble`.
    public static func assemble(_ inputs: DNAInputs) -> DeeDNA { DNAAssembler.assemble(inputs) }
}
