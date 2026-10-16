import DeeCore
import Foundation
import Testing
@testable import DeeSelf

/// v0.6 (providers-wake-onboarding §2): the cascaded chat layout splits a real rendered
/// DNA by section number — the stable part (1, 2, 4, 5, 6, 9) stays byte-identical
/// across turns so a LAN server's prompt cache keeps it.
@Suite struct DNASplitSelfTests {
    @Test(arguments: DNAKit.all.map(\.name))
    func realDNASplitsBySection(_ name: String) throws {
        let a = try #require(DNAKit.all.first { $0.name == name })
        let text = DNAPrompt.render(DNAAssembler.assemble(a.inputs)).text
        let split = DNASplit(text)
        #expect(split.volatile.hasPrefix("DEE DNA "), "\(name)")
        #expect(split.stable.hasPrefix("1 IDENTITY"), "\(name)")
        for heading in ["2 TEMPERAMENT", "4 TOWARD THIS PERSON", "6 WHO YOU ARE", "9 HOW TO RESPOND"] {
            #expect(split.stable.contains("\n" + heading), "\(name): \(heading)")
        }
        for heading in ["3 FEELINGS NOW", "7 RIGHT NOW", "8 THIS TURN"] {
            #expect(split.volatile.contains("\n" + heading), "\(name): \(heading)")
        }
        #expect(split.stable.utf8.count + split.volatile.utf8.count + 1 == text.utf8.count, "\(name): no line lost")
        let sections = DNASplit.sections(of: text)
        #expect(Set(sections.keys) == Set(0...9), "\(name): \(sections.keys.sorted())")
    }
}
