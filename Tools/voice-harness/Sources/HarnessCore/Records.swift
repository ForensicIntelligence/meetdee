import Foundation

/// Everything one scenario run observed, on the harness clock: seconds of audio
/// rendered by the manual AudioGraph since the run began (the clock every DeeVoice
/// mark of that graph uses too). Pure data: the runner fills it, `Metrics` reads it,
/// the JSON report embeds it.
public struct RunRecord: Codable, Sendable, Equatable {
    public struct Interval: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public func contains(_ t: Double) -> Bool { t >= start && t < end }
    }

    public enum UtteranceRole: String, Codable, Sendable { case turn, bargeIn, continuation }

    /// A fixture the user "spoke".
    public struct Utterance: Codable, Sendable, Equatable {
        public var index: Int
        public var step: Int
        public var fixture: String
        public var role: UtteranceRole
        public var text: String
        /// Scheduled start of the file, first voiced sample, exact end of speech.
        public var start: Double
        public var onset: Double
        public var endOfSpeech: Double
        /// Voiced spans (absolute); gaps are the user's mid-turn pauses.
        public var spans: [Interval]
        public var expect: Scenario.Expect
        public var expectMention: [String]?
        /// A held fixture ("hold on", "and…") that the user finished later: the end of
        /// speech of what finished it (nil: not continued).
        public var turnEnd: Double?
        /// A continuation: the index of the held utterance it finishes.
        public var continues: Int?
        /// What a good reply does (judge rubric line from the scenario).
        public var rubric: String?
        /// What `expectMention` probes (`Scenario.Probe`; nil = memory). Tune 2.
        public var probe: Scenario.Probe?
        /// Her reply must mention none of these (tune 2: no hurt after floor control).
        public var forbidMention: [String]?
        /// A listener's backchannel said while she talks (tune 2).
        public var backchannel: Bool?

        public init(index: Int, step: Int, fixture: String, role: UtteranceRole, text: String, start: Double,
                    onset: Double, endOfSpeech: Double, spans: [Interval], expect: Scenario.Expect,
                    expectMention: [String]? = nil, turnEnd: Double? = nil, continues: Int? = nil, rubric: String? = nil,
                    probe: Scenario.Probe? = nil, forbidMention: [String]? = nil, backchannel: Bool? = nil) {
            self.index = index; self.step = step; self.fixture = fixture; self.role = role; self.text = text
            self.start = start; self.onset = onset; self.endOfSpeech = endOfSpeech; self.spans = spans
            self.expect = expect; self.expectMention = expectMention; self.turnEnd = turnEnd
            self.continues = continues; self.rubric = rubric; self.probe = probe; self.forbidMention = forbidMention
            self.backchannel = backchannel
        }

        /// A backchannel ("keep going", "go on", "mm-hm") said over her: she keeps
        /// talking. Older records (no flag) are read by fixture.
        public var isBackchannel: Bool {
            role == .bargeIn && (backchannel ?? TurnShape.isBackchannel(fixture))
        }

        /// Inside a mid-turn pause (after onset, before the end of speech, not voiced).
        public func inPause(_ t: Double) -> Bool {
            t > onset && t < endOfSpeech && !spans.contains { $0.contains(t) }
        }

        /// A mid-turn pause of at least `seconds` between voiced spans.
        public func hasPause(atLeast seconds: Double) -> Bool {
            zip(spans, spans.dropFirst()).contains { $1.start - $0.end >= seconds }
        }

        public func voiced(_ t: Double, margin: Double = 0) -> Bool {
            spans.contains { t >= $0.start - margin && t < $0.end + margin }
        }
    }

    /// One of Dee's items (or clips) on the player.
    public struct Playback: Codable, Sendable, Equatable {
        public var itemID: String
        public var started: Double?
        public var ended: Double?
        public var playedMs: Int?
        public var flushed: Bool?
        public init(itemID: String, started: Double? = nil) { self.itemID = itemID; self.started = started }
    }

    /// A user item the session forwarded to the brain (echo already filtered out).
    public struct UserItem: Codable, Sendable, Equatable {
        public var itemID: String
        public var firstSeen: Double
        public var speechStartedAt: Double?
        public var audioStartMs: Int?
        public var committedAt: Double?
        public var transcript: String?
        public var transcriptFailed: Bool = false
        public init(itemID: String, firstSeen: Double) { self.itemID = itemID; self.firstSeen = firstSeen }
    }

    public struct UsageRecord: Codable, Sendable, Equatable {
        public var inputText = 0, inputAudio = 0, cachedText = 0, cachedAudio = 0
        public var outputText = 0, outputAudio = 0
        public init() {}
    }

    public struct Response: Codable, Sendable, Equatable {
        public var responseID: String?
        public var kind: String
        public var startedAt: Double?
        public var doneAt: Double?
        public var status: String?
        public var reason: String?
        public var itemIDs: [String] = []
        public var transcript: String?
        public var audioMs: Int?
        public var usage: UsageRecord?
        public init(responseID: String?, kind: String) { self.responseID = responseID; self.kind = kind }
    }

    /// `conversation.item.truncate` the session sent (from the TurnTimeline).
    public struct Truncation: Codable, Sendable, Equatable {
        public var itemID: String
        public var audioEndMs: Int
        public var at: Double
        public init(itemID: String, audioEndMs: Int, at: Double) { self.itemID = itemID; self.audioEndMs = audioEndMs; self.at = at }
    }

    public enum BargeOutcome: String, Codable, Sendable {
        /// Dee's audio stopped after the user's onset.
        case stopped
        /// She kept talking (played to the end, or > `missAfter` s after onset). For a
        /// backchannel this is the right outcome ("continued").
        case missed
        /// Her reply had already ended (or never started) when the user began.
        case notApplicable = "n/a"

        /// How a scripted interruption ended, from her playback (pure: the runner and
        /// the tests share it).
        /// - `reply`: the interrupted item; `later`: every other item, for a flush of
        ///   a queued item of the same reply.
        /// - A barge-in is watched for `Metrics.bargeMissAfter` s after its onset; a
        ///   backchannel until `Metrics.backchannelWatch` s after its end of speech (a
        ///   late stop on "keep going" is still a stop).
        /// - `pausedAt`: tune 2, DeeVoice pauses her at once on an onset over her voice
        ///   (`TurnTimeline` `.barge_in` mark, written when the pause ends as a barge-in)
        ///   and flushes only when the words are decided (≈ 1.6–1.9 s, up to
        ///   `pauseHoldMax` s). A flush whose pause began inside the watch window is a
        ///   stop even when the flush itself lands after it.
        public static func classify(reply: Playback?, later: [Playback], onset: Double, endOfSpeech: Double,
                                    backchannel: Bool, pausedAt: Double? = nil) -> (outcome: BargeOutcome, stoppedAt: Double?) {
            let watchUntil = backchannel ? max(onset + Metrics.bargeMissAfter, endOfSpeech + Metrics.backchannelWatch)
                                         : onset + Metrics.bargeMissAfter
            // How late a flush may land: the window, or the pause's own hold limit.
            let flushBy = pausedAt.map { $0 <= watchUntil ? max(watchUntil, $0 + pauseHoldMax) : watchUntil } ?? watchUntil
            if let p = reply, let ended = p.ended {
                if ended <= onset { return (.notApplicable, nil) }
                if p.flushed == true { return ended <= flushBy ? (.stopped, ended) : (.missed, nil) }
                if ended <= onset + 0.5 {
                    // Ran out on its own; a queued item of the same reply may still be flushed.
                    if let s = laterStop(later, onset: onset, until: flushBy) { return (.stopped, s) }
                    return (.notApplicable, nil)
                }
            }
            if let s = laterStop(later, onset: onset, until: flushBy) { return (.stopped, s) }
            return (.missed, nil)
        }

        /// DeeVoice's longest pause before it decides (`CloudVoice.holdMax` 6 s) plus slack.
        public static let pauseHoldMax = 6.5

        /// The pause that ended in this stop: the latest `.barge_in` timeline mark at or
        /// after her reply started, no earlier than 1 s before the onset, and at or before
        /// the flush. nil when there is none (an immediate cut marks at the flush).
        public static func pauseMark(_ marks: [Double], replyStarted: Double?, onset: Double, stoppedAt: Double) -> Double? {
            marks.filter { $0 >= max(replyStarted ?? -.infinity, onset - 1) && $0 <= stoppedAt + 0.05 }.max()
        }

        static func laterStop(_ items: [Playback], onset: Double, until: Double) -> Double? {
            items.filter { $0.flushed == true && ($0.ended ?? 0) > onset && ($0.ended ?? .infinity) <= until }
                .compactMap(\.ended).min()
        }
    }

    public struct BargeIn: Codable, Sendable, Equatable {
        public var step: Int
        public var baseFixture: String
        public var fixture: String
        public var targetAtMs: Double
        /// The reply item being interrupted, and when its audio started.
        public var replyItem: String?
        public var replyStarted: Double?
        /// The interrupting speech's first voiced sample.
        public var onset: Double
        /// Dee's audio stopped (player flushed).
        public var stoppedAt: Double?
        /// Tune 2: her voice went silent (DeeVoice pause, `.barge_in` mark); the flush
        /// (`stoppedAt`) follows when the words are decided. nil in older records.
        public var pausedAt: Double?
        public var outcome: BargeOutcome
        /// A listener's backchannel (she should keep talking). nil in older records:
        /// read by fixture (`TurnShape.isBackchannel`).
        public var backchannel: Bool?
        public init(step: Int, baseFixture: String, fixture: String, targetAtMs: Double, replyItem: String?,
                    replyStarted: Double?, onset: Double, stoppedAt: Double?, outcome: BargeOutcome, backchannel: Bool? = nil) {
            self.step = step; self.baseFixture = baseFixture; self.fixture = fixture; self.targetAtMs = targetAtMs
            self.replyItem = replyItem; self.replyStarted = replyStarted; self.onset = onset
            self.stoppedAt = stoppedAt; self.outcome = outcome; self.backchannel = backchannel
        }
        public var isBackchannel: Bool { backchannel ?? TurnShape.isBackchannel(fixture) }
        /// Onset to silence: the pause when there was one (what the listener hears),
        /// else the flush.
        public var latency: Double? {
            guard let stoppedAt else { return nil }
            return max(0, (pausedAt.map { min($0, stoppedAt) } ?? stoppedAt) - onset)
        }
    }

    /// Dee spoke with nobody talking; only her echo reached the mic.
    public struct EchoSegment: Codable, Sendable, Equatable {
        public var step: Int
        public var line: String
        public var requested: Double
        public var outcome: String
        public var audioStarted: Double?
        public var audioEnded: Double?
        /// The window checked for self-triggers (her audio plus the echo tail).
        public var window: Interval
        public init(step: Int, line: String, requested: Double, outcome: String, audioStarted: Double?,
                    audioEnded: Double?, window: Interval) {
            self.step = step; self.line = line; self.requested = requested; self.outcome = outcome
            self.audioStarted = audioStarted; self.audioEnded = audioEnded; self.window = window
        }
    }

    public struct Request: Codable, Sendable, Equatable {
        public var at: Double
        public var kind: String
        public var outcome: String
        public init(at: Double, kind: String, outcome: String) { self.at = at; self.kind = kind; self.outcome = outcome }
    }

    public struct HistoryTurn: Codable, Sendable, Equatable {
        public var role: String
        public var text: String
        public var itemID: String?
        public init(role: String, text: String, itemID: String?) { self.role = role; self.text = text; self.itemID = itemID }
    }

    public struct TimelineTurn: Codable, Sendable, Equatable {
        public var id: Int
        public var start: Double
        public var marks: [String: Double]
        public var details: [String]
        public init(id: Int, start: Double, marks: [String: Double], details: [String]) {
            self.id = id; self.start = start; self.marks = marks; self.details = details
        }
    }

    /// One socket the session opened (the harness taps every connection).
    public struct Connection: Codable, Sendable, Equatable {
        public var index: Int
        public var opened: Double
        /// The open was refused (HTTP 401 / 429 / network) — scripted or real.
        public var refused: String?
        public var sessionID: String?
        /// `session.created` arrived (the connection is usable).
        public var createdAt: Double?
        public var closedAt: Double?
        public var closeCode: Int?
        public var closeReason: String?
        /// The harness killed it (fault injection).
        public var dropped: Bool?
        public init(index: Int, opened: Double) { self.index = index; self.opened = opened }
    }

    /// A scripted fault and when the session was usable again.
    public struct FaultRecord: Codable, Sendable, Equatable {
        public var step: Int
        public var kind: Scenario.Fault.Kind
        public var at: Double
        /// The first `session.created` on a later connection.
        public var recoveredAt: Double?
        public init(step: Int, kind: Scenario.Fault.Kind, at: Double, recoveredAt: Double? = nil) {
            self.step = step; self.kind = kind; self.at = at; self.recoveredAt = recoveredAt
        }
        public var recovery: Double? { recoveredAt.map { $0 - at } }
    }

    /// A `response.create` the client sent, and whether a DEE DNA item was live in
    /// that conversation (created on this connection and not deleted) when it went.
    public struct ResponseCreate: Codable, Sendable, Equatable {
        public var at: Double
        public var connection: Int
        /// A DNA item was in the conversation.
        public var liveDNA: Bool
        /// A DNA item was created since the previous `response.create` (a fresh render).
        public var freshDNA: Bool
        /// Out of band (`conversation: "none"`): a canned line or the rollover summary.
        public var outOfBand: Bool
        /// `metadata.purpose`, if any (the rollover summary).
        public var purpose: String?
        /// Characters of the live DNA text (size check; the text stays in the trace).
        public var dnaChars: Int?
        public init(at: Double, connection: Int, liveDNA: Bool, freshDNA: Bool, outOfBand: Bool, purpose: String? = nil,
                    dnaChars: Int? = nil) {
            self.at = at; self.connection = connection; self.liveDNA = liveDNA; self.freshDNA = freshDNA
            self.outOfBand = outOfBand; self.purpose = purpose; self.dnaChars = dnaChars
        }
    }

    public struct Note: Codable, Sendable, Equatable {
        public var t: Double
        public var text: String
        public init(t: Double, text: String) { self.t = t; self.text = text }
    }

    public var scenario: String
    public var model: String
    public var brain: String
    public var noise: Scenario.Noise?
    public var bedLevelDB: Double?
    public var echo: EchoConfig?
    public var started: String
    public var duration: Double = 0
    public var connectedAt: Double?
    public var sessionIDs: [String] = []
    public var aborted: String?

    public var utterances: [Utterance] = []
    public var playback: [Playback] = []
    public var userItems: [UserItem] = []
    public var responses: [Response] = []
    public var requests: [Request] = []
    public var truncations: [Truncation] = []
    public var bargeIns: [BargeIn] = []
    public var echoSegments: [EchoSegment] = []
    /// Final transcripts of her items (`.assistantTranscript`), by item.
    public var deeTranscripts: [String: String] = [:]
    /// Sentences the player passed (`sentenceFinished(heard: true)`), by item.
    public var heardSentences: [String: [String]] = [:]
    public var history: [HistoryTurn] = []
    public var timeline: [TimelineTurn] = []
    public var voiceBargeIns: [Double] = []
    public var errors: [Note] = []
    public var notes: [Note] = []
    /// Seconds of mic audio the session was fed (transcription cost estimate).
    public var uplinkSeconds: Double = 0
    public var traceFile: String?

    // Added with the real brain (optional so older reports still decode).
    /// Judge family and the state label of the scenario.
    public var family: String?
    public var state: String?
    public var aecOff: Bool?
    public var connections: [Connection]?
    public var faults: [FaultRecord]?
    public var responseCreates: [ResponseCreate]?
    /// RealtimeBrain decisions (`BrainTrace`, no text).
    public var brainTrace: [Note]?
    /// User items the session deleted as her echo (never forwarded to the brain).
    public var echoRejected: [String]?
    /// Items a `resetConversation` removed on purpose (`RealtimeSession.forgottenItemIDs`);
    /// the truncation history check skips them.
    public var forgottenItems: [String]?

    // 0.6 (optional so older reports still decode).
    /// `--wake` mode of this run (`always-open` / `phrase`); nil: before 0.6 (always open).
    public var wakeMode: String?
    /// Times the voice went DORMANT (`CloudVoice.awakeStates`). Always-open asserts 0.
    public var dormantTransitions: Int?
    /// Provider mode (`openAI`, `lanBrainOpenAIVoice`, `lanEverything`); nil: openAI.
    public var provider: String?
    /// Every outbound call the run's Transport recorded (host, kind, purpose; never
    /// headers, bodies or queries), harness clock.
    public var transport: [TransportCall]?
    /// Wake-window events and voice states ("eyesWake", "connect resume=true",
    /// "voice awake", "disconnect", "perkUp", …), harness clock.
    public var wakeEvents: [Note]?
    /// Outgoing `input_audio_buffer.append` bytes sent before the first wake (W2: 0).
    public var audioBytesBeforeWake: Int?
    /// Local provider measurements (chat requests, TTFT, sentence gaps, …).
    public var providerStats: [String: Double]?

    public struct TransportCall: Codable, Sendable, Equatable {
        public var t: Double
        public var kind: String
        public var host: String
        public var path: String
        public var purpose: String?
        public init(t: Double, kind: String, host: String, path: String, purpose: String? = nil) {
            self.t = t; self.kind = kind; self.host = host; self.path = path; self.purpose = purpose
        }
    }

    public init(scenario: String, model: String, brain: String, started: String) {
        self.scenario = scenario; self.model = model; self.brain = brain; self.started = started
    }

    // MARK: Lookups

    public func response(forItem item: String) -> Response? { responses.first { $0.itemIDs.contains(item) } }

    public func kind(ofItem item: String) -> String? { response(forItem: item)?.kind }

    /// A user item first seen more than this long after an utterance's end of speech
    /// is not that utterance (a server onset arrives ~0.2–0.5 s after the speech
    /// starts; an onset held as maybe-echo is forwarded at most ~1.5 s after it).
    public static let itemWindow = 1.6
    /// The server may open the item on room noise up to this long before the user's
    /// first word, and carry it into the utterance.
    public static let itemLead = 3.0

    /// The utterance a user item belongs to: one whose speech overlaps the item
    /// (first seen at most `itemLead` s before its onset and `window` s after its end
    /// of speech, and still open after its onset), the closest onset winning. nil: a
    /// phantom turn (room noise, TV, an echo the voice accepted).
    public func utterance(forItem item: UserItem, window: Double = RunRecord.itemWindow) -> Utterance? {
        let end = item.committedAt ?? .infinity
        let candidates = utterances.filter { u in
            item.firstSeen <= u.endOfSpeech + window && item.firstSeen >= u.onset - Self.itemLead && end > u.onset + 0.1
        }
        return candidates.min { abs($0.onset - item.firstSeen) < abs($1.onset - item.firstSeen) }
    }
}
