import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Green eyes should be earned over days, not by a burst of thanks in a minute.
@Test func burstOfThanksDoesNotTurnEyesGreen() async throws {
    let mind = try Mind(databaseURL: nil, now: Date(timeIntervalSince1970: 0))
    var t = Date(timeIntervalSince1970: 0)
    let lines = ["Thank you so much!", "You're amazing, thanks!", "Thanks Dee, you're the best!", "I love you, thank you!",
                 "Great job, thank you!", "So clever, thanks!", "Thank you, buddy!", "You're brilliant, thanks!",
                 "Thanks a lot, cutie!", "Thank you, you're adorable!"]
    var peak = -1.0
    for line in lines {
        t += 5
        peak = max(peak, await mind.hear(line, at: t).snapshot.regard)
    }
    #expect(peak < 0.35, "a 50-second burst peaked at regard \(peak)")
    #expect(peak > 0.1, "but it should still visibly warm Dee (peak \(peak))")
}
