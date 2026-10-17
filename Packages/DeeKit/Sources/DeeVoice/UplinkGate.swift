import Foundation

/// The room's sound bed — what the microphone hears when neither the user nor
/// Dee is talking: a fan, a running tap, or a TV across the room.
///
/// A TV is *voice*: pitched, voice-band, with gaps like speech. A floor (a low
/// percentile) sits in those gaps, so "above the floor" counts the TV as the
/// user. What separates a near-end talker from a far TV is level: the user's
/// voice at the phone is well above the bed's *ceiling* (the level its loud
/// parts reach). `ceilingDB` is that ceiling, robust to the user's own speech:
///
/// - Frames come in only while Dee's voice is out of the room and the user's
///   voice is not (the caller leaves out frames its uplink gate is open for).
/// - They are cut into `slice`-long pieces; each full piece contributes the
///   `percentile` level of its frames (its ceiling).
/// - The bed's ceiling is the *second highest* slice ceiling of the last
///   `window`: a TV has quieter and louder seconds, and its ceiling is where its
///   loud ones go; one slice the user's voice crept into (the end of a word the
///   gate had already let go) can't lift it. `floorDB` is the median slice
///   floor (`floorPercentile`), the bed's quiet level.
/// - The first two slices are heard with nothing to tell the user's voice from
///   the bed yet (someone may be talking right away): they set a provisional
///   ceiling and are dropped once two slices heard with it are in.
public struct RoomBed: Sendable, Equatable {
    public static let window = 8.0
    public static let slice = 1.0
    public static let percentile = 0.95
    /// A slice counts once this much of it was heard (frames left out don't).
    static let minCoverage = 0.5
    static let maxSlices = 8
    static let floorPercentile = 0.15

    private var current: [Double] = []
    private var currentStart: Double?
    private var currentSpan = 0.0
    private var slices: [(end: Double, ceiling: Double, floor: Double, provisional: Bool)] = []
    /// The bed's ceiling (dBFS) once two slices were heard.
    public private(set) var ceilingDB: Double?
    /// The bed's quiet level (dBFS), with the ceiling.
    public private(set) var floorDB: Double?

    public init() {}

    public static func == (a: RoomBed, b: RoomBed) -> Bool {
        a.ceilingDB == b.ceilingDB && a.current == b.current && a.slices.map(\.ceiling) == b.slices.map(\.ceiling)
    }

    /// One frame of the bed (`dt` seconds ending at `t`).
    public mutating func add(_ db: Double, duration dt: Double, at t: Double) {
        guard db.isFinite, t.isFinite, dt > 0 else { return }
        if let start = currentStart, t - start > Self.slice + 1e-9 { close(at: t) }
        if currentStart == nil { currentStart = t - dt }
        current.append(db)
        currentSpan += dt
    }

    /// Time passes without frames (Dee talking, the user talking): a slice that
    /// is over is closed (or dropped when too little of it was heard).
    public mutating func advance(to t: Double) {
        if let start = currentStart, t - start > Self.slice + 1e-9 { close(at: t) }
        let before = slices.count
        slices.removeAll { t - $0.end > Self.window }
        if slices.count != before { recompute() }
    }

    /// A bed that changed (a tap turned off) is followed once its old slices left
    /// the window; with none left, the last ceiling stands.
    private mutating func recompute() {
        guard !slices.isEmpty, ceilingDB != nil || slices.count >= 2 else { return }
        let ceilings = slices.map(\.ceiling).sorted()
        ceilingDB = ceilings[max(0, ceilings.count - 2)]
        let floors = slices.map(\.floor).sorted()
        floorDB = floors[floors.count / 2]
    }

    private mutating func close(at t: Double) {
        defer {
            current.removeAll(keepingCapacity: true)
            currentStart = nil
            currentSpan = 0
        }
        guard currentSpan >= Self.slice * Self.minCoverage - 1e-9, !current.isEmpty else { return }
        let sorted = current.sorted()
        func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        slices.append((t, at(Self.percentile), at(Self.floorPercentile), ceilingDB == nil))
        if slices.contains(where: \.provisional), slices.filter({ !$0.provisional }).count >= 2 {
            slices.removeAll(where: \.provisional)
        }
        slices.removeAll { t - $0.end > Self.window }
        if slices.count > Self.maxSlices { slices.removeFirst(slices.count - Self.maxSlices) }
        recompute()
    }
}

/// Mic audio to the server only where it is near-end sound: what lies below
/// the room bed's ceiling (a TV across the room, a fan) is attenuated by
/// `closedGainDB` before it is sent, so the server's VAD and transcription
/// never merge a TV with the user's words, and a turn ends when the user stops
/// rather than when the TV pauses.
///
/// Decided per 10 ms block of the PCM16 actually sent (no delay is added): a
/// block at or above `barDB` opens the gate for itself and `hangover` after it,
/// so words, the gaps between them and soft word ends go through whole; the
/// gain ramps (`attack` / `release`) so nothing clicks. Without a bar (the bed
/// isn't known yet) everything goes through unchanged. Dee's echo louder than the
/// bar opens it like the user: barge-in and echo decisions see exactly what
/// they saw before; only the bed below the bar is quieter.
public struct UplinkGate: Sendable, Equatable {
    public static let blockFrames = 240                     // 10 ms at 24 kHz
    public static let hangover = 0.45
    public static let closedGainDB = -30.0
    static let attackFrames = 48.0                          // 2 ms
    static let releaseFrames = 1_200.0                      // 50 ms
    static let rate = 24_000.0

    /// The level (dBFS, 10 ms mean square) that opens the gate; nil: always open.
    public var barDB: Double?
    private var gain: Float = 1
    private var openUntil = Int64.min
    /// Frames sent attenuated / at full level (for notes and tests).
    public private(set) var closedFrames: Int64 = 0
    public private(set) var openFrames: Int64 = 0

    public init() {}

    /// The gate is open at capture frame `frame` (after the last block processed).
    public func isOpen(at frame: Int64) -> Bool { barDB == nil || frame < openUntil }

    /// Applies the gate to `samples` (Int16 LE PCM, 24 kHz) that start at capture
    /// frame `startFrame`, in place.
    public mutating func process(_ samples: inout [Int16], startFrame: Int64) {
        let closed = Float(pow(10, Self.closedGainDB / 20))
        let up = Float(1 / Self.attackFrames), down = Float(1 / Self.releaseFrames)
        let hold = Int64(Self.hangover * Self.rate)
        var i = 0
        while i < samples.count {
            let n = min(Self.blockFrames, samples.count - i)
            let blockStart = startFrame + Int64(i)
            var e = 0.0
            for k in i..<(i + n) { let v = Double(samples[k]) / 32_768; e += v * v }
            let db = Level.powerDB(e / Double(n))
            if let bar = barDB, db >= bar { openUntil = max(openUntil, blockStart + Int64(n) + hold) }
            let target: Float = barDB == nil || blockStart < openUntil ? 1 : closed
            if target == 1 { openFrames += Int64(n) } else { closedFrames += Int64(n) }
            for k in i..<(i + n) {
                if gain < target { gain = min(target, gain + up) } else if gain > target { gain = max(target, gain - down) }
                if gain < 1 {
                    let v = (Float(samples[k]) * gain).rounded()
                    samples[k] = Int16(max(-32_768, min(32_767, v)))
                }
            }
            i += n
        }
    }

    /// The same on a PCM16 `Data` chunk.
    public mutating func process(_ data: Data, startFrame: Int64) -> Data {
        guard barDB != nil || gain < 1 else { return data }
        var samples = PCM16.samples(data)
        process(&samples, startFrame: startFrame)
        return samples.withUnsafeBytes { Data($0) }
    }
}
