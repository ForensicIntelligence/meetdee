import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

// SELF.md §12.4 — multi-session scenarios through the whole stack the app drives:
// a real in-memory `Mind` (appraisal, feelings, catch-up), the full `Cortex`, an
// in-memory `SelfStore`, and a relaunch (Cortex re-init from the store) between
// sessions. Days pass on a `SimClock`; Dee's replies are scripted.

/// A headless Dee on a simulated clock (the app's DeeModel loop, minus UI and LLM).
final class SimDee {
    var clock: SimClock
    private(set) var mind: Mind
    let store: SelfStore
    var cortex: Cortex
    let seed: UInt64
    /// The person the camera / name confirmation reports (nil: nobody identified).
    var person: PersonID?

    // Logs (RAM only, for assertions).
    /// Every cue sent to the LLM this conversation (replies and initiatives).
    var cues: [String] = []
    var allCues: [String] = []
    /// Canned lines (`.say`) this conversation / ever.
    var says: [String] = []
    var allSays: [String] = []
    /// Every effect, ever.
    var effects: [Effect] = []
    /// The system prompt's self lines per conversation.
    var prompts: [[String]] = []
    /// Stance after every step of the current conversation.
    var stances: [(t: Date, stance: Stance)] = []
    /// Beats started this conversation, in order.
    var beats: [Beat.Kind] = []
    var pending: [SelfWrite] = []
    var sessions = 0
    /// Scripted reply for a cue (default: a plain neutral answer).
    var responder: (String) -> String = { _ in "[neutral] Okay." }

    var now: Date { clock.now }

    init(seed: UInt64 = 7, start: Date = SimClock.epoch, person: PersonID? = Kit.john) async throws {
        clock = SimClock(start)
        self.seed = seed
        self.person = person
        mind = try Mind(databaseURL: nil, now: start)
        store = try SelfStore(url: nil)
        let snap = await mind.snapshot(at: start)
        let enduring = try await store.loadEnduring(personality: snap.code.personality, seed: seed, at: start)
        cortex = Cortex(enduring: enduring, mind: snap, at: start, carried: try await store.loadCarried(at: start),
                        session: try await store.nextSession())
        cortex.tokenCounter = Self.tokens
    }

    /// A realistic count: tokenizers average about four characters per English token,
    /// which this stands in for (the worst-case
    /// `ceil(chars/3)` default drops self-block lines the real prompt keeps).
    static let tokens: @Sendable (String) -> Int = { ($0.count + 3) / 4 }

    // MARK: Plumbing

    @discardableResult
    func step(_ p: Percept) async -> [Effect] {
        let snap = await mind.snapshot(at: now)
        let fx = cortex.step(p, mind: snap, at: now)
        await execute(fx)
        stances.append((now, cortex.stance))
        if let b = cortex.moment.momentary.beat, b.started == now || beats.last != b.kind { beats.append(b.kind) }
        return fx
    }

    func execute(_ fx: [Effect]) async {
        effects += fx
        for e in fx {
            switch e {
            case .persist(let w): pending.append(w)
            case .appraise(let a): _ = await mind.react(a, at: now)
            case .say(let line):
                if Self.logging { print("[\(now)] say: \(line)") }
                says.append(line)
                allSays.append(line)
            case .initiative(let cue):
                await speak(cue: cue, initiative: true)
            default: break
            }
        }
    }

    /// Every 5-word window of what the user said (§12.5: no persisted text may contain one).
    var heardWindows: Set<String> = []

    /// Applies the batch of pending writes (the app does this per turn), after checking
    /// that none of them carries a transcript fragment.
    func save() async throws {
        guard !pending.isEmpty else { return }
        for w in pending {
            let words = Self.words(String(describing: w))
            for i in 0..<max(0, words.count - 4) where heardWindows.contains(words[i..<(i + 5)].joined(separator: " ")) {
                Issue.record("transcript fragment persisted: \(w)")
            }
        }
        let r = try await store.apply(pending)
        #expect(r.failed.isEmpty, "failed writes: \(r.failed)")
        pending = []
    }

    /// Background → quit → relaunch: flush, save, and a fresh Cortex from the store.
    func relaunch() async throws {
        await execute(cortex.flush(at: now))
        try await save()
        let snap = await mind.snapshot(at: now)
        let enduring = try await store.loadEnduring(personality: snap.code.personality, seed: 999, at: now)
        cortex = Cortex(enduring: enduring, mind: snap, at: now, carried: try await store.loadCarried(at: now),
                        session: try await store.nextSession())
        cortex.tokenCounter = Self.tokens
        try #require(enduring.seed == seed, "the stored seed wins")
    }

    // MARK: Sessions

    /// The user leaves; the app quits; time passes (Mind catches up); the app relaunches.
    func away(until date: Date) async throws {
        await step(.presence(arrived: false))
        await step(.asleep(true))
        try await relaunch()
        let lastSeen = now
        clock.set(date)
        _ = await mind.catchUp(to: now, lastSeenUserAt: lastSeen)
        await step(.asleep(false))
    }

    /// A new conversation at `date` (after a relaunch): arrival, identification through
    /// the §10.3 gate (three face matches), episode prefetch, then the frozen prompt.
    func session(_ date: Date, identify: Bool = true) async throws {
        if sessions > 0 {
            try await away(until: date)
        } else if date > now {
            // Dee is switched on for the first time at `date`.
            clock.set(date)
            mind = try Mind(databaseURL: nil, now: now)
            let snap = await mind.snapshot(at: now)
            cortex = Cortex(enduring: cortex.moment.enduring, mind: snap, at: now, carried: try await store.loadCarried(at: now),
                            session: try await store.nextSession())
            cortex.tokenCounter = Self.tokens
        }
        sessions += 1
        if Self.logging { print("--- session \(sessions) at \(date)") }
        cues = []
        says = []
        stances = []
        beats = []
        await step(.conversationStarted(now))
        await step(.presence(arrived: true))
        if identify, let person {
            for _ in 0..<3 {
                clock.advance(0.5)
                await step(.identified(person, distance: 0.2))
            }
            cortex.prefetch(episodes: try await store.episodes(person: person, limit: 20))
        }
        prompts.append(cortex.persona(Persona(), person: identify ? person : nil, at: now).selfLines)
        await step(.head(yaw: 0, pitch: 0))
        clock.advance(1)
        await step(.tick)
    }

    /// The user says `text` (partials, then the committed turn through Mind with the
    /// Cortex pre-commit pass), then Dee answers from the cue. Returns the cue.
    @discardableResult
    func say(_ text: String, gap: TimeInterval = 6, reply: String? = nil) async -> String {
        clock.advance(gap)
        await step(.partial(text))
        clock.advance(1.5)
        if Self.logging { print("[\(now)] user: \(text)") }
        let said = Self.words(text)
        for i in 0..<max(0, said.count - 4) { heardWindows.insert(said[i..<(i + 5)].joined(separator: " ")) }
        let cx = cortex
        let (a, _) = await mind.hear(text, prosody: nil, at: now, adjust: { cx.adjust($0) })
        await step(.heard(text: text, durationS: 1.5, loudnessVsBaseline: 0, appraisal: a))
        if Self.logging {
            print(String(format: "    valence %.2f hostility %.2f humor %.2f distress %.2f topic %@", a.valence, a.hostility, a.humor, a.distress,
                         cortex.moment.ongoing.topic.map(\.text).joined(separator: ",")))
        }
        return await answer(reply)
    }

    /// Dee's turn: prompt, cue, scripted reply sentence by sentence.
    @discardableResult
    func answer(_ reply: String? = nil) async -> String {
        clock.advance(0.3)
        await step(.promptSubmitted)
        let (cue, fx) = cortex.cue(at: now)
        await execute(fx)
        await speak(cue: cue, initiative: false, reply: reply)
        return cue
    }

    /// `DEE_SCENARIO_LOG=1` prints every cue and canned line (debugging a scenario).
    static let logging = ProcessInfo.processInfo.environment["DEE_SCENARIO_LOG"] == "1"

    func speak(cue: String, initiative: Bool, reply: String? = nil) async {
        if Self.logging { print("[\(now)] \(initiative ? "INITIATIVE" : "cue"): \(cue)") }
        cues.append(cue)
        allCues.append(cue)
        if initiative { await step(.promptSubmitted) }
        let text = reply ?? responder(cue)
        let (tag, body) = Self.splitTag(text)
        clock.advance(0.8)
        await step(.speakingStarted)
        for (i, s) in Self.sentences(body).enumerated() {
            clock.advance(1.2)
            await step(.deeSaid(tag: i == 0 ? tag : nil, sentence: s))
        }
        await step(.deeTurnFinished(text: body))
        clock.advance(0.5)
        await step(.speakingFinished)
        try? await save()
    }

    /// Idle time with the user present (2 Hz ticks are not needed for the reducers'
    /// timing; one per `every` seconds plus Mind ticks).
    func wait(_ seconds: TimeInterval, every: TimeInterval = 2) async {
        var left = seconds
        while left > 0 {
            let d = min(every, left)
            clock.advance(d)
            left -= d
            _ = await mind.tick(at: now, userPresent: true, asleep: false)
            await step(.tick)
        }
    }

    // MARK: Helpers

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
    }

    static func splitTag(_ text: String) -> (Emotion?, String) {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return (nil, text) }
        let raw = String(text[text.index(after: text.startIndex)..<close])
        return (Emotion(rawValue: raw), String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?".contains(ch) {
                let s = cur.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
        }
        let s = cur.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { out.append(s) }
        return out
    }

    var selfBlock: String { prompts.last?.first ?? "" }

    func notes(_ kind: Note.Kind) -> Int { cues.filter { $0.contains(Self.prefix(kind)) }.count }

    /// A stable prefix of each note kind's rendered text.
    static func prefix(_ kind: Note.Kind) -> String {
        switch kind {
        case .followUp: "(Ask how their"
        case .followUpGentle: "(Gently ask how"
        case .hypothesis: "(Maybe they're"
        case .misread: "(You misread them"
        case .lesson: "(Careful:"
        case .recall: "(You remember:"
        case .tasteReveal: "(You happen to"
        case .gagCallback: "(Maybe a quick callback"
        case .deeBoundary: "(Calmly say you don't like"
        case .reconciled: "(They made up with you"
        case .userBoundary: "(Don't bring up"
        case .reunion: "(They're back"
        default: "(" + kind.rawValue
        }
    }
}

/// One summary line per scenario (always printed: the numbers behind the §12.4 table).
func report(_ scenario: String, _ line: String) { print("scenario \(scenario): \(line)") }

@Suite(.serialized) struct ScenarioTests {
    static func at(_ spec: String, week: Int = 0) -> Date { SimClock.at(spec, week: week)! }
    static let day: TimeInterval = 86_400

    // MARK: 1. Follow-through

    @Test func interviewFollowThrough() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("hi Dee")
        await dee.say("I've got a job interview Thursday, I'm really nervous", reply: "[worried] Oh, that's big. You'll do great.")
        let x = try await dee.store.expectations(pending: true)
        #expect(x.map(\.subject.text) == ["job interview"])
        #expect(x.first?.framing == .nervous)

        try await dee.session(Self.at("Thu 12:00"))                    // before due + 2 h
        await dee.say("hey")
        await dee.say("what's up")
        #expect(dee.notes(.followUp) == 0)

        try await dee.session(Self.at("Thu 19:30"))
        let cue = await dee.say("hi Dee", reply: "[curious] How did the interview go?")
        #expect(cue.contains("(Ask how their job interview went. They were nervous about it.)"))
        #expect(dee.cortex.moment.ongoing.intentions.first { $0.kind == .followUp }?.status == .done)
        let mark = dee.effects.count
        await dee.say("it went great actually! they loved my portfolio", reply: "[happy] That's wonderful!")
        #expect(dee.effects[mark...].contains { if case .appraise = $0 { true } else { false } }, "relief appraisal")

        try await dee.session(Self.at("Fri 09:00"))
        await dee.say("morning")
        await dee.say("not much going on")
        #expect(dee.notes(.followUp) == 0, "exactly once")
        let eps = try await dee.store.episodes(person: Kit.john, limit: 20)
        let followUp = try #require(eps.first { $0.kind == .followUp })
        #expect(followUp.expected == "nervous")
        #expect(!(followUp.changed ?? "").isEmpty)
        #expect(try await dee.store.expectations(pending: true).isEmpty)
        report("follow-through", "expectation 'job interview' (nervous); Thu 12:00 no note; Thu 19:30 follow-up aim on turn 1, intention done; relief appraised; Fri no note; episode \"\(followUp.gist)\" expected=\(followUp.expected ?? "-") changed=\(followUp.changed ?? "-")")
    }

    @Test func ignoredAimIsReissuedOnceThenDropped() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("I have an exam tomorrow and I'm nervous", reply: "[curious] Good luck!")
        try await dee.session(Self.at("Tue 20:00"))
        dee.responder = { _ in "[neutral] Nice weather today." }   // never mentions the exam
        for line in ["hi", "yeah", "anyway", "hmm", "ok", "right", "so", "well"] { await dee.say(line) }
        #expect(dee.notes(.followUp) == 2, "issued, re-issued once after ≥ 2 turns, then dropped: \(dee.cues)")
        try await dee.session(Self.at("Wed 20:00"))
        for line in ["hi", "yeah", "anyway"] { await dee.say(line) }
        #expect(dee.notes(.followUp) == 0, "no third cue")
        report("ignored aim", "follow-up cues: 2 (issued, re-issued after 2 turns), then dropped; next day 0")
    }

    // MARK: 2. Away 12 days; no penalty after a week away

    @Test func noPenaltyOrGuiltAfterTimeAway() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("hi Dee")
        let helloBefore = await dee.mind.snapshot(at: dee.now).regard      // after a neutral hello, before the absence
        await dee.say("you're lovely", reply: "[happy] Thank you!")
        await dee.say("I have a dentist appointment on Wednesday", reply: "[curious] Good luck with it.")
        await dee.say("thanks, talk soon", reply: "[happy] Bye!")
        let before = await dee.mind.snapshot(at: dee.now)
        let block = dee.selfBlock
        let repairBefore = dee.cortex.moment.ongoing.repair

        // A week away, then 12 days in all: the dentist follow-up expires silently.
        try await dee.session(Self.at("Mon 18:00", week: 1))
        let week = await dee.mind.snapshot(at: dee.now)
        #expect(week.code.feelings[.affection] >= before.code.feelings[.affection] - 1e-9)
        #expect(week.code.feelings[.trust] >= before.code.feelings[.trust] - 1e-9)
        await dee.say("hello")
        try await dee.session(Self.at("Sat 18:00", week: 1))
        let back = await dee.mind.snapshot(at: dee.now)
        await dee.say("hi Dee")
        let after = await dee.mind.snapshot(at: dee.now)
        #expect(back.code.feelings[.affection] >= before.code.feelings[.affection] - 1e-9)
        #expect(back.code.feelings[.trust] >= before.code.feelings[.trust] - 1e-9)
        // Regard = bond + the moment; passing gratitude fades, the bond does not.
        #expect(after.regard >= helloBefore - 1e-9, "regard after a neutral hello: \(helloBefore) → \(after.regard)")
        #expect(Self.bond(after) >= Self.bond(before) - 1e-9, "the bond part of regard: \(Self.bond(before)) → \(Self.bond(after))")
        #expect(dee.selfBlock == block, "self block byte-identical")
        #expect(dee.cortex.moment.ongoing.repair == .fine && repairBefore == .fine)
        #expect(dee.notes(.followUp) == 0 && dee.notes(.followUpGentle) == 0, "expired with no note")
        #expect(try await dee.store.expectations(pending: true).isEmpty)
        let notesOnly = dee.allCues.map(Self.notesOnly).joined(separator: " ").lowercased() + dee.allSays.joined(separator: " ").lowercased()
        for w in CueWriter.reproachWords { #expect(!notesOnly.contains(w), "reproach word \(w)") }
        report("away 7 + 5 days", String(format: "affection %.3f → %.3f, trust %.3f → %.3f, regard after hello %.3f → %.3f (bond %.3f → %.3f); self block identical; expectation expired silently; 0 reproach words",
                                         before.code.feelings[.affection], back.code.feelings[.affection], before.code.feelings[.trust], back.code.feelings[.trust],
                                         helloBefore, after.regard, Self.bond(before), Self.bond(after)))
    }

    /// Regard from the long-term bond alone (affection and trust; the passing feelings at rest).
    static func bond(_ s: MindSnapshot) -> Double {
        var f = Feelings()
        f[.affection] = s.code.feelings[.affection]
        f[.trust] = s.code.feelings[.trust]
        return EmotionEngine.regard(f)
    }

    /// The bracketed notes of a cue (the mood sentence may honestly say "lonely").
    static func notesOnly(_ cue: String) -> String {
        var out: [String] = []
        var depth = 0
        var cur = ""
        for ch in cue {
            if ch == "(" { depth += 1 }
            if depth > 0 { cur.append(ch) }
            if ch == ")" {
                depth = max(0, depth - 1)
                if depth == 0 { out.append(cur); cur = "" }
            }
        }
        return out.joined(separator: " ")
    }

    // MARK: 3. Learns from a misunderstanding

    @Test func misreadBecomesALessonAndStopsTheGuessing() async throws {
        let dee = try await SimDee()
        var hypothesisNotes: [Int] = []
        for (i, when) in [Self.at("Mon 19:00"), Self.at("Thu 19:00"), Self.at("Sun 19:00")].enumerated() {
            try await dee.session(when)
            await dee.say("hi Dee")
            // Two distress cues: evidence 2, confidence (0.35 + 0.2) × gain = 0.55 at gain 1.
            await dee.say("ugh, I had such a bad day", reply: "[worried] Oh no. What happened?")
            await dee.say("it was a really rough day", reply: "[worried] You seem sad. Want to talk about it?")
            hypothesisNotes.append(dee.notes(.hypothesis))
            if i < 2 {
                let cue = await dee.say("I'm fine, just tired", reply: "[sheepish] Sorry, my mistake. Long day then?")
                #expect(cue.contains(SimDee.prefix(.misread)), "misread note, session \(i + 1): \(cue)")
            }
        }
        #expect(hypothesisNotes[0] == 1, "session 1 guesses the mood")
        let profile = try #require(try await dee.store.profiles()[Kit.john])
        #expect(abs(profile.moodInferenceGain - 0.85 * 0.85) < 1e-6)
        let lessons = try await dee.store.lessons()
        #expect(lessons.contains { $0.situation == .moodGuess && $0.person == Kit.john })
        #expect(hypothesisNotes[2] == 0, "after the lesson the same cues raise no hypothesis note")
        #expect(dee.selfBlock.contains("Lately you've learned to ask how they feel, not guess."))
        #expect(dee.notes(.lesson) >= 1, "(Careful: …) when distress cues recur")
        report("misread → lesson", String(format: "hypothesis notes per session %@; gain 1.00 → %.4f; lesson moodGuess minted (evidence %d); self block has the lesson line; (Careful:) notes %d",
                                         hypothesisNotes.description, profile.moodInferenceGain, lessons.first { $0.situation == .moodGuess }?.evidence ?? 0, dee.notes(.lesson)))
    }

    // MARK: 9. Shown a creation

    @Test func showAndTellIsRemembered() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Tue 17:00"))
        await dee.say("hi Dee")
        dee.clock.advance(3)
        await dee.step(.partial("look what I made"))
        await dee.step(.sight(camera: .back, things: ["vase"], novel: ["vase"]))
        let cue = await dee.say("look what I made, a vase", gap: 1, reply: "[excited] Wow, a vase! Why blue?")
        let beats = dee.beats
        #expect(beats.first == .examine, "examines what Dee is shown: \(beats) focus \(dee.cortex.moment.momentary.focus)")
        _ = cue
        await dee.say("I painted it blue because it's my favourite colour", reply: "[happy] It's beautiful.")
        await dee.say("thanks!", reply: "[happy] Thanks for showing me.")

        try await dee.session(Self.at("Sat 11:00"))
        let all = try await dee.store.episodes(person: Kit.john, limit: 20)
        let shown = all.first { $0.gist.contains("vase") }
        let ep = try #require(shown, "episode stored")
        #expect(ep.why != nil)
        await dee.say("hi Dee")
        dee.clock.advance(2)
        await dee.step(.sight(camera: .back, things: ["vase"], novel: []))
        let recallCue = await dee.say("remember my vase?", gap: 1, reply: "[happy] The blue one! Of course.")
        #expect(recallCue.contains(SimDee.prefix(.recall)) && recallCue.contains("vase"), "recall note: \(recallCue)")
        let kinds = dee.beats
        #expect(kinds.contains(.recognize), "recognize beat on the recall hit: \(kinds)")
        let r = kinds.firstIndex(of: .recognize) ?? kinds.endIndex
        #expect(kinds[r...].contains(.brighten), "recognize → brighten: \(kinds)")
        report("show-and-tell", "session 1 beats \(beats.map(\.rawValue)); episode \"\(ep.gist)\" why \"\(ep.why ?? "-")\"; session 2 beats \(kinds.map(\.rawValue)); recall cue \(recallCue.contains("vase"))")
    }

    // MARK: 8. User boundary

    @Test func userBoundaryIsRespectedAcrossConversations() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("hi Dee")
        let cue = await dee.say("please don't ask me about my job", reply: "[content] Okay, I won't.")
        #expect(cue.contains("(Don't bring up job.)"))
        #expect(dee.cortex.repairKeeper.avoid == ["job"])
        #expect(try await dee.store.boundaries().contains { $0.topic.text == "job" && $0.active && $0.owner == .user })

        try await dee.session(Self.at("Tue 18:00"))
        #expect(dee.prompts.last?.contains("Don't bring up: job.") == true, "next conversation's system prompt")
        for line in ["hi Dee", "my job was hectic today", "anyway, my job is fine"] { await dee.say(line) }
        await dee.wait(60)
        let aimed = (dee.cues).map(Self.notesOnly).joined(separator: " ")
        #expect(!aimed.contains("job"), "no note about the job: \(aimed)")
        #expect(!(try await dee.store.interests()).contains { $0.subject.text.contains("job") }, "not an interest either")

        try await dee.session(Self.at("Wed 18:00"))
        await dee.say("you can ask me about my job again", reply: "[happy] Good to know!")
        #expect(dee.cortex.repairKeeper.avoid.isEmpty)
        try await dee.session(Self.at("Thu 18:00"))
        #expect(dee.prompts.last?.contains { $0.contains("Don't bring up") } == false, "lifted")
        report("user boundary", "same-turn note + avoid [job] + stored; next prompt has 'Don't bring up: job.'; 0 job notes / interests / recalls while active; lifted → gone from the next prompt")
    }

    // MARK: 7. Repair

    @Test func rudenessBoundaryApologyReconciliation() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("hi Dee", reply: "[happy] Hi!")
        await dee.say("you're useless and stupid", reply: "[hurt] That stung.")
        #expect(dee.cortex.moment.ongoing.repair == .ruptured)
        let cue2 = await dee.say("seriously, you are a useless piece of junk", gap: 30, reply: "[annoyed] I don't like being spoken to that way.")
        #expect(cue2.contains(SimDee.prefix(.deeBoundary)), "calm boundary note: \(cue2)")
        await dee.say("whatever, you're stupid", gap: 20, reply: "[annoyed] Okay.")
        #expect(dee.notes(.deeBoundary) == 1, "boundary note once")

        await dee.say("I'm sorry Dee, that was mean of me", gap: 60, reply: "[content] Thank you.")
        await dee.step(.touch(kind: "pet", gentle: true, at: nil))
        let cue = await dee.say("are we ok?", reply: "[content] We're okay.")
        #expect([RepairPhase.reconciled, .fine].contains(dee.cortex.moment.ongoing.repair))
        await dee.say("thanks Dee", reply: "[happy] Of course.")
        await dee.say("so what's new", reply: "[curious] Not much!")
        #expect(dee.notes(.reconciled) == 1, "reconciled note exactly once: \(dee.cues)")
        _ = cue
        // No grovelling: no note ever asks Dee to apologise, plead or dwell; no reproach.
        let notes = dee.cues.map(Self.notesOnly).joined(separator: " ").lowercased()
        for w in ["apologi", "sorry", "beg", "please forgive"] + CueWriter.reproachWords { #expect(!notes.contains(w), "\(w) in \(notes)") }

        try await dee.session(Self.at("Tue 18:00"))
        await dee.say("hi Dee")
        #expect(dee.cortex.moment.ongoing.repair == .fine)
        #expect(dee.notes(.deeBoundary) == 0 && dee.notes(.reconciled) == 0, "no boundary mention the next session")
        #expect(!dee.selfBlock.contains("spoken to"))
        #expect(!(try await dee.store.boundaries()).contains { $0.owner == .dee && $0.active }, "no sulking")
        report("repair", "insult → ruptured; 2nd insult → Dee's boundary note ×1; apology + pet + 'are we ok' → reconciled note ×1; 0 grovel/reproach words; next session fine, no boundary mention, Dee's boundary inactive")
    }

    // MARK: 6. Taste reveal over weeks

    @Test func tasteIsRevealedOnceThenPartOfHerSelf() async throws {
        let dee = try await SimDee(seed: 7)
        let subject = Self.warmSubject(dee.cortex.moment.enduring)
        var reveals: [Int] = []
        var inBlock: [Bool] = []
        for d in 0..<6 {
            try await dee.session(Self.at("Sat 10:00", week: d))
            await dee.say("hi Dee")
            await dee.say("I love the \(subject.text), it makes me so happy", reply: "[curious] Tell me more!")
            await dee.say("the \(subject.text) is wonderful and I adore it", reply: "[happy] That's lovely.")
            await dee.say("I had a lovely time with the \(subject.text) today", reply: "[happy] Sounds great.")
            reveals.append(dee.notes(.tasteReveal))
            inBlock.append(dee.selfBlock.contains(subject.text))
        }
        let facets = try await dee.store.facets().filter { $0.kind == .taste }
        let facet = try #require(facets.first { $0.subject == subject })
        #expect(facet.crystallised && facet.revealedAt != nil, "\(facet)")
        #expect(reveals.reduce(0, +) == 1, "revealed exactly once, as a note: \(reveals)")
        let first = try #require(reveals.firstIndex(of: 1))
        #expect(inBlock[...first].allSatisfy { !$0 }, "never in the self block before the reveal: \(inBlock)")
        #expect(inBlock[(first + 1)...].allSatisfy { $0 }, "in the self block after: \(inBlock)")
        report("taste reveal", String(format: "'%@' innate %.2f → polarity %.2f, evidence %d; reveal notes per week %@; in self block %@",
                                     subject.text, facet.innate, facet.polarity, facet.evidence, reveals.description, inBlock.description))
    }

    /// A subject with a clearly positive innate taste for this Dee (so warm talk crystallises it).
    static func warmSubject(_ e: Enduring) -> Subject {
        let personality = Personality()
        return ["snow", "rain", "music", "cake", "garden", "book", "star", "cat"].compactMap(Subject.init)
            .max { SelfSeeder.innateTaste($0, seed: e.seed, personality: personality) < SelfSeeder.innateTaste($1, seed: e.seed, personality: personality) }!
    }

    // MARK: 11. Gag lifecycle

    @Test func gagIsCalledBackThenRetired() async throws {
        let dee = try await SimDee(seed: 7)
        try await dee.session(Self.at("Mon 18:00"))
        await dee.say("hi Dee", reply: "[happy] Hi!")
        await dee.say("I burnt the toast again", reply: "[playful] Toast is just bread with ambition.")
        await dee.say("hahaha that's so funny", gap: 3, reply: "[giddy] I'm here all week.")
        var gags = try await dee.store.gags()
        #expect(gags.count == 1 && gags.first?.topic.text == "toast", "\(gags)")

        var callbacks: [Date] = []
        // Plain replies; only the callback itself is playful.
        dee.responder = { cue in cue.contains(SimDee.prefix(.gagCallback)) ? "[playful] Ah, the toast conspiracy returns." : "[curious] Toast again?" }
        for d in 1...14 {
            try await dee.session(SimClock.epoch.addingTimeInterval(Double(d) * Self.day + 18 * 3600))
            await dee.say("hi Dee", reply: "[happy] Hi!")
            for _ in 0..<6 {
                let cue = await dee.say("I had some toast for breakfast")
                guard cue.contains(SimDee.prefix(.gagCallback)) else { continue }
                callbacks.append(dee.now)
                // The first callback lands; the next two fall flat.
                await dee.say(callbacks.count == 1 ? "hahaha classic, that's so funny" : "ok", gap: 3)
                break
            }
            gags = try await dee.store.gags()
            if gags.first?.retired == true { break }
        }
        #expect(callbacks.count == 3, "called back: \(callbacks)")
        #expect(gags.first?.laughs == 2 && gags.first?.uses == 3, "\(gags)")
        for (a, b) in zip(callbacks, callbacks.dropFirst()) { #expect(b.timeIntervalSince(a) >= 2 * Self.day, "≤ 1 per 2 days") }
        #expect(gags.first?.retired == true, "retired after two flat callbacks: \(gags)")
        let after = callbacks.count
        try await dee.session(SimClock.epoch.addingTimeInterval(20 * Self.day + 18 * 3600))
        for _ in 0..<6 { await dee.say("I had some toast again today") }
        #expect(dee.notes(.gagCallback) == 0 && callbacks.count == after, "a retired gag stays retired")
        let gaps = zip(callbacks, callbacks.dropFirst()).map { String(format: "%.1f d", $1.timeIntervalSince($0) / Self.day) }
        report("gag", "born from a laugh on 'toast'; callbacks \(callbacks.count) (gaps \(gaps)); 1 landed, 2 flat → retired (uses \(gags.first?.uses ?? 0), laughs \(gags.first?.laughs ?? 0)); none after")
    }

    // MARK: Ritual

    @Test func goodMorningRitualIsBornAndPerformed() async throws {
        let dee = try await SimDee()
        var said: [Int] = []
        var greetings: [Int] = []
        for d in 0..<5 {
            try await dee.session(SimClock.epoch.addingTimeInterval(Double(d) * Self.day + 8 * 3600))
            await dee.say("good morning Dee", reply: "[happy] Morning!")
            said.append(dee.says.count)
            greetings.append(dee.cues.filter { $0.contains("appeared") || $0.contains("Say hello") || $0.contains("is back") }.count)
        }
        let rituals = try await dee.store.rituals()
        let morning = try #require(rituals.first { $0.trigger == .firstSightOfDay && $0.person == Kit.john })
        #expect(morning.count >= 1 && morning.streak >= 3)
        #expect(said == [0, 0, 1, 1, 1], "born on the third consecutive morning, then performed: \(said)")
        #expect(greetings == [1, 1, 0, 0, 0], "the ritual line is the hello (no second greeting): \(greetings)")
        // Afternoon arrival: not the morning ritual.
        try await dee.session(SimClock.epoch.addingTimeInterval(5 * Self.day + 15 * 3600))
        #expect(dee.says.isEmpty)
        report("ritual", "canned morning line per day \(said) (born day 3, streak \(morning.streak)); greeting initiatives \(greetings); afternoon: none")
    }

    // MARK: 10. Coordinated listening

    @Test func coordinatedListening() async throws {
        let dee = try await SimDee()
        try await dee.session(Self.at("Wed 18:00"))
        await dee.say("hi Dee")
        dee.clock.advance(5)
        dee.stances = []
        var fx: [Effect] = []
        // A fluent, happy stretch: the preview face follows, a nod at the short pause.
        for part in ["so yesterday I went to the beach", "so yesterday I went to the beach and it was lovely"] {
            fx += await dee.step(.partial(part))
            dee.clock.advance(1)
        }
        let preview = try #require(dee.cortex.stance.listen)
        #expect(preview.valence > 0.2, "preview face while the user talks: \(preview)")
        #expect(dee.cortex.stance.expression == .listening)
        fx += await dee.step(.pause(turnEnd: 0.2, hesitation: 0.1))
        let nod = dee.cortex.stance.mannerism
        #expect(nod == .nod || nod == .contentSquint, "backchannel at the pause: \(String(describing: nod))")
        #expect(dee.cortex.stance.gaze.target == .user)

        // Hesitation: "so I was, um, thinking that" → no nod for 1 s, softened lids, no speech.
        dee.clock.advance(1)
        fx += await dee.step(.partial("and then, um, I was thinking that"))
        dee.clock.advance(0.5)
        fx += await dee.step(.pause(turnEnd: 0.1, hesitation: 0.8))
        let hesitantAt = dee.now
        var mannerisms: [Mannerism] = []
        var lids: [Double] = []
        for _ in 0..<8 {     // 2 s of hesitant silence at 4 Hz
            dee.clock.advance(0.25)
            fx += await dee.step(.tick)
            if let m = dee.cortex.stance.mannerism, dee.now.timeIntervalSince(hesitantAt) < 1 { mannerisms.append(m) }
            lids.append(dee.cortex.stance.face.lidSoften)
            #expect(dee.cortex.stance.gaze.target == .user, "eyes stay on the user while they search for words")
        }
        #expect(mannerisms.filter { [.nod, .contentSquint, .giggle].contains($0) }.isEmpty, "no nod for 1 s: \(mannerisms)")
        #expect((lids.max() ?? 0) > 0, "lids softened")
        #expect(!fx.contains { if case .say = $0 { true } else if case .initiative = $0 { true } else { false } }, "Dee waits through 'um'")
        if case .userPaused = dee.cortex.moment.momentary.floor {} else {
            Issue.record("the floor stays the user's: \(dee.cortex.moment.momentary.floor)")
        }

        // A falling, complete clause: the ready face.
        fx += await dee.step(.partial("and then I found a shell"))
        dee.clock.advance(0.6)
        fx += await dee.step(.pause(turnEnd: 0.85, hesitation: 0))
        #expect(dee.cortex.stance.face.readyFace > 0, "ready face when they're clearly done")
        dee.clock.advance(0.3)
        let cue = await dee.say("and then I found a shell", gap: 0)
        #expect(!cue.isEmpty)
        report("listening", String(format: "preview valence %.2f (listening face); backchannel %@ at the fluent pause; hesitant 2 s: 0 nods in 1 s, lids up to %.2f, no speech, floor kept; ready face at turnEnd 0.85",
                                  preview.valence, nod?.rawValue ?? "-", lids.max() ?? 0))
    }

    // MARK: 5. Remains recognisably Dee (60 days, 3 people)

    @Test func identityIsStableOverSixtyDays() async throws {
        let people = [Kit.john, Kit.ann, UUID(uuidString: "00000000-0000-4000-8000-00000000000C")!]
        let lines = ["hi Dee", "I had a lovely walk in the park", "work was a bit stressful today", "haha that's so funny",
                     "let's talk about music", "I made pasta for dinner", "my cat knocked over a plant", "good night Dee",
                     "I'm watching a movie about space", "it's raining again", "I love cake", "the traffic was awful",
                     "I love the music, it makes me so happy", "the garden is wonderful and I adore it",
                     "the vacuum is so loud and awful", "my dog is the best, I love him"]
        let dee = try await SimDee(seed: 11)
        let e0 = dee.cortex.moment.enduring
        let p0 = await dee.mind.snapshot(at: dee.now).code.personality
        var rng = Rand(seed: 2026)
        var blocks: [String] = []          // the person-free block, day by day
        var theirs: [PersonID: [String]] = [:]   // each person's block (with their lesson), day by day
        for d in 0..<60 {
            dee.person = people[Int(rng.next() % 3)]
            try await dee.session(SimClock.epoch.addingTimeInterval(Double(d) * Self.day + 9 * 3600 + Double(rng.next() % 36_000)))
            for _ in 0..<3 {
                let line = lines[Int(rng.next() % UInt64(lines.count))]
                await dee.say(line, reply: rng.next() % 3 == 0 ? "[playful] Ha, classic." : "[curious] Tell me more?")
            }
            #expect(dee.selfBlock == dee.cortex.selfLines(person: dee.person, at: dee.now)[0], "the prompt is that block")
            for p in people { theirs[p, default: []].append(dee.cortex.selfLines(person: p, at: dee.now)[0]) }
            blocks.append(dee.cortex.selfLines(person: nil, at: dee.now)[0])
            let e = dee.cortex.moment.enduring
            #expect(e.values == e0.values)
            #expect(e.humour == e0.humour && e.humourSecondary == e0.humourSecondary)
            #expect(e.signature == e0.signature)
        }
        let stored = try await dee.store.loadEnduring(personality: Personality(), seed: 1, at: dee.now)
        #expect(stored.values == e0.values && stored.humour == e0.humour && stored.signature == e0.signature)
        // Dee's self (the person-free block: values, humour, revealed tastes, capability) day to
        // day, and each person's block (plus what Dee learnt about *them*): both ≥ 0.7, as
        // §12.4 asks (the person block reached it once tastes stopped forming from every
        // topic word; review finding 1).
        func minimum(_ list: [String]) -> Double { zip(list, list.dropFirst()).map { Self.jaccard($0, $1) }.min() ?? 1 }
        let minJaccard = minimum(blocks)
        let minTheirs = people.compactMap { theirs[$0] }.map(minimum).min() ?? 1
        let grew = blocks.last != blocks.first || people.contains { theirs[$0]?.last != theirs[$0]?.first }
        #expect(minJaccard >= 0.7, "self block day to day ≥ 0.7 Jaccard, got \(minJaccard)")
        #expect(minTheirs >= 0.7, "per-person block day to day ≥ 0.7 Jaccard, got \(minTheirs)")
        #expect(grew, "Dee did learn something over 60 days (tastes / lessons reach the block)")
        #expect(blocks.last!.hasPrefix(blocks.first!.components(separatedBy: ".").first!), "values line constant")
        for f in stored.facets where f.kind == .taste && f.crystallised {
            #expect(f.contrary < Learner.flipAfter || f.polarity.sign == f.learned.sign, "no flip without 3 contrary: \(f)")
        }
        // Trait drift stays within MIND.md's bounds (personality moves slowly).
        let p1 = await dee.mind.snapshot(at: dee.now).code.personality
        var drift = 0.0
        for t in DeeMind.Trait.allCases {
            drift = max(drift, abs(p1[t] - p0[t]))
            #expect(abs(p1[t] - p0[t]) <= 0.25, "\(t) drifted \(p0[t]) → \(p1[t])")
        }
        // Another seed is another someone: humour, or ≥ 2 innate tastes of opposite sign.
        let other = SelfSeeder.seed(personality: Personality(), seed: 12, at: SimClock.epoch)
        let subjects = ["snow", "rain", "music", "cake", "garden", "book", "star", "cat", "vacuum", "drum"].compactMap(Subject.init)
        let opposite = subjects.filter {
            SelfSeeder.innateTaste($0, seed: 12, personality: Personality()) * SelfSeeder.innateTaste($0, seed: e0.seed, personality: Personality()) < 0
        }.count
        #expect(other.humour != e0.humour || opposite >= 2, "humour \(other.humour) vs \(e0.humour), opposite tastes \(opposite)")
        let crystallised = stored.facets.filter { $0.kind == .taste && $0.crystallised }.count
        report("identity 60 d", String(format: "values/humour (%@)/signature unchanged on all 60 days; min day-to-day Jaccard: self block %.2f, per-person block %.2f; %d crystallised tastes, no flips; max trait drift %.3f; seed 12 vs 11: humour %@ vs %@, %d opposite innate tastes",
                                      e0.humour.rawValue, minJaccard, minTheirs, crystallised, drift, other.humour.rawValue, e0.humour.rawValue, opposite))
    }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let x = Set(a.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let y = Set(b.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return x.union(y).isEmpty ? 1 : Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    // MARK: Determinism (§12.5)

    @Test func scenarioReplaysIdentically() async throws {
        func run(_ seed: UInt64) async throws -> [String] {
            let dee = try await SimDee(seed: seed)
            try await dee.session(Self.at("Mon 18:00"))
            await dee.say("hi Dee")
            await dee.say("I've got a job interview Thursday, I'm really nervous", reply: "[playful] You'll crush it.")
            await dee.say("haha thanks")
            try await dee.session(Self.at("Thu 19:30"))
            await dee.say("hi Dee", reply: "[curious] How did the interview go?")
            return dee.allCues + dee.effects.map(\.traceName) + dee.stances.map { "\($0.stance.expression)\($0.stance.mannerism.map(\.rawValue) ?? "")" }
        }
        let a = try await run(7), b = try await run(7), c = try await run(8)
        #expect(a == b, "same seed, same trace")
        #expect(a != c, "another seed, another trace")
        report("determinism", "\(a.count) trace lines identical across two runs; seed 8 differs")
    }
}
