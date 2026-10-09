import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct CueWriterTests {
    static func randomCode(_ rng: inout Rand) -> MindCode {
        var bytes = ""
        for _ in 0..<MindCode.parameterCount { bytes += String(format: "%02X", Int(rng.next() % 256)) }
        return MindCode(hex: bytes)!
    }

    // MARK: Golden parity with MindSnapshot.cue

    @Test func moodSentenceIsByteIdenticalForRandomCodes() {
        var rng = Rand(seed: 0xC0E)
        for i in 0..<500 {
            let code = Self.randomCode(&rng)
            let age: Double? = i % 3 == 0 ? nil : Double(rng.next() % 121)
            let snap = MindSnapshot(code: code, age: age)
            #expect(CueWriter.cue(mind: snap, notes: []) == snap.cue, "code \(code.hex) age \(String(describing: age))")
            #expect(CueWriter.open + CueWriter.mood(snap) + CueWriter.close == snap.cue)
        }
    }

    @Test func extremesAndEveryLifeStage() {
        for hex in [String(repeating: "00", count: 26), String(repeating: "FF", count: 26), String(repeating: "80", count: 26)] {
            for age in [nil, 0.5, 5, 15, 30, 80] as [Double?] {
                let s = MindSnapshot(code: MindCode(hex: hex)!, age: age)
                #expect(CueWriter.cue(mind: s, notes: []) == s.cue)
            }
        }
    }

    @Test func regardWordsMatchThresholds() {
        #expect(CueWriter.regardWords(-0.7) == "furious with them")
        #expect(CueWriter.regardWords(0.0) == "no strong feelings about them yet")
        #expect(CueWriter.regardWords(0.9) == "you adore them")
    }

    // MARK: Notes

    @Test func everyTemplateFitsThirtyTokensWithLongestSlots() {
        for kind in Note.Kind.allCases {
            for v in 0..<NoteTemplates.variants(kind) {
                let text = NoteTemplates.render(kind, slots: NoteTemplates.longestSlots(kind), variant: v)
                #expect(CueWriter.estimateTokens(text) <= CueWriter.maxNoteTokens, "\(kind) v\(v): \(text.count) chars")
                #expect(text.hasPrefix("(") && text.hasSuffix(")"))
                let over = NoteTemplates.render(kind, slots: NoteTemplates.slotCaps(kind).map { String(repeating: "word ", count: $0) }, variant: v)
                #expect(CueWriter.estimateTokens(over) <= CueWriter.maxNoteTokens, "\(kind): over-long slots are cut")
            }
        }
    }

    @Test func catalogueRolesAndPriorities() {
        #expect(Note.Kind.deeBoundary.priority == 1 && Note.Kind.awkwardRepair.priority == 16)
        #expect(Note.Kind.followUp.role == .aim && Note.Kind.recall.role == .context)
        #expect(Note.followUp(Subject("job interview")!, framing: .nervous).text == "(Ask how their job interview went. They were nervous about it.)")
        #expect(Note.followUp(Subject("surgery")!, framing: .nervous, gentle: true).text == "(Gently ask how today went.)")
        #expect(Note.lesson("check if they're joking").text == "(Careful: check if they're joking.)")
    }

    @Test func slotFitCutsAtWordBoundary() {
        #expect(NoteTemplates.fit("one two three", 9) == "one two")
        #expect(NoteTemplates.fit("short", 9) == "short")
    }

    /// The longest possible mood sentence (+ age voice note).
    static var worstMood: MindSnapshot {
        var f = Feelings()
        for x in Feeling.allCases { f[x] = 1 }
        f[.energy] = 0
        var p = Personality()
        p[.playfulness] = 1; p[.patience] = 0; p[.confidence] = 0; p[.agreeableness] = 0
        return MindSnapshot(code: MindCode(personality: p, feelings: f), age: 15)
    }

    @Test func wholeCueStaysUnderCap() {
        let mind = Self.worstMood
        let notes = Note.Kind.allCases.map { Note($0, slots: NoteTemplates.longestSlots($0)) }
        let cue = CueWriter.cue(mind: mind, notes: notes)
        #expect(CueWriter.estimateTokens(cue) <= CueWriter.maxTokens, "\(cue.count) chars")
        #expect(cue.hasPrefix(CueWriter.open + CueWriter.mood(mind)), "the mood always stays")
    }

    @Test func fitDropsContextFirstThenAim() {
        let mood = CueWriter.mood(Kit.snap())
        let aim = Note.intention(nextAction: "Ask one short question about the music they play.", intention: UUID())
        let ctx = Note.recall(gist: "they're learning watercolor", episode: UUID())
        let base = CueWriter.estimateTokens(CueWriter.cue(mood: mood, notes: []))
        let both = CueWriter.fit(mood: mood, notes: [ctx, aim])
        #expect(both.map(\.kind) == [.recall, .intention], "context, then aim")
        let aimOnly = CueWriter.estimateTokens(CueWriter.cue(mood: mood, notes: [aim]))
        #expect(CueWriter.fit(mood: mood, notes: [ctx, aim], budget: aimOnly).map(\.kind) == [.intention])
        #expect(CueWriter.fit(mood: mood, notes: [ctx, aim], budget: base).isEmpty)
    }

    @Test func fitKeepsAtMostOneAimAndOneContext() {
        let mood = CueWriter.mood(Kit.snap())
        let notes = [Note.deeBoundary(), Note.reconciled(), Note.cutOff(), Note.hesitation(), Note.deixisUnknown()]
        let f = CueWriter.fit(mood: mood, notes: notes)
        #expect(f.map(\.kind) == [.cutOff, .deeBoundary])
    }

    @Test func exampleCueFromTheDesign() {
        let snap = Kit.snap()
        let notes = [Note.recall(gist: "they're learning watercolor", episode: UUID()),
                     Note.intention(nextAction: "Ask about one choice they made in the painting.", intention: UUID())]
        let cue = CueWriter.cue(mind: snap, notes: notes)
        #expect(cue == "<dee_state>\(CueWriter.mood(snap)) (You remember: they're learning watercolor.) (Ask about one choice they made in the painting.)</dee_state>")
    }

    // MARK: NotePicker

    @Test func pickerAtMostTwoAndOneAim() {
        var picker = NotePicker()
        var rng = Rand(seed: 1)
        let m = Kit.moment()
        let all = Note.Kind.allCases.map { Note($0, slots: NoteTemplates.longestSlots($0), episode: UUID(), facet: UUID(), gag: UUID()) }
        for _ in 0..<50 {
            let picked = picker.pick(all, moment: m, mood: CueWriter.mood(m.ongoing.mind), rng: &rng)
            #expect(picked.count <= 2)
            #expect(picked.filter { $0.role == .aim }.count <= 1)
            #expect(picked.contains { $0.kind == .deeBoundary })
        }
    }

    @Test func pickerDistressGateAndCooldowns() {
        var picker = NotePicker()
        var rng = Rand(seed: 1)
        var m = Kit.moment()
        let mood = CueWriter.mood(m.ongoing.mind)
        let ep = UUID()
        m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        #expect(picker.pick([.recall(gist: "x", episode: ep), .intention(nextAction: "Ask.", intention: UUID())], moment: m, mood: mood, rng: &rng).isEmpty)
        m.ongoing.hypotheses = []
        #expect(picker.pick([.recall(gist: "x", episode: ep)], moment: m, mood: mood, rng: &rng).map(\.kind) == [.recall])
        for _ in 0..<3 { #expect(picker.pick([.recall(gist: "y", episode: UUID())], moment: m, mood: mood, rng: &rng).isEmpty, "one recall per 4 turns") }
        m.now = Kit.t0.addingTimeInterval(86_400)
        #expect(picker.pick([.recall(gist: "x", episode: ep)], moment: m, mood: mood, rng: &rng).isEmpty, "same episode within 2 days")
        #expect(picker.pick([.recall(gist: "y", episode: UUID())], moment: m, mood: mood, rng: &rng).map(\.kind) == [.recall])

        let h = Note.hypothesis("tired")
        #expect(picker.pick([h], moment: m, mood: mood, rng: &rng).count == 1)
        #expect(picker.pick([h], moment: m, mood: mood, rng: &rng).isEmpty)
        #expect(picker.pick([h], moment: m, mood: mood, rng: &rng).isEmpty)
        #expect(picker.pick([h], moment: m, mood: mood, rng: &rng).count == 1, "one per 3 turns")
    }

    @Test func pickerTasteOncePerConversationAndNoGagWhileStrained() {
        var picker = NotePicker()
        var rng = Rand(seed: 1)
        var m = Kit.moment()
        let mood = CueWriter.mood(m.ongoing.mind)
        let t = Note.tasteReveal(Subject("rain sounds")!, loves: true, facet: UUID())
        #expect(picker.pick([t], moment: m, mood: mood, rng: &rng).count == 1)
        #expect(picker.pick([t], moment: m, mood: mood, rng: &rng).isEmpty)
        m.ongoing.conversationStarted = Kit.t0.addingTimeInterval(3600)
        #expect(picker.pick([t], moment: m, mood: mood, rng: &rng).count == 1)
        m.ongoing.repair = .strained
        for _ in 0..<20 { #expect(picker.pick([.gagCallback(Subject("toast")!, style: .deadpan, gag: UUID())], moment: m, mood: mood, rng: &rng).isEmpty) }
    }

    @Test func pickerVariantsNeverRepeatImmediately() {
        var picker = NotePicker()
        var rng = Rand(seed: 9)
        let m = Kit.moment()
        var last: Int?
        for _ in 0..<40 {
            let v = picker.pick([.reunion()], moment: m, mood: CueWriter.mood(m.ongoing.mind), rng: &rng)[0].variant
            #expect(v != last)
            last = v
        }
    }

    @Test func contextMustNotContradictAim() {
        var picker = NotePicker()
        var rng = Rand(seed: 1)
        let m = Kit.moment()
        let picked = picker.pick([.misread(notX: "sad"), .reunion(), .hesitation()], moment: m, mood: CueWriter.mood(m.ongoing.mind), rng: &rng)
        #expect(picked.map(\.kind) == [.hesitation, .misread])
    }

    @Test func noReproachWordsInAnyTemplate() {
        for kind in Note.Kind.allCases {
            for v in 0..<NoteTemplates.variants(kind) {
                let text = NoteTemplates.render(kind, slots: NoteTemplates.longestSlots(kind), variant: v).lowercased()
                for w in CueWriter.reproachWords { #expect(!text.contains(w), "\(kind): \(w)") }
            }
        }
    }
}
