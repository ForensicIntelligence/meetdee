import Foundation
import Testing
@testable import DeeWake

@Suite struct WakeCorpusTests {
    @Test func gridReport() {
        guard ProcessInfo.processInfo.environment["DEE_WAKE_GRID"] != nil else { return }
        for kd in WakeCorpus.keyDistanceGrid {
            for r in WakeCorpus.letterRatioGrid {
                let rep = WakeCorpus.evaluate(.init(keyDistance: kd, letterRatio: r), recognitions: Fixtures.corpus, wordList: Fixtures.words10k)
                print("GRID kd \(kd) lr \(r) ok \(rep.qualifies) recall \(rep.recall.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }) audio \(rep.audioFalseHits.prefix(6)) text \(rep.textFalseHits.prefix(6)) (\(rep.audioFalseHits.count)/\(rep.textFalseHits.count))")
            }
        }
    }
}
