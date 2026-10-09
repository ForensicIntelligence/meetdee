import Testing
@testable import DeeCore

/// Thinking without a local model: per-response reasoning effort (audit C7, review
/// M3). These are the rules the old agent loop applied, now pure and table-tested.
@Suite struct ThinkingModeTests {
    @Test func thinkingIsOffByDefault() {
        var mode = ThinkingMode()
        let turn = mode.turn(for: "Hello Dee")
        #expect(turn == ThinkingMode.Turn(thinks: false, modeChanged: nil))
        #expect(turn.reasoningEffort == .low)
        #expect(!mode.isOn)
    }

    @Test func aThinkRequestThinksForThisReplyOnly() {
        var mode = ThinkingMode()
        let first = mode.turn(for: "Please think about it: is 7 prime?")
        #expect(first.thinks)
        #expect(first.modeChanged == nil, "a one-off request does not switch the mode")
        #expect(first.reasoningEffort == .medium)
        #expect(!mode.isOn)
        // Review M3: the next turn is fast again.
        #expect(mode.turn(for: "And what about tomorrow?") == ThinkingMode.Turn(thinks: false, modeChanged: nil))
    }

    @Test func thinkingModeStaysOnUntilSwitchedOff() {
        var mode = ThinkingMode()
        #expect(mode.turn(for: "Turn on thinking mode. Will it rain today?") == ThinkingMode.Turn(thinks: true, modeChanged: true))
        #expect(mode.isOn)
        #expect(mode.turn(for: "And what about tomorrow?") == ThinkingMode.Turn(thinks: true, modeChanged: nil))
        #expect(mode.turn(for: "Use thinking mode again") == ThinkingMode.Turn(thinks: true, modeChanged: nil), "already on: no second event")
        let off = mode.turn(for: "Stop thinking so hard.")
        #expect(off == ThinkingMode.Turn(thinks: false, modeChanged: false))
        #expect(off.reasoningEffort == .low)
        #expect(!mode.isOn)
    }

    @Test func stopThinkingWhileOffChangesNothing() {
        var mode = ThinkingMode()
        #expect(mode.turn(for: "Stop thinking.") == ThinkingMode.Turn(thinks: false, modeChanged: nil))
    }

    @Test func narrationNeverSwitchesItOn() {
        var mode = ThinkingMode()
        for line in ["I think about my dad a lot", "my teacher told me to think hard", "What do you think about cats?"] {
            #expect(!mode.turn(for: line).thinks, "\(line)")
        }
        #expect(!mode.isOn)
    }

    @Test func theDebugToggleSetsTheMode() {
        var mode = ThinkingMode()
        mode.set(true)
        #expect(mode.turn(for: "Hi!").thinks)
        mode.set(false)
        #expect(!mode.turn(for: "Hi!").thinks)
    }

    @Test func effortsAreTheAPIValues() {
        #expect(ReasoningEffort.allCases.map(\.rawValue) == ["minimal", "low", "medium", "high", "xhigh"])
        #expect(ThinkingMode.chatEffort == .low)
        #expect(ThinkingMode.thinkingEffort == .medium)
    }

    /// Review F1: in fast mode the reply is requested on the server's commit,
    /// before the transcript. Its effort is the mode's; the words, when they come,
    /// update the mode and say whether the reply deserved more thought.
    @Test func fastModeUsesTheModeAndFlagsAThinkRequestThatCameLate() {
        var mode = ThinkingMode()
        #expect(mode.effortBeforeWords == .low)
        let late = mode.wordsArrived("Think hard: is 91 prime?", answeredAt: mode.effortBeforeWords)
        #expect(late.turn.thinks && late.rethink, "asked to think, answered at chat effort")
        #expect(!mode.isOn, "a one-off request does not switch the mode on")
        #expect(mode.effortBeforeWords == .low)

        let chat = mode.wordsArrived("Hello there", answeredAt: .low)
        #expect(!chat.rethink)

        let on = mode.wordsArrived("Turn on thinking mode", answeredAt: .low)
        #expect(on.rethink && on.turn.modeChanged == true)
        #expect(mode.effortBeforeWords == .medium, "the next reply thinks from the start")
        #expect(!mode.wordsArrived("And tomorrow?", answeredAt: mode.effortBeforeWords).rethink)

        let off = mode.wordsArrived("Stop thinking", answeredAt: .medium)
        #expect(!off.rethink, "a reply that thought too much is not redone")
        #expect(off.turn.modeChanged == false)
        #expect(mode.effortBeforeWords == .low)
    }
}
