import Foundation

/// 12 s of 20 ms energy blocks on the 24 kHz capture clock — the wake ear's memory of
/// *when* there was speech (never audio; nothing here is ever sent).
///
/// Used for the 0.3 s local pause that triggers `finalize(through:)`, and for the
/// energy walk-back to the phrase onset when no final word timing is available.
public struct EnergyRing: Sendable {
    public struct Block: Sendable, Equatable {
        public var frame: Int64       // 24 kHz frame of the block start
        public var db: Double
    }

    public static let seconds: Double = 12
    public static let blockFrames16k = 320            // 20 ms at 16 kHz
    public static let blockFrames24k: Int64 = 480
    static let capacity = Int(seconds * 50)

    public private(set) var blocks: [Block] = []
    private var pending: [Int16] = []
    private var pendingFrame: Int64 = 0
    /// Slowly tracked noise floor (dBFS).
    public private(set) var floorDB: Double = -70
    private var voicedRun = 0
    private var silentRun = 0
    private var hadSpeech = false

    public init() {}

    /// Speech threshold: 10 dB over the floor and above −52 dBFS.
    public var thresholdDB: Double { max(floorDB + 10, -52) }

    public var lastFrame: Int64? { blocks.last.map { $0.frame + Self.blockFrames24k } }

    /// Feed 16 kHz samples; returns the 24 kHz frame where a ≥ 0.3 s pause after speech
    /// was just completed (once per pause), else nil.
    public mutating func append(_ pcm16k: [Int16], captureFrame24k: Int64) -> Int64? {
        if pending.isEmpty { pendingFrame = captureFrame24k }
        pending += pcm16k
        var pauseAt: Int64?
        while pending.count >= Self.blockFrames16k {
            let chunk = pending[0..<Self.blockFrames16k]
            var sum: Double = 0
            for s in chunk { let v = Double(s) / 32768; sum += v * v }
            let rms = (sum / Double(Self.blockFrames16k)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            let block = Block(frame: pendingFrame, db: db)
            blocks.append(block)
            if blocks.count > Self.capacity { blocks.removeFirst(blocks.count - Self.capacity) }
            // Floor: fast down, slow up.
            floorDB = db < floorDB ? floorDB + (db - floorDB) * 0.3 : floorDB + (db - floorDB) * 0.005
            if db > thresholdDB {
                voicedRun += 1
                silentRun = 0
                if voicedRun >= 3 { hadSpeech = true }
            } else {
                voicedRun = 0
                silentRun += 1
                if hadSpeech, silentRun == 15 {
                    hadSpeech = false
                    pauseAt = block.frame + Self.blockFrames24k
                }
            }
            pending.removeFirst(Self.blockFrames16k)
            pendingFrame += Self.blockFrames24k
        }
        return pauseAt
    }

    /// Frames of continuous quiet right before `frame` (0 if unknown / voiced).
    public func quietBefore(_ frame: Int64) -> Int64 {
        guard let idx = blocks.lastIndex(where: { $0.frame + Self.blockFrames24k <= frame }) else { return 0 }
        let th = thresholdDB
        var n: Int64 = 0
        var i = idx
        while i >= 0, blocks[i].db <= th { n += Self.blockFrames24k; i -= 1 }
        return n
    }

    /// The start of the speech burst ending at or before `end`: walk back over voiced
    /// blocks, bridging gaps < 0.25 s, never earlier than `notBefore`.
    public func onset(endingAt end: Int64, notBefore: Int64) -> Int64? {
        guard let lastIdx = blocks.lastIndex(where: { $0.frame < end }) else { return nil }
        let th = thresholdDB
        // Find the last voiced block at or before end.
        var i = lastIdx
        while i >= 0, blocks[i].db <= th { i -= 1 }
        guard i >= 0 else { return nil }
        var onset = blocks[i].frame
        var gap = 0
        var j = i - 1
        while j >= 0, blocks[j].frame >= notBefore {
            if blocks[j].db > th {
                onset = blocks[j].frame
                gap = 0
            } else {
                gap += 1
                if gap >= 13 { break }
            }
            j -= 1
        }
        return max(onset, notBefore)
    }
}
