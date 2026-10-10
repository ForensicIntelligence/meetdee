import Foundation

/// A scripted conversation (JSON). See `Scenarios/README` in the tool docs.
///
///     {
///       "name": "smoke-echo",
///       "noise": {"bed": "kitchen", "snrDb": 15},
///       "echo": {"gainDB": -20, "delayMs": 80, "reverb": true},
///       "instructions": "optional per-turn instructions for the brain",
///       "steps": [
///         {"say": "q01"},
///         {"say": "l01", "bargeIn": {"say": "c03", "atMs": 900}},
///         {"silence": 1.5},
///         {"deeSays": "Owls can turn their heads almost all the way around.", "expect": "noReply"}
///       ]
///     }
public struct Scenario: Codable, Sendable, Equatable {
    public struct Noise: Codable, Sendable, Equatable {
        public var bed: String
        public var snrDb: Double
        public init(bed: String, snrDb: Double) { self.bed = bed; self.snrDb = snrDb }
    }

    public struct BargeIn: Codable, Sendable, Equatable {
        /// Fixture the user interrupts with.
        public var say: String
        /// Start the interruption's speech this long after Dee's first played audio
        /// of the reply to the base utterance.
        public var atMs: Double
        /// A listener's backchannel: she should keep talking (default: by fixture,
        /// `TurnShape.isBackchannel`).
        public var backchannel: Bool?
        /// Tune 5: what she owes the interruption. `reply` makes it a content barge-in
        /// (a question asked over her): she must stop AND answer it within the latency
        /// gate (`interrupt_questions`). Default `any` (a stop command may or may not
        /// get a reply); a backchannel is always `any`.
        public var expect: Expect?
        /// What a good answer to the interruption does (judge rubric line).
        public var rubric: String?
        public init(say: String, atMs: Double, backchannel: Bool? = nil, expect: Expect? = nil, rubric: String? = nil) {
            self.say = say; self.atMs = atMs; self.backchannel = backchannel; self.expect = expect; self.rubric = rubric
        }
        public var isBackchannel: Bool { backchannel ?? TurnShape.isBackchannel(say) }
        /// What the runner records for the interrupting utterance.
        public var expected: Expect { isBackchannel ? .any : (expect ?? .any) }
    }

    /// What an `expectMention` probes; each has its own gate.
    public enum Probe: String, Codable, Sendable {
        /// A fact given earlier is used when asked (§7.1 memory gate).
        case memory
        /// A dated plan is followed up on its day ("how did the exam go?").
        case followup
        /// A reunion after a long time apart is acknowledged.
        case reunion
    }

    /// The user resumes a held turn ("hold on", "and…") after a gap.
    public struct Continuation: Codable, Sendable, Equatable {
        /// Fixture with the rest of the turn.
        public var say: String
        /// Gap from the held fixture's end of speech to the continuation's onset (ms).
        public var afterMs: Double
        public init(say: String, afterMs: Double) { self.say = say; self.afterMs = afterMs }
    }

    /// A scripted connection fault (fallback gate, §7.1 last row).
    public struct Fault: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// The socket dies (no close frame): the session must reconnect.
            case drop
            /// The next socket open is refused with HTTP 401 (expired / revoked secret),
            /// then the socket dies: the session must mint a fresh secret and reconnect.
            case reject401
            /// The next open is refused with HTTP 429, then the socket dies.
            case reject429
        }
        public var kind: Kind
        /// With `faultDuringReply`: this long after her reply's first audio (ms).
        public var afterMs: Double?
        public init(kind: Kind, afterMs: Double? = nil) { self.kind = kind; self.afterMs = afterMs }
    }

    /// Things that happen to Dee's body and clock between turns (real brain only;
    /// the minimal brain notes and ignores them).
    public struct HostAction: Codable, Sendable, Equatable {
        /// The user walks away (presence lost).
        public var leave: Bool?
        /// Simulated clock jumps forward (the Mind catches up on the time apart).
        public var advanceHours: Double?
        /// …or to the next such weekday (never today, as DeeSelf reads "on Friday") at
        /// `atHour` local time (default 18): "the day of the plan, afterwards".
        public var advanceToWeekday: String?
        public var atHour: Double?
        /// A new conversation (Cortex counters, realtime context cleared).
        public var newConversation: Bool?
        /// The user is back in front of her (presence + identified).
        public var arrive: Bool?
        public init(leave: Bool? = nil, advanceHours: Double? = nil, advanceToWeekday: String? = nil, atHour: Double? = nil,
                    newConversation: Bool? = nil, arrive: Bool? = nil) {
            self.leave = leave; self.advanceHours = advanceHours; self.advanceToWeekday = advanceToWeekday
            self.atHour = atHour; self.newConversation = newConversation; self.arrive = arrive
        }

        /// Hours from `now` to the next `weekday` (not today) at `hour` local time.
        public static func hours(from now: Date, toNext weekday: String, at hour: Double = 18,
                                 calendar: Calendar = .current) -> Double? {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let target = names.firstIndex(of: weekday.lowercased()) else { return nil }
            let today = calendar.component(.weekday, from: now) - 1
            var days = (target - today + 7) % 7
            if days == 0 { days = 7 }
            guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
            return day.addingTimeInterval(hour * 3600).timeIntervalSince(now) / 3600
        }
    }

    /// Session client behaviour for fallback scenarios.
    public struct SessionTuning: Codable, Sendable, Equatable {
        /// `RealtimeSessionConfig.rolloverAfter` / `forceRolloverAfter` (s).
        public var rolloverAfter: Double?
        public var forceRolloverAfter: Double?
        /// Ephemeral `ek_` secret lifetime (s, 10…7200).
        public var secretTTL: Int?
        public init(rolloverAfter: Double? = nil, forceRolloverAfter: Double? = nil, secretTTL: Int? = nil) {
            self.rolloverAfter = rolloverAfter; self.forceRolloverAfter = forceRolloverAfter; self.secretTTL = secretTTL
        }
    }

    /// Who she is talking to (real brain): a known person, or a stranger.
    public struct PersonSetup: Codable, Sendable, Equatable {
        public var name: String?
        /// Known for this many days (first met), 0 = met today.
        public var knownDays: Double?
        public init(name: String? = nil, knownDays: Double? = nil) { self.name = name; self.knownDays = knownDays }
    }

    public enum Expect: String, Codable, Sendable {
        /// Dee answers (default for user utterances).
        case reply
        /// Dee must not answer (echo-only segments, default for `deeSays`).
        case noReply
        /// Either is fine (e.g. a bare "stop").
        case any
    }

    public struct Step: Codable, Sendable, Equatable {
        /// A user utterance (fixture id).
        public var say: String?
        /// Silence (room bed only), seconds.
        public var silence: Double?
        /// Dee speaks this line unprompted (initiative "say exactly"), echo only: no user.
        public var deeSays: String?
        /// Dee speaks first with these initiative instructions (her own words).
        public var deeInitiative: String?
        public var bargeIn: BargeIn?
        public var expect: Expect?
        /// Longest wait for Dee's reply to start after the end of speech (s).
        public var replyTimeout: Double?
        /// Quiet gap after Dee finishes before the next step (s).
        public var gapAfter: Double?
        /// Per-step instructions for the brain (overrides the scenario's).
        public var instructions: String?
        /// Memory probe: Dee's reply to this step must mention one of these
        /// (case-insensitive), e.g. a name the user gave earlier (§7.1 memory gate).
        public var expectMention: [String]?
        /// The user resumes this (held) turn with another fixture after a gap.
        public var then: Continuation?
        /// A connection fault now (a step of its own).
        public var fault: Fault?
        /// A connection fault while her reply to this `say` plays (`afterMs` after its first audio).
        public var faultDuringReply: Fault?
        /// Body / clock changes (a step of its own).
        public var host: HostAction?
        /// What a good reply to this turn does (LLM judge rubric line).
        public var rubric: String?
        /// What `expectMention` probes (default `memory`).
        public var probe: Probe?
        /// Her reply to this step must mention none of these (case-insensitive), e.g.
        /// no "brushed off" after a polite "stop talking for a second".
        public var forbidMention: [String]?

        public init(say: String? = nil, silence: Double? = nil, deeSays: String? = nil, deeInitiative: String? = nil,
                    bargeIn: BargeIn? = nil, expect: Expect? = nil, replyTimeout: Double? = nil,
                    gapAfter: Double? = nil, instructions: String? = nil, expectMention: [String]? = nil,
                    then: Continuation? = nil, fault: Fault? = nil, faultDuringReply: Fault? = nil,
                    host: HostAction? = nil, rubric: String? = nil, probe: Probe? = nil, forbidMention: [String]? = nil) {
            self.say = say; self.silence = silence; self.deeSays = deeSays; self.deeInitiative = deeInitiative
            self.bargeIn = bargeIn; self.expect = expect; self.replyTimeout = replyTimeout
            self.gapAfter = gapAfter; self.instructions = instructions; self.expectMention = expectMention
            self.then = then; self.fault = fault; self.faultDuringReply = faultDuringReply; self.host = host
            self.rubric = rubric; self.probe = probe; self.forbidMention = forbidMention
        }

        public var expected: Expect {
            if let expect { return expect }
            if deeSays != nil || deeInitiative != nil || silence != nil || fault != nil || host != nil { return .noReply }
            // A held turn ("hold on", "and…") is not answered on its own.
            if let say, TurnShape.holdsFloor(say) { return .any }
            return .reply
        }
    }

    public var name: String
    public var description: String?
    public var noise: Noise?
    public var echo: EchoConfig?
    public var instructions: String?
    /// Seconds of room tone before the first step (lets the session connect + pre-roll).
    public var leadIn: Double?
    public var steps: [Step]
    /// Judge family (`acoustic`, `dna`, `fallback`, …): rubric means are reported per family.
    public var family: String?
    /// Dee's state as the judge should read it ("she was just insulted", …): the
    /// judge is blind to the DNA text (docs/DNA.md §5.6).
    public var state: String?
    /// Real brain: who she talks to (default: a known person, "Alex", met 20 days ago).
    public var person: PersonSetup?
    /// Real brain: she has never met this speaker (no person).
    public var stranger: Bool?
    /// Session client tuning (rollover, secret lifetime).
    public var session: SessionTuning?
    /// The echo path models a device without echo cancellation (recorded for the report).
    public var aecOff: Bool?

    public init(name: String, description: String? = nil, noise: Noise? = nil, echo: EchoConfig? = nil,
                instructions: String? = nil, leadIn: Double? = nil, steps: [Step], family: String? = nil,
                state: String? = nil, person: PersonSetup? = nil, stranger: Bool? = nil, session: SessionTuning? = nil,
                aecOff: Bool? = nil) {
        self.name = name; self.description = description; self.noise = noise; self.echo = echo
        self.instructions = instructions; self.leadIn = leadIn; self.steps = steps; self.family = family
        self.state = state; self.person = person; self.stranger = stranger; self.session = session; self.aecOff = aecOff
    }

    /// Fixture ids this scenario plays, in order.
    public var fixtureIDs: [String] {
        steps.flatMap { s -> [String] in [s.say, s.then?.say, s.bargeIn?.say].compactMap { $0 } }
    }

    public var faultCount: Int { steps.filter { $0.fault != nil || $0.faultDuringReply != nil }.count }

    public var userUtteranceCount: Int { fixtureIDs.count }
    public var bargeInCount: Int { steps.filter { $0.bargeIn != nil }.count }
    public var echoOnlyCount: Int { steps.filter { $0.deeSays != nil || $0.deeInitiative != nil }.count }

    /// Problems that make the scenario unrunnable against `manifest`.
    public func validate(against manifest: FixtureManifest) -> [String] {
        var issues: [String] = []
        for id in fixtureIDs where manifest.utterance(id) == nil { issues.append("\(name): unknown fixture \(id)") }
        if let bed = noise?.bed, !manifest.noise.contains(where: { $0.id == bed }) {
            issues.append("\(name): unknown noise bed \(bed)")
        }
        for (i, s) in steps.enumerated() {
            let kinds = [s.say != nil, s.silence != nil, s.deeSays != nil, s.deeInitiative != nil, s.fault != nil,
                         s.host != nil].filter { $0 }.count
            if kinds != 1 { issues.append("\(name) step \(i): exactly one of say / silence / deeSays / deeInitiative / fault / host") }
            if s.bargeIn != nil && s.say == nil { issues.append("\(name) step \(i): bargeIn needs a say") }
            if s.then != nil && s.say == nil { issues.append("\(name) step \(i): then needs a say") }
            if s.then != nil && s.bargeIn != nil { issues.append("\(name) step \(i): then and bargeIn don't mix") }
            if s.faultDuringReply != nil && s.say == nil { issues.append("\(name) step \(i): faultDuringReply needs a say") }
            if let b = s.bargeIn, b.isBackchannel, let e = b.expect, e != .any {
                issues.append("\(name) step \(i): a backchannel (\(b.say)) is never answered; drop its expect")
            }
        }
        return issues
    }
}

/// A file of scenarios (or a single one).
public struct ScenarioFile: Codable, Sendable {
    public var scenarios: [Scenario]

    public init(scenarios: [Scenario]) { self.scenarios = scenarios }

    public static func load(_ url: URL) throws -> ScenarioFile {
        let data = try Data(contentsOf: url)
        if let file = try? JSONDecoder().decode(ScenarioFile.self, from: data) { return file }
        return ScenarioFile(scenarios: [try JSONDecoder().decode(Scenario.self, from: data)])
    }
}
