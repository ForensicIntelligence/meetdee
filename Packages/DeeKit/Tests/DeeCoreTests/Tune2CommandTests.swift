import Testing
@testable import DeeCore

/// Tune 2 (tune1-live.md §F-DNA): stop requests with a lead-in or a "for a second" are
/// the stop command while Dee talks, never conversation for the model to take offence at.
struct Tune2CommandTests {
    @Test(arguments: ["Wait, stop talking for a second.", "Hold on, be quiet for a sec.", "Can you stop talking for a second?",
                      "Sorry, stop.", "Dee, could you be quiet for a moment please?", "hang on, shh"])
    func politeStopIsTheStopCommandWhileSheTalks(_ text: String) {
        #expect(SpokenCommand.match(text, deeIsTalking: true) == .stop, "\(text) → \(SpokenCommand.core(of: text))")
        #expect(SpokenCommand.match(text, deeIsTalking: false) == nil, "to a silent Dee it is conversation")
    }

    @Test(arguments: ["Wait.", "Hold on.", "hold on, hold on", "Don't stop. Keep going.", "Keep going, I'm listening.",
                      "mm-hm", "go on", "wait for me", "wait, what did you say?", "hold on, I need to think"])
    func backchannelsAndHoldsAreNotCommands(_ text: String) {
        #expect(SpokenCommand.match(text, deeIsTalking: true) == nil, "\(text) → \(SpokenCommand.core(of: text))")
    }
}
