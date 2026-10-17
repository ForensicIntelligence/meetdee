import Foundation

// 0.6 wake suite (contract docs/contracts-0.6/providers-wake-onboarding.md §6). Pure:
// the plan (phrases, fixtures, beds, trials), the records the runner fills, the gates
// and the report (`Reports/<run>/wake.{json,md}`). The wake phrase is heard ONLY on the
// device (W1): the on-device suite feeds fixture audio through `DeeWake.OnDeviceWakeEar`
// with no network at all; the live suite runs whole scenarios dormant → wake → window.

/// How a harness run treats the wake phrase (`--wake`, required on `run`).
public enum WakeMode: String, Codable, Sendable, CaseIterable {
    /// The 28 tune2 scenarios' baseline: Dee is awake for the whole run (never DORMANT),
    /// exactly today's behaviour. Asserted: a run that ever goes dormant fails `wake_mode`.
    case alwaysOpen = "always-open"
    /// Dee starts DORMANT; only the on-device wake phrase (or a tap) opens a window.
    case phrase
}

/// A scenario that runs in `--wake phrase` (the wake subset of tune2).
public struct WakeSetup: Codable, Sendable, Equatable {
    /// The wake phrase (default "Hey Dee").
    public var phrase: String?
    public init(phrase: String? = nil) { self.phrase = phrase }
    public var text: String { phrase ?? WakeSuite.defaultPhrase }
}

public enum WakeSuite {
    public static let defaultPhrase = "Hey Dee"
    public static let customPhrases = ["Computer", "Hey Robo", "Okay Pixel"]
    public static var phrases: [String] { [defaultPhrase] + customPhrases }

    /// Accept targets (contract §6): "Hey Dee" ≥ 95 %, each custom phrase ≥ 90 %.
    public static let acceptDefault = 0.95
    public static let acceptCustom = 0.90
    /// A window opened on a TV bed (no accepted turn) closes 60 s ± 2 after the wake.
    public static let windowClose = 60.0
    public static let windowTolerance = 2.0
    /// Seconds of each bed the false-wake exposure plays per phrase.
    public static let exposureSeconds = 600.0

    public struct Line: Sendable, Equatable { public var voice: String; public var text: String }

    /// The `tvlong` bed (original lines; staggered like `Beds.tv`).
    public static let tvLines: [Line] = [
        .init(voice: "Daniel", text: "Good evening. Our top story tonight: the river reached its highest level in ten years after three days of heavy rain."),
        .init(voice: "Samantha", text: "When we come back, a family bakery that has been making the same rye bread since nineteen fifty two."),
        .init(voice: "Fred", text: "And in sports, the visitors scored twice in the final minutes to steal a win on the road."),
        .init(voice: "Kathy", text: "Expect fog in the valleys early tomorrow, clearing by noon, with a high of sixty one."),
        .init(voice: "Moira", text: "Hey there, folks, are your floors looking dull? Try our new mop, it glides like a dream."),
        .init(voice: "Karen", text: "The detective looked at the window again. Someone had been here, and they had left in a hurry."),
        .init(voice: "Daniel", text: "Traffic is heavy on the east side tonight, with delays near the stadium exit."),
        .init(voice: "Samantha", text: "Today on the show we are making a lemon cake that is light, simple and ready in an hour."),
        .init(voice: "Fred", text: "He is the first player in the league to reach two hundred goals before turning thirty."),
        .init(voice: "Kathy", text: "Lady luck was on her side when she found the winning ticket in an old coat pocket."),
        .init(voice: "Moira", text: "Had enough of slow internet? Call today and ask about our holiday deal."),
        .init(voice: "Karen", text: "The museum will stay open late on Fridays this summer, with music in the garden."),
    ]

    /// The `radio` bed: talk radio, one voice at a time (original lines).
    public static let radioLines: [Line] = [
        .init(voice: "Daniel", text: "You're listening to the afternoon show, and we have a full hour of your calls ahead."),
        .init(voice: "Samantha", text: "Our first caller says her tomatoes split every August. What is going on there?"),
        .init(voice: "Karen", text: "Well, it is usually the watering. Too much after a dry spell and the skins just give up."),
        .init(voice: "Moira", text: "Hi, thanks for taking my call. I have a question about my old car, it makes a noise when it is cold."),
        .init(voice: "Fred", text: "A ticking noise or more of a grinding noise? Those are two very different stories."),
        .init(voice: "Kathy", text: "Coming up at the half hour, the headlines, the weather, and a look at the weekend."),
        .init(voice: "Reed (English (US))", text: "I read a book last week about the deep sea, and honestly it changed how I think about the ocean."),
        .init(voice: "Flo (English (US))", text: "They say the hardest part of a long trip is the first ten minutes out of the driveway."),
        .init(voice: "Daniel", text: "The city wants to hear from you about the new bike lanes downtown. Love them or hate them?"),
        .init(voice: "Samantha", text: "My neighbor has a dog that sings when the ice cream truck goes by. It is the best part of my day."),
        .init(voice: "Karen", text: "Let's go to the phones. Hello, you're on the air, what's on your mind today?"),
        .init(voice: "Moira", text: "Hey, I just wanted to say the soup recipe from last week was a hit with my kids."),
        .init(voice: "Fred", text: "The deadline for the photo contest is Sunday at midnight, so send in those sunsets."),
        .init(voice: "Kathy", text: "He is coming back to town next month for one night only, and tickets are already going fast."),
        .init(voice: "Reed (English (US))", text: "If you missed the start of the show, we have been talking about the best way to fold a fitted sheet."),
        .init(voice: "Flo (English (US))", text: "That's all the time we have for this segment. Stay with us, more music after the break."),
    ]

    /// Mic conditions the trials are mixed under (beds at 15 dB SNR, like tune2).
    public struct Condition: Sendable, Equatable {
        public var id: String
        public var noise: Scenario.Noise?
    }
    public static let conditions: [Condition] = [
        .init(id: "clean", noise: nil),
        .init(id: "fan15", noise: .init(bed: "fan", snrDb: 15)),
        .init(id: "kitchen15", noise: .init(bed: "kitchen", snrDb: 15)),
        .init(id: "tv15", noise: .init(bed: "tv", snrDb: 15)),
    ]
    /// The false-wake exposures: each bed alone for `exposureSeconds` per phrase.
    public static let exposureBeds: [Scenario.Noise] = [
        .init(bed: "fan", snrDb: 15), .init(bed: "kitchen", snrDb: 15),
        .init(bed: "tvlong", snrDb: 15), .init(bed: "radio", snrDb: 10),
    ]

    public enum Expect: String, Codable, Sendable { case accept, reject }

    /// One wake-phrase decision: a fixture under a condition, for a phrase.
    public struct Trial: Codable, Sendable, Equatable {
        public var id: String
        public var phrase: String
        public var fixture: String
        public var condition: String
        public var noise: Scenario.Noise?
        public var expect: Expect
        /// The question follows the phrase in one breath (it must be answered, live).
        public var oneBreath: Bool
        /// Counts in a gate (else information).
        public var gated: Bool
        public init(id: String, phrase: String, fixture: String, condition: String, noise: Scenario.Noise?,
                    expect: Expect, oneBreath: Bool, gated: Bool) {
            self.id = id; self.phrase = phrase; self.fixture = fixture; self.condition = condition; self.noise = noise
            self.expect = expect; self.oneBreath = oneBreath; self.gated = gated
        }
    }

    /// Fixtures that say `phrase` (alone, in one breath, or with a pause after it).
    public static func positives(for phrase: String) -> [String] {
        let ids = FixtureCatalog.all.filter { $0.category == .wake }.map(\.id)
        switch phrase {
        case defaultPhrase: return ids.filter { $0.hasPrefix("wd") || $0.hasPrefix("wq") || $0.hasPrefix("wp") }
        case "Computer": return ids.filter { $0.hasPrefix("cc") || $0.hasPrefix("cq") }
        case "Hey Robo": return ids.filter { $0.hasPrefix("hr") }
        case "Okay Pixel": return ids.filter { $0.hasPrefix("op") }
        default: return []
        }
    }

    /// Fixtures that must not wake `phrase`: every unaddressed line, plus every OTHER
    /// phrase's positives (saying "Computer" never wakes a "Hey Dee" Dee). Unaddressed
    /// lines that contain the phrase itself are left out (un07 "computer" for Computer).
    public static func negatives(for phrase: String) -> [String] {
        let words = Set(phrase.lowercased().split(separator: " ").map(String.init))
        let unaddressed = FixtureCatalog.all.filter { $0.category == .unaddressed }.filter { spec in
            let w = Set(spec.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            return !(words.count == 1 && w.isSuperset(of: words))
        }.map(\.id)
        let others = phrases.filter { $0 != phrase }.flatMap { positives(for: $0).filter { !$0.hasPrefix("wq") && !$0.hasPrefix("wp") } }
        return unaddressed + others
    }

    /// Positives the gates count: the phrase alone + one breath (all conditions).
    /// Negatives the gate counts: unaddressed speech for "Hey Dee" (contract: gate 0);
    /// custom phrases' negatives and cross-phrase lines are information.
    public static func trials() -> [Trial] {
        var out: [Trial] = []
        for phrase in phrases {
            let slug = phrase.lowercased().replacingOccurrences(of: " ", with: "")
            for c in conditions {
                for f in positives(for: phrase) {
                    out.append(.init(id: "\(slug)-\(f)-\(c.id)", phrase: phrase, fixture: f, condition: c.id, noise: c.noise,
                                     expect: .accept, oneBreath: f.hasPrefix("wq") || f.hasPrefix("cq") || f.hasPrefix("hrq") || f.hasPrefix("opq"),
                                     gated: true))
                }
                for f in negatives(for: phrase) {
                    let unaddressed = FixtureCatalog.spec(f)?.category == .unaddressed
                    out.append(.init(id: "\(slug)-\(f)-\(c.id)", phrase: phrase, fixture: f, condition: c.id, noise: c.noise,
                                     expect: .reject, oneBreath: false, gated: phrase == defaultPhrase && unaddressed))
                }
            }
        }
        return out
    }

    /// The live wake subset of tune2 (`--wake phrase`), scored with the tune2 gates:
    /// one-breath question, a pause after the phrase, a follow-up after the window
    /// closed (65 s quiet) and a re-wake, a backchannel in the first window turn; plus
    /// the TV-bed window (wake, then only TV: closes 60 s ± 2) and a close command.
    public static func liveScenarios() -> [Scenario] {
        typealias Step = Scenario.Step
        let setup = WakeSetup()
        func s(_ name: String, _ d: String, noise: Scenario.Noise? = nil, echo: EchoConfig? = nil, aecOff: Bool? = nil,
               _ steps: [Step]) -> Scenario {
            var sc = Scenario(name: name, description: d, noise: noise, echo: echo, leadIn: 3.0, steps: steps,
                              family: "wake", aecOff: aecOff)
            sc.wake = setup
            return sc
        }
        return [
            s("wk-onebreath-clean", "\"Hey Dee, what time is it?\" in one breath: answered.", [
                Step(say: "wq01"), Step(silence: 2), Step(say: "q02"),
            ]),
            s("wk-onebreath-fan15", "One-breath questions on a fan bed.", noise: .init(bed: "fan", snrDb: 15), [
                Step(say: "wq03"), Step(say: "q05"),
            ]),
            s("wk-pause-kitchen15", "\"Hey Dee.\" … pause … the question.", noise: .init(bed: "kitchen", snrDb: 15), [
                Step(say: "wp01"), Step(say: "q06"),
            ]),
            s("wk-rewake-clean", "Answered, 65 s quiet (the window closes), then a re-wake and a follow-up.", [
                Step(say: "wq04"), Step(silence: 65, gapAfter: 1), Step(say: "wd07", expect: .any), Step(say: "q01"),
            ]),
            s("wk-backchannel-echo20", "A backchannel in the first window turn: Dee keeps talking.",
              echo: EchoConfig(gainDB: -20, delayMs: 80), aecOff: true, [
                Step(say: "wd11", expect: .any), Step(say: "l05", bargeIn: .init(say: "c05", atMs: 1500, backchannel: true)),
            ]),
            s("wk-tv-window", "Woken, then only the TV: the window closes 60 s ± 2 after the wake, nothing answered.",
              noise: .init(bed: "tvlong", snrDb: 15), [
                Step(say: "wd02", expect: .any), Step(silence: 75),
            ]),
            s("wk-close-command", "\"Okay, go to sleep.\" closes the window at once; a later question is not answered until a wake.", [
                Step(say: "wq03"), Step(say: "wc01", expect: .any), Step(silence: 3), Step(say: "q04", expect: .noReply),
                Step(say: "wd09", expect: .any), Step(say: "q04"),
            ]),
        ]
    }
}

// MARK: - Records

public struct WakeTrialResult: Codable, Sendable, Equatable {
    public var trial: WakeSuite.Trial
    /// The ear fired for this phrase while the trial played (or within the grace after it).
    public var hit: Bool
    public var tier: String?
    public var matched: String?
    /// The hit came from a final result (else a volatile one).
    public var fromFinal: Bool?
    /// Seconds into the trial's audio: the phrase's true end of speech, the hit, the
    /// first "perking up" candidate cue.
    public var phraseEnd: Double
    public var hitAt: Double?
    public var candidateAt: Double?
    /// Estimated onset − true onset (s), from the hit's onset frame.
    public var onsetError: Double?
    public init(trial: WakeSuite.Trial, hit: Bool, phraseEnd: Double) { self.trial = trial; self.hit = hit; self.phraseEnd = phraseEnd }
    public var correct: Bool { hit == (trial.expect == .accept) }
    public var latency: Double? { hitAt.map { $0 - phraseEnd } }
}

public struct WakeExposureResult: Codable, Sendable, Equatable {
    public var phrase: String
    public var bed: String
    public var snrDb: Double
    public var seconds: Double
    /// Seconds into the exposure of each false wake, and what matched.
    public var falseWakes: [Double]
    public var matched: [String]
    public init(phrase: String, bed: String, snrDb: Double, seconds: Double, falseWakes: [Double] = [], matched: [String] = []) {
        self.phrase = phrase; self.bed = bed; self.snrDb = snrDb; self.seconds = seconds
        self.falseWakes = falseWakes; self.matched = matched
    }
}

/// One live wake scenario's wake-specific measurements (the tune2 gates score the rest).
public struct WakeLiveResult: Codable, Sendable, Equatable {
    public struct Wake: Codable, Sendable, Equatable {
        public var fixture: String
        /// Harness-clock seconds: phrase end of speech; first candidate cue; the hit;
        /// the window's `eyesWake`; the first socket opened; Dee's first audio after it.
        public var phraseEnd: Double
        public var candidateAt: Double?
        public var hitAt: Double?
        public var eyesAt: Double?
        public var connectAt: Double?
        public var firstAudioAt: Double?
        /// One breath: the question in the same fixture got a reply.
        public var oneBreathAnswered: Bool?
        public init(fixture: String, phraseEnd: Double) { self.fixture = fixture; self.phraseEnd = phraseEnd }
    }
    public var scenario: String
    public var mode: String
    public var wakes: [Wake] = []
    /// Window open → dormant, harness clock.
    public var windows: [WakeSuite.Interval] = []
    /// The close a scenario expects to measure (the TV-bed scenario): wake → close.
    public var tvWindowSeconds: Double?
    /// User utterances answered while Dee was DORMANT (after a close): must be none.
    public var dormantAnswered: [String] = []
    public init(scenario: String, mode: String) { self.scenario = scenario; self.mode = mode }
}

/// W1/W2/W3 per provider mode: what left the phone before the local hit.
public struct WakeInvariantResult: Codable, Sendable, Equatable {
    public var mode: String
    /// Recorded transport calls (HTTP + streams + sockets) before the hit, and by kind.
    public var requestsBeforeHit: Int
    public var socketsBeforeHit: Int
    public var mintsBeforeHit: Int
    /// Mic audio bytes sent (input_audio_buffer.append payload) before the hit.
    public var audioBytesBeforeHit: Int
    /// The wake fired with the network failing every call.
    public var hitWithNetworkDown: Bool
    /// `eyesWake` came before the first connect attempt.
    public var eyesBeforeConnect: Bool
    /// A server / LAN transcript saying the phrase woke Dee (must be false).
    public var serverTranscriptWoke: Bool
    /// Hosts contacted after the wake (W3: no crossover).
    public var hostsAfterWake: [String]
    public var crossover: [String]
    public init(mode: String, requestsBeforeHit: Int, socketsBeforeHit: Int, mintsBeforeHit: Int, audioBytesBeforeHit: Int,
                hitWithNetworkDown: Bool, eyesBeforeConnect: Bool, serverTranscriptWoke: Bool, hostsAfterWake: [String] = [],
                crossover: [String] = []) {
        self.mode = mode; self.requestsBeforeHit = requestsBeforeHit; self.socketsBeforeHit = socketsBeforeHit
        self.mintsBeforeHit = mintsBeforeHit; self.audioBytesBeforeHit = audioBytesBeforeHit
        self.hitWithNetworkDown = hitWithNetworkDown; self.eyesBeforeConnect = eyesBeforeConnect
        self.serverTranscriptWoke = serverTranscriptWoke; self.hostsAfterWake = hostsAfterWake; self.crossover = crossover
    }
    public var ok: Bool {
        requestsBeforeHit == 0 && socketsBeforeHit == 0 && mintsBeforeHit == 0 && audioBytesBeforeHit == 0
            && hitWithNetworkDown && eyesBeforeConnect && !serverTranscriptWoke && crossover.isEmpty
    }
}

public extension WakeSuite {
    struct Interval: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double?
        public init(start: Double, end: Double?) { self.start = start; self.end = end }
        public var length: Double? { end.map { $0 - start } }
    }
}

// MARK: - Report + gates

public struct WakeReport: Codable, Sendable {
    public var tool = "voice-harness wake"
    public var runID: String
    public var started: String
    public var finished: String
    /// What heard the phrase ("on-device SpeechAnalyzer DictationTranscriber en-US" …).
    public var engine: String
    /// `fast` (fed as fast as the analyzer takes it) or `realtime` (paced like a mic).
    public var pace: String
    public var thresholds: String?
    public var trials: [WakeTrialResult] = []
    public var exposures: [WakeExposureResult] = []
    public var live: [WakeLiveResult] = []
    public var invariants: [WakeInvariantResult] = []
    /// The tune2 first-audio p50 / p90 with a warm socket, for comparison (information).
    public var warmFirstAudio: [Double]?
    public var gates: [Gate] = []
    public var notes: [String] = []

    public init(runID: String, started: String, finished: String, engine: String, pace: String) {
        self.runID = runID; self.started = started; self.finished = finished; self.engine = engine; self.pace = pace
    }

    public var failed: Bool { Gates.anyFailed(gates) }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try e.encode(self)
    }

    public static func load(_ data: Data) throws -> WakeReport {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(WakeReport.self, from: data)
    }
}

public enum WakeGates {
    static func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : String(format: "%.1f%% (%d/%d)", Double(n) / Double(d) * 100, n, d) }
    static func s(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }

    public static func evaluate(_ r: WakeReport) -> [Gate] {
        var g: [Gate] = []
        let gated = r.trials.filter(\.trial.gated)

        // 1. True accepts, "Hey Dee".
        let def = gated.filter { $0.trial.phrase == WakeSuite.defaultPhrase && $0.trial.expect == .accept }
        let defHits = def.filter(\.hit).count
        let misses = def.filter { !$0.hit }.map { "\($0.trial.fixture)@\($0.trial.condition)" }
        g.append(Gate(id: "wake_accept", metric: "\"Hey Dee\" heard on the device (alone + one breath, clean/fan/kitchen/TV)",
                      target: "≥ \(Int(WakeSuite.acceptDefault * 100))%", value: pct(defHits, def.count), n: def.count,
                      status: def.isEmpty ? .skip : (Double(defHits) >= WakeSuite.acceptDefault * Double(def.count) ? .pass : .fail),
                      note: misses.isEmpty ? nil : "missed: " + misses.prefix(10).joined(separator: ", ")))

        // 2. Custom phrases, each.
        var parts: [String] = [], ok = true, n = 0
        for p in WakeSuite.customPhrases {
            let t = gated.filter { $0.trial.phrase == p && $0.trial.expect == .accept }
            guard !t.isEmpty else { continue }
            let h = t.filter(\.hit).count
            n += t.count
            parts.append("\(p) \(pct(h, t.count))")
            if Double(h) < WakeSuite.acceptCustom * Double(t.count) { ok = false }
        }
        g.append(Gate(id: "wake_accept_custom", metric: "Custom phrases heard (\"Computer\", \"Hey Robo\", \"Okay Pixel\")",
                      target: "≥ \(Int(WakeSuite.acceptCustom * 100))% each", value: parts.isEmpty ? "not run" : parts.joined(separator: "; "),
                      n: n, status: parts.isEmpty ? .skip : (ok ? .pass : .fail)))

        // 3. False wakes: beds (every phrase) + unaddressed speech ("Hey Dee").
        let negs = gated.filter { $0.trial.expect == .reject }
        let negHits = negs.filter(\.hit)
        let bedWakes = r.exposures.reduce(0) { $0 + $1.falseWakes.count }
        let bedSeconds = r.exposures.reduce(0.0) { $0 + $1.seconds }
        let perHour = bedSeconds > 0 ? Double(bedWakes) / bedSeconds * 3600 : nil
        let falseList = r.exposures.filter { !$0.falseWakes.isEmpty }.map { "\($0.phrase)/\($0.bed): \($0.falseWakes.count) (\($0.matched.prefix(3).joined(separator: ", ")))" }
            + negHits.map { "\($0.trial.fixture)@\($0.trial.condition) “\($0.matched ?? "?")”" }
        let ran = !negs.isEmpty || !r.exposures.isEmpty
        g.append(Gate(id: "wake_false", metric: "False wakes: fan / kitchen / TV / talk-radio beds (every phrase) + unaddressed \"Dee\" speech",
                      target: "0", value: "\(bedWakes) in \(String(format: "%.0f", bedSeconds / 60)) min of beds (\(s(perHour))/h); unaddressed \(negHits.count)/\(negs.count)",
                      n: negs.count + r.exposures.count, status: !ran ? .skip : (bedWakes == 0 && negHits.isEmpty ? .pass : .fail),
                      note: falseList.isEmpty ? nil : falseList.prefix(8).joined(separator: "; ")))

        // Information: custom-phrase near misses and cross-phrase lines.
        let info = r.trials.filter { !$0.trial.gated && $0.trial.expect == .reject }
        let infoHits = info.filter(\.hit)
        if !info.isEmpty {
            g.append(Gate(id: "wake_near_miss", metric: "Near misses and other phrases (information)", target: "–",
                          value: "\(infoHits.count)/\(info.count) woke", n: info.count, status: .skip,
                          note: infoHits.isEmpty ? nil : infoHits.prefix(8).map { "\($0.trial.phrase): \($0.trial.fixture)@\($0.trial.condition) “\($0.matched ?? "?")”" }.joined(separator: "; ")))
        }

        // 4. Latency (information): phrase end → hit (volatile / final), → candidate cue,
        // and live: → eyes, → first audio, next to warm-socket tune2 first audio.
        let hits = r.trials.filter { $0.hit && $0.trial.expect == .accept }
        let vol = hits.filter { $0.fromFinal == false }.compactMap(\.latency)
        let fin = hits.filter { $0.fromFinal == true }.compactMap(\.latency)
        let cand = hits.compactMap { t in t.candidateAt.map { $0 - t.phraseEnd } }
        let wakes = r.live.flatMap(\.wakes)
        let eyes = wakes.compactMap { w in w.eyesAt.map { $0 - w.phraseEnd } }
        let audio = wakes.compactMap { w in w.firstAudioAt.map { $0 - w.phraseEnd } }
        func pp(_ x: [Double]) -> String { x.isEmpty ? "–" : "p50 \(s(Stats.percentile(x, 0.5))) / p90 \(s(Stats.percentile(x, 0.9))) s (n=\(x.count))" }
        g.append(Gate(id: "wake_latency", metric: "Phrase end → hit (volatile | final), → candidate cue, → eyes, → first audio (information)",
                      target: "–", value: "hit volatile \(pp(vol)); final \(pp(fin)); cue \(pp(cand)); eyes \(pp(eyes)); first audio \(pp(audio))",
                      n: hits.count + wakes.count, status: .skip,
                      note: r.warmFirstAudio.map { "warm-socket tune2 first audio: \(pp($0))" }))

        // 5. One breath answered (live) — and accepted (on device).
        let ob = wakes.compactMap(\.oneBreathAnswered)
        let obTrials = r.trials.filter { $0.trial.oneBreath && $0.trial.gated }
        let obHit = obTrials.filter(\.hit).count
        let obOK = ob.allSatisfy { $0 } && Double(obHit) >= WakeSuite.acceptCustom * Double(max(1, obTrials.count))
        g.append(Gate(id: "wake_one_breath", metric: "\"Hey Dee, what time is it?\" in one breath: heard, and the question answered (live)",
                      target: "every one answered", value: "answered \(ob.filter { $0 }.count)/\(ob.count); heard \(pct(obHit, obTrials.count))",
                      n: ob.count + obTrials.count, status: ob.isEmpty && obTrials.isEmpty ? .skip : (obOK ? .pass : .fail)))

        // 6. Window after a TV-bed wake.
        let tv = r.live.compactMap(\.tvWindowSeconds)
        let tvOK = tv.allSatisfy { abs($0 - WakeSuite.windowClose) <= WakeSuite.windowTolerance }
        g.append(Gate(id: "wake_window", metric: "Window after a wake with only the TV on: closes after", target: "60 s ± 2",
                      value: tv.isEmpty ? "not run" : tv.map { String(format: "%.1f s", $0) }.joined(separator: ", "), n: tv.count,
                      status: tv.isEmpty ? .skip : (tvOK ? .pass : .fail)))

        // 6b. DORMANT is deaf to everything but the phrase: nothing said after a close is answered.
        let deaf = r.live.flatMap { l in l.dormantAnswered.map { "\(l.scenario):\($0)" } }
        let liveRan = !r.live.isEmpty
        g.append(Gate(id: "wake_dormant", metric: "Speech while DORMANT (after \"go to sleep\" / the window closed) is never answered",
                      target: "0", value: liveRan ? "\(deaf.count)" : "not run", n: r.live.count,
                      status: liveRan ? (deaf.isEmpty ? .pass : .fail) : .skip, note: deaf.isEmpty ? nil : deaf.joined(separator: ", ")))

        // 7. W1/W2/W3 per mode.
        let bad = r.invariants.filter { !$0.ok }
        g.append(Gate(id: "wake_local", metric: "W1/W2/W3 per mode: wake heard and reacted to on the phone only; 0 requests / sockets / mints / audio bytes while DORMANT; no crossover",
                      target: "all modes", value: r.invariants.isEmpty ? "not run" : r.invariants.map { "\($0.mode) \($0.ok ? "ok" : "FAIL")" }.joined(separator: ", "),
                      n: r.invariants.count, status: r.invariants.isEmpty ? .skip : (bad.isEmpty ? .pass : .fail),
                      note: bad.isEmpty ? nil : bad.map { i in
                          "\(i.mode): before hit \(i.requestsBeforeHit) req / \(i.socketsBeforeHit) sockets / \(i.mintsBeforeHit) mints / \(i.audioBytesBeforeHit) B; hit with network down \(i.hitWithNetworkDown); eyes first \(i.eyesBeforeConnect); server transcript woke \(i.serverTranscriptWoke); crossover \(i.crossover)"
                      }.joined(separator: "; ")))
        return g
    }

    public static func markdown(_ r: WakeReport) -> String {
        var md = "# Dee wake suite — \(r.runID)\n\n"
        md += "- Engine: \(r.engine) · pace \(r.pace)\(r.thresholds.map { " · thresholds \($0)" } ?? "")\n"
        md += "- Started \(r.started) · finished \(r.finished)\n"
        md += "- Verdict: **\(r.failed ? "FAIL" : "PASS")**\n\n"
        md += "| Gate | Target | Value | n | Status |\n|---|---|---|---|---|\n"
        for x in r.gates {
            md += "| \(x.metric) | \(x.target) | \(x.value.replacingOccurrences(of: "|", with: "\\|")) | \(x.n) | **\(x.status.rawValue)**\(x.note.map { " — \($0.replacingOccurrences(of: "|", with: "\\|"))" } ?? "") |\n"
        }
        if !r.trials.isEmpty {
            md += "\n## Accept rate by phrase and condition\n\n| Phrase | Condition | Accepted | Rejected correctly |\n|---|---|---|---|\n"
            for p in WakeSuite.phrases {
                for c in WakeSuite.conditions.map(\.id) {
                    let t = r.trials.filter { $0.trial.phrase == p && $0.trial.condition == c }
                    guard !t.isEmpty else { continue }
                    let pos = t.filter { $0.trial.expect == .accept }, neg = t.filter { $0.trial.expect == .reject }
                    md += "| \(p) | \(c) | \(pct(pos.filter(\.hit).count, pos.count)) | \(pct(neg.filter { !$0.hit }.count, neg.count)) |\n"
                }
            }
            let wrong = r.trials.filter { !$0.correct }
            if !wrong.isEmpty {
                md += "\n### Wrong decisions\n\n| Phrase | Fixture | Condition | Expected | Matched | Tier |\n|---|---|---|---|---|---|\n"
                for t in wrong.prefix(80) {
                    md += "| \(t.trial.phrase) | \(t.trial.fixture) | \(t.trial.condition) | \(t.trial.expect.rawValue) | \(t.matched ?? "–") | \(t.tier ?? "–") |\n"
                }
            }
        }
        if !r.exposures.isEmpty {
            md += "\n## False-wake exposures\n\n| Phrase | Bed | SNR | Minutes | False wakes | Matched |\n|---|---|---|---|---|---|\n"
            for e in r.exposures {
                md += "| \(e.phrase) | \(e.bed) | \(Int(e.snrDb)) dB | \(String(format: "%.0f", e.seconds / 60)) | \(e.falseWakes.count) | \(e.matched.prefix(4).joined(separator: ", ")) |\n"
            }
        }
        if !r.live.isEmpty {
            md += "\n## Live wake scenarios\n\n| Scenario | Mode | Wake fixture | → cue | → hit | → eyes | → connect | → first audio | One breath answered |\n|---|---|---|---|---|---|---|---|---|\n"
            for l in r.live {
                for w in l.wakes {
                    func d(_ t: Double?) -> String { t.map { String(format: "%.2f s", $0 - w.phraseEnd) } ?? "–" }
                    md += "| \(l.scenario) | \(l.mode) | \(w.fixture) | \(d(w.candidateAt)) | \(d(w.hitAt)) | \(d(w.eyesAt)) | \(d(w.connectAt)) | \(d(w.firstAudioAt)) | \(w.oneBreathAnswered.map { $0 ? "yes" : "**no**" } ?? "–") |\n"
                }
                if let tv = l.tvWindowSeconds { md += "| \(l.scenario) | \(l.mode) | window (TV only) | | | | | closed after \(String(format: "%.1f", tv)) s | |\n" }
            }
        }
        if !r.invariants.isEmpty {
            md += "\n## Wake is local (W1/W2/W3)\n\n| Mode | Requests before hit | Sockets | Mints | Audio bytes | Hit with network down | Eyes before connect | Server transcript woke | Hosts after wake | Crossover |\n|---|---|---|---|---|---|---|---|---|---|\n"
            for i in r.invariants {
                md += "| \(i.mode) | \(i.requestsBeforeHit) | \(i.socketsBeforeHit) | \(i.mintsBeforeHit) | \(i.audioBytesBeforeHit) | \(i.hitWithNetworkDown) | \(i.eyesBeforeConnect) | \(i.serverTranscriptWoke) | \(i.hostsAfterWake.joined(separator: ", ")) | \(i.crossover.isEmpty ? "none" : i.crossover.joined(separator: ", ")) |\n"
            }
        }
        if !r.notes.isEmpty { md += "\n## Notes\n\n" + r.notes.map { "- \($0)\n" }.joined() }
        return md
    }
}

public extension WakeMode {
    /// Scenarios that can't run in this mode (asserted before a run starts): the tune2
    /// baseline only runs `always-open`; a wake scenario only runs `phrase`.
    func issues(_ scenarios: [Scenario]) -> [String] {
        scenarios.compactMap { s in
            switch self {
            case .alwaysOpen where s.wake != nil: "\(s.name) is a wake-phrase scenario: run it with --wake phrase"
            case .phrase where s.wake == nil: "\(s.name) is an always-open scenario (tune2 baseline): run it with --wake always-open"
            default: nil
            }
        }
    }
}

// MARK: - Live wake measurements from a run record (pure)

public enum WakeLive {
    static func isWakeFixture(_ id: String) -> Bool {
        FixtureCatalog.spec(id)?.category == .wake
    }

    /// The phrase's end in a wake fixture: the first voiced span's end when the phrase is
    /// followed by a pause (`wp…`, or a phrase alone), else the end of speech (one breath:
    /// latencies then read as answer latencies).
    static func phraseEnd(_ u: RunRecord.Utterance) -> Double {
        u.spans.count > 1 ? u.spans[0].end : u.endOfSpeech
    }

    public static func result(_ run: RunRecord, metrics: Metrics, mode: String) -> WakeLiveResult {
        var r = WakeLiveResult(scenario: run.scenario, mode: mode)
        let events = run.wakeEvents ?? []
        let eyes = events.filter { $0.text == "eyesWake" }.map(\.t)
        let off = events.filter { $0.text == "eyesListeningOff" }.map(\.t)
        let perk = events.filter { $0.text == "perkUp" }.map(\.t)
        let sockets = (run.transport ?? []).filter { $0.kind == "webSocket" }.map(\.t)
        let rows = metrics.utterances.filter { $0.scenario == run.scenario }
        for u in run.utterances where isWakeFixture(u.fixture) {
            var w = WakeLiveResult.Wake(fixture: u.fixture, phraseEnd: phraseEnd(u))
            let horizon = u.endOfSpeech + 8
            w.eyesAt = eyes.first { $0 >= u.onset && $0 <= horizon }
            w.hitAt = w.eyesAt
            w.candidateAt = perk.first { $0 >= u.onset && $0 <= (w.eyesAt ?? horizon) }
            if let e = w.eyesAt {
                w.connectAt = sockets.first { $0 >= e - 0.05 }
                w.firstAudioAt = run.playback.compactMap(\.started).filter { $0 > e }.min()
            }
            if u.fixture.hasPrefix("wq") || u.fixture.hasPrefix("cq") || u.fixture.hasPrefix("hrq") || u.fixture.hasPrefix("opq") {
                let row = rows.first { $0.index == u.index }
                w.oneBreathAnswered = row?.latency != nil && !(row?.dropped ?? true)
            }
            r.wakes.append(w)
        }
        for e in eyes {
            r.windows.append(.init(start: e, end: off.first { $0 > e }))
        }
        if run.scenario.hasSuffix("tv-window"), let first = r.windows.first { r.tvWindowSeconds = first.length }
        // Spoken to while DORMANT (expect noReply) and answered anyway.
        for u in run.utterances where u.expect == .noReply {
            if let row = rows.first(where: { $0.index == u.index }), row.replyItem != nil { r.dormantAnswered.append(u.fixture) }
        }
        return r
    }

    /// W1/W2/W3 from one phrase-mode run: what left the phone before the first local
    /// wake, and which hosts it contacted after (`allowedHosts`: the mode's hosts).
    public static func invariant(_ run: RunRecord, mode: String, allowedHosts: (String) -> Bool) -> WakeInvariantResult {
        let events = run.wakeEvents ?? []
        let firstEyes = events.first { $0.text == "eyesWake" }?.t ?? .infinity
        let calls = run.transport ?? []
        let before = calls.filter { $0.t < firstEyes }
        let after = calls.filter { $0.t >= firstEyes }
        let firstConnect = calls.first { $0.kind == "webSocket" || TransportTape_isMint($0) }?.t ?? .infinity
        let hosts = Array(Set(after.map(\.host))).sorted()
        return WakeInvariantResult(
            mode: mode, requestsBeforeHit: before.count, socketsBeforeHit: before.filter { $0.kind == "webSocket" }.count,
            mintsBeforeHit: before.filter(TransportTape_isMint).count, audioBytesBeforeHit: run.audioBytesBeforeWake ?? 0,
            hitWithNetworkDown: firstEyes.isFinite, eyesBeforeConnect: firstEyes <= firstConnect,
            serverTranscriptWoke: false, hostsAfterWake: hosts, crossover: hosts.filter { !allowedHosts($0) })
    }

    static func TransportTape_isMint(_ c: RunRecord.TransportCall) -> Bool {
        c.path.hasSuffix("/client_secrets") || c.purpose == "mint"
    }
}
