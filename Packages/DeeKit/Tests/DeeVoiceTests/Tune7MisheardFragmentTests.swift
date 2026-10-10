import Foundation
import Testing
@testable import DeeVoice

/// Tune 7 (T6-3, from the brain): live tune 6 (Traces/20261010-035320), four
/// backchannels said over her came back misheard and stopped her. In a hold, in a short
/// burst, one or two unclear words are a backchannel; stops and questions never are.
struct Tune7MisheardFragmentTests {
    @Test func misheardShortFragmentsInAHoldAreBackchannels() {
        // echo10 c05 "Keep going" → "Put going."; fan15 c05 → "She."; echo10 bc01 "Go on" →
        // "Grand."; fan15 bc02, the tail of "Mm-hm" → "Done."
        for t in ["Put going.", "She.", "Grand.", "Done."] {
            #expect(Backchannel.isBackchannel(t, inHold: true), "\(t)")
            #expect(!Backchannel.isBackchannel(t), "\(t): only over her voice, in a short burst")
        }
        for t in ["Stop.", "Wait.", "No.", "Hold on.", "Why?", "Who made", "Dee.", "D.", "I'm bored.", "5.", "Never mind."] {
            #expect(!Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
        #expect(Backchannel.isBackchannel("MMHN.", inHold: true) && Backchannel.isBackchannel("Mm.", inHold: true))
    }
}
