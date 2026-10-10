import Foundation

public enum Stats {
    /// Linear-interpolated percentile (`p` 0…1); nil when empty.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let x = p * Double(s.count - 1)
        let i = Int(x.rounded(.down)), j = min(i + 1, s.count - 1)
        return s[i] + (s[j] - s[i]) * (x - Double(i))
    }
}

/// Every §7.1 measurement over one or more runs.
public struct Metrics: Codable, Sendable, Equatable {
    public struct Utterance: Codable, Sendable, Equatable {
        public var scenario: String
        public var index: Int
        public var fixture: String
        public var role: RunRecord.UtteranceRole
        public var expect: Scenario.Expect
        /// End of speech → first played audio of her reply (s); nil if none after it.
        public var latency: Double?
        public var replyItem: String?
        public var userItems: [String] = []
        public var transcript: String?
        public var werEdits: Int?
        public var werWords: Int?
        public var falseCutoff = false
        public var dropped = false
        public var droppedReason: String?
        public var mentionOK: Bool?
        public var deeReply: String?
        /// Latency bucket (`main`, `filler`, `none`).
        public var bucket: String = TurnShape.Bucket.main.rawValue
        /// Waiting was the right answer at some point of this utterance (a held
        /// fixture, or a mid-sentence pause ≥ `pauseThreshold`).
        public var waitTurn = false
        /// Answered before the user was done (inside a pause, or a held turn before
        /// its continuation / within `holdGrace`).
        public var answeredEarly = false
        /// A listener's backchannel said over her (tune 2).
        public var backchannel: Bool? = nil
        /// What `expectMention` probed (nil: no probe).
        public var probe: Scenario.Probe? = nil
        /// A `forbidMention` phrase her reply used.
        public var forbidden: [String]? = nil
    }

    public struct Leak: Codable, Sendable, Equatable {
        public var scenario: String
        public var itemID: String
        public var rules: [String]
        public var text: String
    }

    public struct Collision: Codable, Sendable, Equatable {
        public var scenario: String
        public var itemID: String
        public var at: Double
        public var fixture: String
        public var kind: String?
    }

    public struct TruncationCheck: Codable, Sendable, Equatable {
        public var scenario: String
        public var itemID: String
        public var audioEndMs: Int
        public var playedMs: Int?
        public var accurate: Bool
        public var historyMatches: Bool?
        public var historyText: String?
        public var heardText: String?
    }

    public var scenarios: [String] = []
    public var utterances: [Utterance] = []

    /// Every measured latency (all buckets; informational).
    public var latencies: [Double] = []
    public var latencyP50: Double?
    public var latencyP90: Double?
    /// Complete turns (gate: p50 ≤ 1.1 s, p90 ≤ 1.6 s).
    public var latencyMain: [Double] = []
    public var latencyMainP50: Double?
    public var latencyMainP90: Double?
    public var expectedMainReplies = 0
    /// Filler turns ("um", "uh", "er": gate p90 ≤ 2.0 s).
    public var latencyFiller: [Double] = []
    public var latencyFillerP50: Double?
    public var latencyFillerP90: Double?
    public var expectedFillerReplies = 0
    /// Turns where waiting is correct (held fixtures + mid-sentence pauses) and how
    /// many of them she answered early.
    public var waitTurns = 0
    public var waitTurnsEarly = 0
    public var waitTurnsEarlyList: [String] = []
    /// The same from DeeVoice's TurnTimeline (`speech_stopped` → `speaking_started`),
    /// i.e. from the server's end-of-speech decision, not ground truth.
    public var timelineLatencies: [Double] = []
    public var timelineP50: Double?

    public var expectedReplies = 0
    public var dropped = 0
    public var spokenUtterances = 0
    public var falseCutoffs = 0
    public var falseCutoffRate: Double?
    /// Utterances with a scripted / measured mid-turn pause (the hard cases).
    public var pausedUtterances = 0
    public var pausedFalseCutoffs = 0

    public var bargeIns = 0
    public var bargeInsApplicable = 0
    public var bargeInsMissed = 0
    public var bargeInLatencies: [Double] = []
    public var bargeInP50: Double?
    public var bargeInP90: Double?
    public var bargeInMissRate: Double?

    /// Tune 5: a question asked over her (a content barge-in, `expect: reply`). She
    /// must stop AND answer it, the answer starting within `interruptAnswerWithin` of
    /// their end of speech and not cut short (tune 4 F1: the app's stop cancelled the
    /// brain's answer to every one of them).
    public struct InterruptQuestion: Codable, Sendable, Equatable {
        public var scenario: String
        public var fixture: String
        public var baseFixture: String
        /// Her reply was still playing when they asked (else not applicable).
        public var applicable: Bool
        /// Her interrupted reply went silent (pause or flush).
        public var stopped: Bool
        /// Their end of speech → first audio of the answer (s).
        public var latency: Double?
        public var answerItem: String?
        public var answer: String?
        public var answered: Bool
        /// Why it does not count as answered (nil when answered).
        public var miss: String?
    }
    public var interruptQuestions: [InterruptQuestion] = []
    public var interruptQuestionsApplicable = 0
    public var interruptQuestionsAnswered = 0
    public var interruptAnswerLatencies: [Double] = []
    public var interruptAnswerP50: Double?
    public var interruptAnswerP90: Double?

    public var echoSegments = 0
    /// Echo-only steps where her line never played (initiative refused): not a test.
    public var echoSegmentsNotSpoken = 0
    public var selfTriggers = 0
    public var selfTriggerItems: [String] = []

    public var truncations: [TruncationCheck] = []
    public var truncationsAccurate = 0
    public var historyChecked = 0
    public var historyMatched = 0

    public var leaks: [Leak] = []

    public var replies = 0
    public var repliesWithinThree = 0
    public var replyLengthRate: Double?
    /// Completed replies that never played (a discarded speculative reply): not counted.
    public var repliesUnplayed = 0
    /// Played replies with heard sentences, and those with ≤ 3 heard sentences.
    public var repliesHeard = 0
    public var repliesHeardWithinThree = 0
    public var replySentenceCounts: [Int] = []

    public var memoryProbes = 0
    public var memoryHits = 0
    /// Follow-ups (a dated plan on its day) and reunions (time apart acknowledged).
    public var followupProbes = 0
    public var followupHits = 0
    public var followupMisses: [String] = []
    /// Follow-up / reunion replies that gave the time apart as a number of days or
    /// hours ("it's been 6 days", "three days"): the decision is words ("nearly a
    /// week", "a couple of days"). Informational, in the `followups` note.
    public var elapsedAsNumber: [String] = []
    public var memoryMisses: [String] = []

    /// Backchannels said over her ("keep going", "go on", "mm-hm"): she must keep
    /// talking. Applicable = her reply was still playing when they started.
    public var backchannels = 0
    public var backchannelsApplicable = 0
    public var backchannelStops = 0
    public var backchannelStopList: [String] = []
    /// Backchannels that reached the server as a user item (informational: either is fine).
    public var backchannelsHeard = 0

    /// Replies that used a phrase the scenario forbids there (e.g. "brushed off" after
    /// a polite stop): `scenario:fixture "phrase"`.
    public var forbiddenHits: [String] = []
    public var forbiddenChecked = 0

    /// Replies that narrate her own process before answering or calling a tool
    /// ("let me respond", "let me check what I remember"): DNA §3.
    public var narrations: [Leak] = []

    public var collisions: [Collision] = []

    /// User items that belong to no scripted utterance and no echo-only window:
    /// the server (and CloudVoice) took room noise or TV for a turn.
    public struct Phantom: Codable, Sendable, Equatable {
        public var scenario: String
        public var itemID: String
        public var at: Double
        public var transcript: String?
        /// A reply was requested for it.
        public var answered: Bool
    }
    public var phantoms: [Phantom] = []

    public var werEdits = 0
    public var werWords = 0
    public var wer: Double?
    public var missingTranscripts = 0

    public var cost = CostSummary()

    /// In-band `response.create`s (not canned lines, not the rollover summary) and how
    /// many had a DEE DNA live in the conversation; replies / initiatives with a fresh one.
    public var dnaRunsChecked = 0
    public var inBandResponses = 0
    public var inBandWithDNA = 0
    public var withoutDNA: [String] = []
    public var freshDNARequests = 0

    /// Scripted faults, rollovers, and turns spoken after them.
    public var faults = 0
    public var faultsRecovered = 0
    public var recoveryTimes: [Double] = []
    public var rollovers = 0
    public var turnsAfterDisruption = 0
    public var turnsLostAfterDisruption = 0
    public var lostAfterDisruption: [String] = []

    public init() {}

    /// A held fixture with no continuation: answering within this long of its end of
    /// speech is early (she should give them a moment to go on).
    public static let holdGrace = 2.0
    /// A fault must be recovered (a new `session.created`) within this.
    public static let recoveryLimit = 15.0

    /// A gap between voiced spans at least this long makes a "paused" utterance.
    public static let pauseThreshold = 0.5
    /// Played-ms tolerance for truncation accuracy: one 20 ms render block + rounding.
    public static let truncationToleranceMs = 21
    /// Her audio still playing this long after a barge-in onset counts as a miss.
    public static let bargeMissAfter = 2.0
    /// A backchannel is watched until this long after its end of speech: a stop
    /// that late is still a stop on "keep going".
    public static let backchannelWatch = 2.0
    /// An interrupting question must be answered within this of its end of speech:
    /// the latency gate's p90 bound (`Gates.Thresholds.latencyP90`), per question.
    public static let interruptAnswerWithin = 1.6
    /// An answer cut (flushed) before this much played was not really heard.
    public static let interruptAnswerMinPlayedMs = 600

    public static func compute(_ runs: [RunRecord], pricing: Pricing) -> Metrics {
        var m = Metrics()
        m.scenarios = runs.map(\.scenario)
        for run in runs { m.add(run) }
        m.latencyP50 = Stats.percentile(m.latencies, 0.5)
        m.latencyP90 = Stats.percentile(m.latencies, 0.9)
        m.latencyMainP50 = Stats.percentile(m.latencyMain, 0.5)
        m.latencyMainP90 = Stats.percentile(m.latencyMain, 0.9)
        m.latencyFillerP50 = Stats.percentile(m.latencyFiller, 0.5)
        m.latencyFillerP90 = Stats.percentile(m.latencyFiller, 0.9)
        m.timelineP50 = Stats.percentile(m.timelineLatencies, 0.5)
        m.falseCutoffRate = m.spokenUtterances > 0 ? Double(m.falseCutoffs) / Double(m.spokenUtterances) : nil
        m.bargeInP50 = Stats.percentile(m.bargeInLatencies, 0.5)
        m.bargeInP90 = Stats.percentile(m.bargeInLatencies, 0.9)
        m.bargeInMissRate = m.bargeInsApplicable > 0 ? Double(m.bargeInsMissed) / Double(m.bargeInsApplicable) : nil
        m.interruptAnswerP50 = Stats.percentile(m.interruptAnswerLatencies, 0.5)
        m.interruptAnswerP90 = Stats.percentile(m.interruptAnswerLatencies, 0.9)
        m.replyLengthRate = m.replies > 0 ? Double(m.repliesWithinThree) / Double(m.replies) : nil
        m.wer = m.werWords > 0 ? Double(m.werEdits) / Double(m.werWords) : nil
        m.cost = CostSummary.of(runs, pricing: pricing)
        return m
    }

    private static let replyKinds: Set<String> = ["reply", "toolFollowUp"]

    private func isReply(_ run: RunRecord, _ item: String) -> Bool {
        guard let k = run.kind(ofItem: item) else { return true }   // unknown: count it (conservative)
        return Self.replyKinds.contains(k)
    }

    mutating func add(_ run: RunRecord) {
        let starts = run.playback.compactMap { p -> (item: String, t: Double)? in p.started.map { (p.itemID, $0) } }
            .sorted { $0.t < $1.t }
        // User items per utterance.
        var itemsFor: [Int: [RunRecord.UserItem]] = [:]
        for item in run.userItems.sorted(by: { $0.firstSeen < $1.firstSeen }) {
            if let u = run.utterance(forItem: item) { itemsFor[u.index, default: []].append(item) }
        }

        for (k, u) in run.utterances.enumerated() {
            var r = Utterance(scenario: run.scenario, index: u.index, fixture: u.fixture, role: u.role, expect: u.expect)
            let backchannel = u.isBackchannel
            if backchannel { r.backchannel = true }
            let next = run.utterances.dropFirst(k + 1).first?.onset ?? .infinity
            let windowEnd = min(next, u.endOfSpeech + 20)
            // Over a backchannel she goes on with the reply she was giving: its later
            // items are not a reply to it (nor a cut-off). Nor are they an answer to a
            // question asked over her (tune 5): only a response made after it is.
            let question = u.role == .bargeIn && u.expect == .reply && !backchannel
            let replyStarts = starts.filter { $0.t > u.onset && $0.t < windowEnd && isReply(run, $0.item)
                && !((backchannel || question) && continuesEarlierReply(run, $0.item, before: u.onset)) }
            let holds = TurnShape.holdsFloor(u.fixture) && u.role != .bargeIn
            // Held: the user is not done until what finishes it (or a grace period).
            let doneAt = holds ? min(u.turnEnd ?? u.endOfSpeech + Self.holdGrace, next) : u.endOfSpeech
            r.bucket = (holds ? TurnShape.Bucket.none : TurnShape.bucket(u.fixture)).rawValue
            if let early = replyStarts.first(where: { $0.t < doneAt }) {
                r.falseCutoff = true
                r.answeredEarly = true
                r.replyItem = early.item
            }
            if !holds, let after = replyStarts.first(where: { $0.t >= u.endOfSpeech }) {
                r.latency = after.t - u.endOfSpeech
                r.replyItem = r.replyItem ?? after.item
            } else if holds, let after = replyStarts.first(where: { $0.t >= doneAt }) {
                r.replyItem = r.replyItem ?? after.item
            }
            r.waitTurn = holds || u.hasPause(atLeast: Self.pauseThreshold)
            if r.waitTurn {
                waitTurns += 1
                if r.answeredEarly { waitTurnsEarly += 1; waitTurnsEarlyList.append("\(run.scenario):\(u.fixture)") }
            }
            var items = itemsFor[u.index] ?? []
            var borrowed = false
            if items.isEmpty, u.role == .continuation, let held = u.continues {
                // The server kept the held turn open through the gap: one item for both.
                items = (itemsFor[held] ?? []).filter { ($0.committedAt ?? .infinity) > u.onset }
                borrowed = !items.isEmpty
            }
            r.userItems = items.map(\.itemID)
            let texts = borrowed ? [] : items.compactMap(\.transcript).filter { !$0.isEmpty }
            // A held turn the server kept open through the gap: its item holds both parts.
            var reference = u.text
            if let cont = run.utterances.first(where: { $0.continues == u.index }),
               items.contains(where: { ($0.committedAt ?? .infinity) > cont.onset }) {
                reference += " " + cont.text
            }
            if !texts.isEmpty {
                r.transcript = texts.joined(separator: " ")
                let s = WER.score(reference: reference, hypothesis: r.transcript!)
                r.werEdits = s.edits; r.werWords = s.words
                werEdits += s.edits; werWords += s.words
            } else if !items.isEmpty && !borrowed {
                missingTranscripts += 1
            }
            if backchannel {
                // She keeps talking either way; whether the server kept an item is not a drop.
                if !items.isEmpty { backchannelsHeard += 1 }
            } else if u.expect != .noReply {
                spokenUtterances += 1
                if items.isEmpty {
                    r.dropped = true; r.droppedReason = "no user item"
                } else if u.expect == .reply && replyStarts.isEmpty {
                    r.dropped = true; r.droppedReason = "no reply"
                }
            }
            if u.expect == .reply { expectedReplies += 1 }
            if r.dropped { dropped += 1 }
            if r.falseCutoff { falseCutoffs += 1 }
            if u.hasPause(atLeast: Self.pauseThreshold) {
                pausedUtterances += 1
                if r.falseCutoff { pausedFalseCutoffs += 1 }
            }
            if let lat = r.latency { latencies.append(lat) }      // also after a cut-off: the user's real end
            if u.expect == .reply && u.role != .bargeIn {
                switch TurnShape.Bucket(rawValue: r.bucket) ?? .main {
                case .main:
                    expectedMainReplies += 1
                    if let lat = r.latency { latencyMain.append(lat) }
                case .filler:
                    expectedFillerReplies += 1
                    if let lat = r.latency { latencyFiller.append(lat) }
                case .none:
                    break
                }
            }
            let replyText = replyStarts.map { run.deeTranscripts[$0.item] ?? run.response(forItem: $0.item)?.transcript ?? "" }
                .joined(separator: " ")
            r.deeReply = replyText.isEmpty ? nil : replyText
            if let mention = u.expectMention, !mention.isEmpty {
                let ok = mention.contains { replyText.range(of: $0, options: .caseInsensitive) != nil }
                let kind = u.probe ?? .memory
                r.mentionOK = ok
                r.probe = kind
                let tag = "\(run.scenario):\(u.fixture)"
                if kind == .memory {
                    memoryProbes += 1
                    if ok { memoryHits += 1 } else { memoryMisses.append(tag) }
                } else {
                    followupProbes += 1
                    if ok { followupHits += 1 } else { followupMisses.append("\(tag) (\(kind.rawValue))") }
                    if let n = ElapsedTime.exactCount(in: replyText) { elapsedAsNumber.append("\(tag) \"\(n)\"") }
                }
            }
            if let forbid = u.forbidMention, !forbid.isEmpty, !replyText.isEmpty {
                forbiddenChecked += 1
                let hits = forbid.filter { replyText.range(of: $0, options: .caseInsensitive) != nil }
                if !hits.isEmpty {
                    r.forbidden = hits
                    forbiddenHits.append("\(run.scenario):\(u.fixture) \"\(hits.joined(separator: "\", \""))\"")
                }
            }
            utterances.append(r)
        }

        for item in run.userItems where run.utterance(forItem: item) == nil {
            guard !run.echoSegments.contains(where: { $0.audioStarted != nil && $0.window.contains(item.firstSeen) }) else { continue }
            let answered = run.responses.contains { r in
                r.kind == "reply" && (r.startedAt.map { $0 >= item.firstSeen && $0 <= (item.committedAt ?? item.firstSeen) + 3 } ?? false)
            }
            phantoms.append(Phantom(scenario: run.scenario, itemID: item.itemID, at: item.firstSeen,
                                    transcript: item.transcript, answered: answered))
        }

        for turn in run.timeline {
            // `speaking_started` (CloudVoice, graph clock); the player's own
            // `first_audio_played` is off the graph clock in manual rendering.
            if let a = turn.marks["speech_stopped"], let b = turn.marks["speaking_started"], b >= a {
                timelineLatencies.append(b - a)
            }
        }

        for b in run.bargeIns {
            if b.isBackchannel {
                backchannels += 1
                switch b.outcome {
                case .notApplicable: break
                case .missed: backchannelsApplicable += 1          // she kept talking: right
                case .stopped:
                    backchannelsApplicable += 1
                    backchannelStops += 1
                    backchannelStopList.append("\(run.scenario):\(b.fixture)")
                }
                continue
            }
            bargeIns += 1
            switch b.outcome {
            case .notApplicable: break
            case .missed: bargeInsApplicable += 1; bargeInsMissed += 1
            case .stopped:
                bargeInsApplicable += 1
                if let l = b.latency { bargeInLatencies.append(l) }
            }
        }

        addInterruptQuestions(run)

        for seg in run.echoSegments {
            guard seg.audioStarted != nil else { echoSegmentsNotSpoken += 1; continue }
            echoSegments += 1
            let triggered = run.userItems.filter { seg.window.contains($0.firstSeen) }
            let replies = run.responses.filter { r in
                r.kind == "reply" && (r.startedAt.map { seg.window.contains($0) } ?? false)
            }
            if !triggered.isEmpty || !replies.isEmpty {
                selfTriggers += 1
                selfTriggerItems += triggered.map(\.itemID) + replies.compactMap(\.responseID)
            }
        }

        for t in run.truncations {
            let p = run.playback.first { $0.itemID == t.itemID }
            let played = p?.playedMs ?? (p?.started == nil ? 0 : nil)
            let accurate = played.map { abs($0 - t.audioEndMs) <= Self.truncationToleranceMs } ?? false
            var check = TruncationCheck(scenario: run.scenario, itemID: t.itemID, audioEndMs: t.audioEndMs,
                                        playedMs: played, accurate: accurate)
            let heard = (run.heardSentences[t.itemID] ?? []).joined(separator: " ")
            let hist = run.history.filter { $0.role == "assistant" && $0.itemID == t.itemID }.map(\.text).joined(separator: " ")
            if !run.history.isEmpty {
                check.historyMatches = WER.normalize(heard) == WER.normalize(hist)
                check.heardText = heard
                check.historyText = hist
                historyChecked += 1
                if check.historyMatches == true { historyMatched += 1 }
            }
            truncations.append(check)
            if accurate { truncationsAccurate += 1 }
        }

        var scanned = Set<String>()
        for (item, text) in run.deeTranscripts.sorted(by: { $0.key < $1.key }) {
            scanned.insert(item)
            let rules = LeakScanner.scan(text)
            if !rules.isEmpty { leaks.append(Leak(scenario: run.scenario, itemID: item, rules: rules, text: text)) }
            let said = NarrationScanner.scan(text)
            if !said.isEmpty { narrations.append(Leak(scenario: run.scenario, itemID: item, rules: said, text: text)) }
        }
        for r in run.responses {
            guard let text = r.transcript, !r.itemIDs.contains(where: scanned.contains) else { continue }
            let rules = LeakScanner.scan(text)
            if !rules.isEmpty {
                leaks.append(Leak(scenario: run.scenario, itemID: r.itemIDs.first ?? r.responseID ?? "?", rules: rules, text: text))
            }
        }

        for r in run.responses where r.kind == "reply" && r.status == "completed" {
            let text = r.itemIDs.compactMap { run.deeTranscripts[$0] }.joined(separator: " ")
            let t = text.isEmpty ? (r.transcript ?? "") : text
            guard !t.isEmpty else { continue }
            // Tune 4: a speculative reply the brain held and discarded completes on the
            // server but is never played. Nobody heard it, so it has no length.
            let played = run.playback.contains { p in r.itemIDs.contains(p.itemID) && p.started != nil }
            guard played || run.playback.isEmpty else { repliesUnplayed += 1; continue }
            let n = Sentences.count(t)
            replies += 1
            replySentenceCounts.append(n)
            if n <= 3 { repliesWithinThree += 1 }
            // What she actually said: the sentences the player finished (heard).
            let heard = r.itemIDs.reduce(0) { $0 + (run.heardSentences[$1]?.count ?? 0) }
            if heard > 0 {
                repliesHeard += 1
                if heard <= 3 { repliesHeardWithinThree += 1 }
            }
        }

        addDNA(run)
        addDisruptions(run)

        for s in starts {
            guard let u = run.utterances.first(where: { u in
                u.spans.contains { s.t > $0.start + 0.02 && s.t < $0.end }
            }) else { continue }
            // Going on with the reply she was giving while they say "keep going" is
            // what they asked for.
            if u.isBackchannel && continuesEarlierReply(run, s.item, before: u.onset) { continue }
            collisions.append(Collision(scenario: run.scenario, itemID: s.item, at: s.t, fixture: u.fixture,
                                        kind: run.kind(ofItem: s.item)))
        }
    }

    /// Questions asked over her (`expect: reply` barge-ins): stopped, then answered in time.
    mutating func addInterruptQuestions(_ run: RunRecord) {
        for b in run.bargeIns where !b.isBackchannel {
            guard let u = run.utterances.first(where: { $0.role == .bargeIn && $0.step == b.step && $0.fixture == b.fixture }),
                  u.expect == .reply,
                  let row = utterances.last(where: { $0.scenario == run.scenario && $0.index == u.index }) else { continue }
            let applicable = b.outcome != .notApplicable
            let stopped = b.outcome == .stopped
            var q = InterruptQuestion(scenario: run.scenario, fixture: u.fixture, baseFixture: b.baseFixture,
                                      applicable: applicable, stopped: stopped, latency: row.latency,
                                      answerItem: row.replyItem, answer: row.deeReply, answered: false)
            let played = row.replyItem.flatMap { item in run.playback.first { $0.itemID == item } }
            let limitMs = Int((Self.interruptAnswerWithin * 1000).rounded())
            if applicable && !stopped {
                q.miss = "kept talking over the question"
            } else if row.answeredEarly {
                q.miss = "answered before they finished"
            } else if row.replyItem == nil || row.latency == nil {
                q.miss = "never answered"
            } else if let l = row.latency, Int((l * 1000).rounded()) > limitMs {
                q.miss = String(format: "answered late (%.2f s)", l)
            } else if let p = played, p.flushed == true, (p.playedMs ?? 0) < Self.interruptAnswerMinPlayedMs {
                q.miss = "answer cut after \(p.playedMs ?? 0) ms"
            } else {
                q.answered = true
            }
            if applicable {
                if let l = row.latency { interruptAnswerLatencies.append(l) }
                interruptQuestionsApplicable += 1
                if q.answered { interruptQuestionsAnswered += 1 }
            }
            interruptQuestions.append(q)
        }
    }

    /// `item` belongs to a response created before `t` (she is going on with it).
    func continuesEarlierReply(_ run: RunRecord, _ item: String, before t: Double) -> Bool {
        guard let r = run.response(forItem: item), let created = r.startedAt else { return false }
        return created < t
    }

    /// Every in-band response must have a DEE DNA in the conversation (real brain).
    mutating func addDNA(_ run: RunRecord) {
        let creates = run.responseCreates ?? []
        guard creates.contains(where: { $0.liveDNA }) else { return }   // no DNA brain (minimal)
        dnaRunsChecked += 1
        for c in creates where !c.outOfBand {
            inBandResponses += 1
            if c.liveDNA { inBandWithDNA += 1 } else { withoutDNA.append(String(format: "%@ %.2f s", run.scenario, c.at)) }
            if c.freshDNA { freshDNARequests += 1 }
        }
    }

    /// Faults (scripted drops / refused opens) and rollovers: recovered in time, and
    /// no user turn after them lost.
    /// How long after the end of speech a turn can still be uncommitted.
    static let commitLag = 1.0

    mutating func addDisruptions(_ run: RunRecord) {
        let conns = (run.connections ?? []).sorted { $0.opened < $1.opened }
        var disruptions: [Double] = []
        for f in run.faults ?? [] {
            faults += 1
            disruptions.append(f.at)
            if let r = f.recovery, r <= Self.recoveryLimit {
                faultsRecovered += 1
                recoveryTimes.append(r)
            }
        }
        // A rollover: a connection opened while an earlier one was live (make-before-break).
        for (i, c) in conns.enumerated() where i > 0 {
            let overlapping = conns[..<i].contains { p in p.createdAt != nil && (p.closedAt ?? .infinity) > c.opened }
            if overlapping, c.createdAt != nil {
                rollovers += 1
                disruptions.append(c.opened)
            }
        }
        guard let first = disruptions.min() else { return }
        // A turn not yet committed when the disruption starts is affected too, not
        // only turns begun after it: the server commits ~0.7 s after the end of
        // speech, so a rollover opening up to a second after it can still lose it.
        for u in run.utterances where u.endOfSpeech + Self.commitLag > first && u.expect != .noReply {
            turnsAfterDisruption += 1
            if let r = utterances.last(where: { $0.scenario == run.scenario && $0.index == u.index }), r.dropped {
                turnsLostAfterDisruption += 1
                lostAfterDisruption.append("\(run.scenario):\(u.fixture)")
            }
        }
    }
}
