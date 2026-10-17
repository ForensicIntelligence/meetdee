import Foundation

/// The §7.1 acceptance gates, evaluated on `Metrics`.
public struct Gate: Codable, Sendable, Equatable {
    /// `info`: round 3, a measured value that is not a gate (never fails a run).
    public enum Status: String, Codable, Sendable { case pass = "PASS", fail = "FAIL", skip = "SKIP", info = "INFO" }

    public var id: String
    public var metric: String
    public var target: String
    public var value: String
    public var n: Int
    public var status: Status
    public var note: String?

    public init(id: String, metric: String, target: String, value: String, n: Int, status: Status, note: String? = nil) {
        self.id = id; self.metric = metric; self.target = target; self.value = value
        self.n = n; self.status = status; self.note = note
    }
}

public enum Gates {
    public struct Thresholds: Codable, Sendable, Equatable {
        /// Tune 10: no end-to-end p50 bound. The server + model floor alone is p50
        /// 1.12–1.17 s at 300 ms VAD silence (tunes 7–9), above the old 1.1 s target;
        /// Dee's own overhead (end-to-end − floor) is gated instead.
        public var latencyP90 = 1.6
        public var overheadP50 = 0.10
        public var overheadP90 = 0.25
        public var fillerP90 = 2.0
        public var falseCutoffRate = 0.05
        public var waitEarlyRate = 0.05
        public var judgeMean = Judge.meanTarget
        public var bargeInP90 = 0.5
        public var bargeInMissRate = 0.05
        public var replyWithinThree = 0.95
        public var memory = 0.90
        /// Backchannels ("keep going", "go on", "mm-hm") Dee stopped on.
        public var backchannelStopRate = 0.05
        /// Dated follow-ups and reunions acknowledged.
        public var followups = 1.0
        /// Tune 5: questions asked over Dee that Dee stopped for and answered in time.
        public var interruptAnswered = 1.0
        /// Calm (D1): `barge_in` measures onset → Dee gives way (a dip or a pause), with
        /// `bargeInP90` / `bargeInMissRate`; the new `silence` gate bounds onset → Dee
        /// fully silent. false: 0.6.0's onset → silent / flushed.
        public var bargeInMeasuresYield = true
        /// Calm round 2 (user decision D1): onset → Dee audibly dips, p90. The 0.6.0
        /// measure (`bargeInMeasuresYield = false`) keeps `bargeInP90`.
        public var yieldP90 = 0.4
        /// Calm `false_pause`: short sounds + single-clause continuers over Dee with an
        /// audible pause or a stop (≤ 5 %, pooled n ≥ 40; 0 stops on a sound).
        public var falsePauseRate = 0.05
        public var falsePauseMinN = 40
        /// Calm `false_barge`: pauses per 10 Dee-talking minutes with no user audio
        /// (0 stops anywhere); TV conditions at 10 dB SNR get `falseBargeTVPer10`.
        public var falseBargePer10 = 1.0
        /// Round 2: 0 pauses (and 0 cuts) with a TV on and nobody talking to Dee, in
        /// every TV condition (`tv…`: tv15, tv10, tvlong10). "Background noise/TV" is
        /// what the user named.
        public var falseBargeTVPer10 = 0.0
        public var falseBargeTVConditions: Set<String> = ["tv10", "tvlong10"]
        /// Round 2: any condition whose id starts with this is a TV room.
        public var falseBargeTVPrefix: String? = "tv"
        public func isTVCondition(_ c: String) -> Bool {
            falseBargeTVConditions.contains(c) || (falseBargeTVPrefix.map { !$0.isEmpty && c.hasPrefix($0) } ?? false)
        }
        /// Calm `silence`: onset → Dee fully silent, p90; every stop / command fixture
        /// ends the reply within `Metrics.stopEndWithin`.
        public var silenceMultiP90 = 0.75
        public var silenceLoneP90 = 1.1
        /// Round 2 (D1): the stop / command phrase's end → Dee fully silent, p90 (the
        /// fixtures of `FixtureCatalog.stopWordEnds`). Other real interruptions may stay
        /// dipped until their words show a real turn: their onset → silent is reported.
        public var stopWordSilenceP90 = 1.0
        /// true: the round-1 bounds (multi-word / lone, from the onset) instead.
        public var silenceFromOnset = false
        public var stopCommandsEnded = 1.0
        /// Calm `duck_time`: duck → unduck of short events, p90.
        public var duckTimeP90 = 1.5
        public init() {}
    }

    static func s(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

    public static func evaluate(_ m: Metrics, judge: Judge.Summary? = nil, thresholds t: Thresholds = Thresholds()) -> [Gate] {
        var g: [Gate] = []

        // 1. Latency of complete turns: end of a COMPLETE turn → first played audio.
        // Tune 10: p90 end to end, plus Dee's own overhead over the server + model
        // floor (`Metrics.serverModelFloor`); the end-to-end p50 is information.
        let latencyMetric = "End of a complete turn → first Dee audio played; Dee's overhead over the server + model floor"
        let latencyTarget = "p90 ≤ \(t.latencyP90) s; overhead p50 ≤ \(t.overheadP50) s, p90 ≤ \(t.overheadP90) s"
        if m.latencyMain.isEmpty {
            g.append(Gate(id: "latency", metric: latencyMetric, target: latencyTarget, value: "no replies measured",
                          n: 0, status: m.expectedMainReplies > 0 ? .fail : .skip))
        } else {
            let overheadOK = m.latencyOverhead.isEmpty
                || ((m.latencyOverheadP50 ?? .infinity) <= t.overheadP50 + 1e-9 && (m.latencyOverheadP90 ?? .infinity) <= t.overheadP90 + 1e-9)
            let ok = (m.latencyMainP90 ?? .infinity) <= t.latencyP90 && overheadOK
            let overhead = m.latencyOverhead.isEmpty ? "overhead not measured (no timeline)"
                : "overhead p50 \(s(m.latencyOverheadP50)) s, p90 \(s(m.latencyOverheadP90)) s (n=\(m.latencyOverhead.count))"
            g.append(Gate(id: "latency", metric: latencyMetric, target: latencyTarget,
                          value: "p90 \(s(m.latencyMainP90)) s; \(overhead)", n: m.latencyMain.count,
                          status: ok ? .pass : .fail,
                          note: ([String(format: "info: end-to-end p50 %@ s, floor p50 %@ s", s(m.latencyMainP50), s(m.latencyFloorP50)),
                                  m.latencyMain.count < 10 ? "small sample: p90 is close to the max" : nil].compactMap { $0 })
                                .joined(separator: "; ")))
        }
        // 1b. Filler turns ("um", "uh"): their own bucket.
        if m.latencyFiller.isEmpty {
            g.append(Gate(id: "latency_filler", metric: "Filler turns (um / uh / er) → first Dee audio",
                          target: "p90 ≤ \(t.fillerP90) s", value: "no filler replies measured", n: 0,
                          status: m.expectedFillerReplies > 0 ? .fail : .skip))
        } else {
            g.append(Gate(id: "latency_filler", metric: "Filler turns (um / uh / er) → first Dee audio",
                          target: "p90 ≤ \(t.fillerP90) s",
                          value: "p50 \(s(m.latencyFillerP50)) s, p90 \(s(m.latencyFillerP90)) s", n: m.latencyFiller.count,
                          status: (m.latencyFillerP90 ?? .infinity) <= t.fillerP90 ? .pass : .fail))
        }
        // 1c. Waiting is correct: "hold on", a trailing "and…", mid-sentence pauses.
        let waitRate = m.waitTurns > 0 ? Double(m.waitTurnsEarly) / Double(m.waitTurns) : nil
        g.append(Gate(id: "wait_turns", metric: "Held turns answered early (hold on / trailing and… / mid-sentence pauses)",
                      target: "< \(pct(t.waitEarlyRate))",
                      value: "\(pct(waitRate)) (\(m.waitTurnsEarly)/\(m.waitTurns))", n: m.waitTurns,
                      status: m.waitTurns == 0 ? .skip : ((waitRate ?? 0) < t.waitEarlyRate ? .pass : .fail),
                      note: m.waitTurnsEarlyList.isEmpty ? nil : m.waitTurnsEarlyList.joined(separator: ", ")))

        // 2. Dropped utterances.
        g.append(Gate(id: "dropped", metric: "Dropped user utterances (no user item / no reply)", target: "0",
                      value: "\(m.dropped)", n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : (m.dropped == 0 ? .pass : .fail)))

        // 3. False cut-offs.
        g.append(Gate(id: "false_cutoff", metric: "False cut-off (Dee starts mid-thought)",
                      target: "< \(pct(t.falseCutoffRate))",
                      value: "\(pct(m.falseCutoffRate)) (\(m.falseCutoffs); \(m.pausedFalseCutoffs)/\(m.pausedUtterances) with pauses)",
                      n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : ((m.falseCutoffRate ?? 0) < t.falseCutoffRate ? .pass : .fail)))

        // 4. Barge-in. Calm (D1): onset → Dee gives way (dip or pause).
        if t.bargeInMeasuresYield {
            g.append(yieldGate(m, t))
        } else if m.bargeInsApplicable == 0 {
            g.append(Gate(id: "barge_in", metric: "Barge-in: user onset → Dee audio stopped; misses",
                          target: "p90 ≤ \(t.bargeInP90) s; missed < \(pct(t.bargeInMissRate))",
                          value: m.bargeIns == 0 ? "no barge-ins scripted" : "\(m.bargeIns) scripted, none applicable (Dee's reply had ended)",
                          n: 0, status: m.bargeIns == 0 ? .skip : .fail))
        } else {
            let ok = (m.bargeInP90 ?? .infinity) <= t.bargeInP90 && (m.bargeInMissRate ?? 1) < t.bargeInMissRate
            g.append(Gate(id: "barge_in", metric: "Barge-in: user onset → Dee audio stopped; misses",
                          target: "p90 ≤ \(t.bargeInP90) s; missed < \(pct(t.bargeInMissRate))",
                          value: "p50 \(s(m.bargeInP50)) s, p90 \(s(m.bargeInP90)) s; missed \(m.bargeInsMissed)/\(m.bargeInsApplicable)",
                          n: m.bargeInsApplicable, status: ok ? .pass : .fail,
                          note: ([m.bargeIns > m.bargeInsApplicable ? "\(m.bargeIns - m.bargeInsApplicable) not applicable" : nil,
                                  m.backchannels > 0 ? "backchannels scored separately" : nil].compactMap { $0 })
                                .joined(separator: "; ").nilIfEmpty))
        }

        // 4b. Backchannels: "keep going" / "go on" / "mm-hm" said over Dee are not
        // barge-ins (user decision, tune 2): Dee keeps talking.
        let bcRate = m.backchannelsApplicable > 0 ? Double(m.backchannelStops) / Double(m.backchannelsApplicable) : nil
        g.append(Gate(id: "backchannel", metric: "Backchannel over Dee (keep going / go on / mm-hm): Dee keeps talking",
                      target: "stopped < \(pct(t.backchannelStopRate))",
                      value: m.backchannels == 0 ? "no backchannels scripted"
                          : "stopped \(m.backchannelStops)/\(m.backchannelsApplicable) (\(pct(bcRate))); heard as a user item \(m.backchannelsHeard)/\(m.backchannels)",
                      n: m.backchannelsApplicable,
                      status: m.backchannelsApplicable == 0 ? (m.backchannels == 0 ? .skip : .fail)
                          : ((bcRate ?? 1) < t.backchannelStopRate ? .pass : .fail),
                      note: ([m.backchannels > m.backchannelsApplicable ? "\(m.backchannels - m.backchannelsApplicable) not applicable (Dee's reply had ended)" : nil,
                              m.backchannelStopList.isEmpty ? nil : "stopped on: " + m.backchannelStopList.joined(separator: ", "),
                              m.backchannelCapEnds.isEmpty ? nil : "continued, then ended at Dee's sentence cap: " + m.backchannelCapEnds.joined(separator: ", ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))

        // 4b'. Calm: Dee's floor decisions over Dee's own reply.
        g += calmGates(m, t)

        // 4c. Tune 5: a question asked over Dee (content barge-in): Dee stops AND
        // answers it, starting within the latency gate (`Metrics.interruptAnswerWithin`).
        let iqMetric = "Interrupting questions answered: Dee stops and answers a question asked over Dee"
        let iqTarget = "\(pct(t.interruptAnswered)), each answer ≤ \(Metrics.interruptAnswerWithin) s after their end of speech"
        let iqScripted = m.interruptQuestions.count
        if m.interruptQuestionsApplicable == 0 {
            g.append(Gate(id: "interrupt_questions", metric: iqMetric, target: iqTarget,
                          value: iqScripted == 0 ? "no interrupting questions scripted" : "\(iqScripted) scripted, none applicable (Dee's reply had ended)",
                          n: 0, status: iqScripted == 0 ? .skip : .fail))
        } else {
            let rate = Double(m.interruptQuestionsAnswered) / Double(m.interruptQuestionsApplicable)
            let misses = m.interruptQuestions.filter { $0.applicable && !$0.answered }
                .map { "\($0.scenario):\($0.fixture) \($0.miss ?? "missed")" }
            let na = m.interruptQuestions.filter { !$0.applicable }.count
            g.append(Gate(id: "interrupt_questions", metric: iqMetric, target: iqTarget,
                          value: "\(pct(rate)) (\(m.interruptQuestionsAnswered)/\(m.interruptQuestionsApplicable)); answer p50 \(s(m.interruptAnswerP50)) s, p90 \(s(m.interruptAnswerP90)) s",
                          n: m.interruptQuestionsApplicable,
                          status: rate >= t.interruptAnswered ? .pass : .fail,
                          note: ([na > 0 ? "\(na) not applicable (Dee's reply had ended)" : nil,
                                  misses.isEmpty ? nil : "missed: " + misses.prefix(12).joined(separator: "; ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))
        }

        // 5. Self-trigger on echo.
        g.append(Gate(id: "self_trigger", metric: "Self-trigger on own echo (echo-only segments)", target: "0",
                      value: "\(m.selfTriggers)", n: m.echoSegments,
                      status: m.echoSegments == 0 ? (m.echoSegmentsNotSpoken > 0 ? .fail : .skip) : (m.selfTriggers == 0 ? .pass : .fail),
                      note: m.echoSegmentsNotSpoken > 0 ? "\(m.echoSegmentsNotSpoken) echo-only line(s) never played (initiative refused)" : nil))

        // 6. Truncation.
        let truncOK = m.truncationsAccurate == m.truncations.count && m.historyMatched == m.historyChecked
        g.append(Gate(id: "truncation", metric: "Truncated history = audio actually played",
                      target: "100% (±1 buffer)",
                      value: "\(m.truncationsAccurate)/\(m.truncations.count) audio_end_ms; history \(m.historyMatched)/\(m.historyChecked)",
                      n: m.truncations.count, status: m.truncations.isEmpty ? .skip : (truncOK ? .pass : .fail)))

        // 7. Leaks.
        // 0.6 §6: scored on what Dee said aloud (`Metrics.spokenText`); unheard text is information.
        let unspoken = m.leaksUnspoken.isEmpty ? nil
            : "spoken text only; unspoken (not counted): \(m.leaksUnspoken.count) — "
              + m.leaksUnspoken.prefix(4).map { "\($0.scenario): \($0.text.prefix(40))" }.joined(separator: "; ")
        g.append(Gate(id: "leaks", metric: "Leaks in what Dee said aloud (<dee_state>, DNA, [tags], hex, \"as an AI\")",
                      target: "0", value: "\(m.leaks.count)", n: m.replies,
                      status: m.leaks.isEmpty ? .pass : .fail, note: unspoken))

        // 7b. Narration of Dee's own process (DNA §3: no preamble; tools are silent).
        g.append(Gate(id: "narration", metric: "Narrated process said aloud (\"let me respond\", \"let me check what I remember\")",
                      target: "0", value: "\(m.narrations.count)", n: m.replies,
                      status: m.narrations.isEmpty ? .pass : .fail,
                      note: m.narrations.isEmpty ? unspoken : m.narrations.prefix(6).map { "\($0.scenario): \($0.text.prefix(60))" }.joined(separator: "; ")))

        // 8. Reply length.
        g.append(Gate(id: "reply_length", metric: "Reply length ≤ 3 sentences", target: "≥ \(pct(t.replyWithinThree)) of replies",
                      value: "\(pct(m.replyLengthRate)) (\(m.repliesWithinThree)/\(m.replies))", n: m.replies,
                      status: m.replies == 0 ? .skip : ((m.replyLengthRate ?? 0) >= t.replyWithinThree ? .pass : .fail),
                      note: m.replies == 0 ? nil
                          : "heard ≤ 3: \(m.repliesHeardWithinThree)/\(m.repliesHeard); unplayed (not counted): \(m.repliesUnplayed)"))

        // 9. Memory.
        let memRate = m.memoryProbes > 0 ? Double(m.memoryHits) / Double(m.memoryProbes) : nil
        g.append(Gate(id: "memory", metric: "Memory: fact given in session → used when asked", target: "≥ \(pct(t.memory))",
                      value: m.memoryProbes == 0 ? "no probes scripted" : "\(pct(memRate)) (\(m.memoryHits)/\(m.memoryProbes))",
                      n: m.memoryProbes,
                      status: m.memoryProbes == 0 ? .skip : ((memRate ?? 0) >= t.memory ? .pass : .fail),
                      note: m.memoryMisses.isEmpty ? nil : "missed: " + m.memoryMisses.joined(separator: ", ")))

        // 9b. Follow-ups on a plan's day, and reunions after a long time apart (DNA).
        let fuRate = m.followupProbes > 0 ? Double(m.followupHits) / Double(m.followupProbes) : nil
        g.append(Gate(id: "followups", metric: "A dated plan followed up on its day; a reunion after > 24 h acknowledged",
                      target: "\(pct(t.followups))",
                      value: m.followupProbes == 0 ? "no probes scripted" : "\(pct(fuRate)) (\(m.followupHits)/\(m.followupProbes))",
                      n: m.followupProbes,
                      status: m.followupProbes == 0 ? .skip : ((fuRate ?? 0) >= t.followups ? .pass : .fail),
                      note: ([m.followupMisses.isEmpty ? nil : "missed: " + m.followupMisses.joined(separator: ", "),
                              m.elapsedAsNumber.isEmpty ? nil : "time apart as a number (decision: words): " + m.elapsedAsNumber.joined(separator: ", ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))

        // 9c. No hurt after floor control ("stop talking for a second", "Stop.").
        g.append(Gate(id: "forbidden", metric: "Replies free of phrases the scenario forbids (no hurt after a polite stop)",
                      target: "0", value: m.forbiddenChecked == 0 ? "nothing checked" : "\(m.forbiddenHits.count)/\(m.forbiddenChecked)",
                      n: m.forbiddenChecked,
                      status: m.forbiddenChecked == 0 ? .skip : (m.forbiddenHits.isEmpty ? .pass : .fail),
                      note: m.forbiddenHits.isEmpty ? nil : m.forbiddenHits.prefix(8).joined(separator: "; ")))

        // 10. Initiative collisions.
        g.append(Gate(id: "collisions", metric: "Collisions (Dee starts while the user is talking)", target: "0",
                      value: "\(m.collisions.count)", n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : (m.collisions.isEmpty ? .pass : .fail)))

        // 11. Rollover / reconnect / 429.
        let disrupted = m.faults + m.rollovers
        if disrupted == 0 {
            g.append(Gate(id: "fallback", metric: "Session rollover / reconnect / 429 → fallback without losing a turn",
                          target: "100% in scripted tests", value: "no faults or rollovers in this run", n: 0, status: .skip,
                          note: "scripted in Scenarios/fallback.json (drop, 401, 429, short secret, rollover)"))
        } else {
            let ok = m.faultsRecovered == m.faults && m.turnsLostAfterDisruption == 0
            g.append(Gate(id: "fallback", metric: "Session rollover / reconnect / 429 → fallback without losing a turn",
                          target: "100% in scripted tests",
                          value: "faults recovered \(m.faultsRecovered)/\(m.faults) (max \(s(m.recoveryTimes.max())) s), rollovers \(m.rollovers); turns lost after \(m.turnsLostAfterDisruption)/\(m.turnsAfterDisruption)",
                          n: disrupted, status: ok ? .pass : .fail,
                          note: m.lostAfterDisruption.isEmpty ? nil : m.lostAfterDisruption.joined(separator: ", ")))
        }

        // 12. Every response carries the current DNA (real brain).
        if m.dnaRunsChecked == 0 {
            g.append(Gate(id: "dna", metric: "Every in-band response has a live DEE DNA", target: "100%",
                          value: "no DNA in this run (minimal brain)", n: 0, status: .skip))
        } else {
            g.append(Gate(id: "dna", metric: "Every in-band response has a live DEE DNA", target: "100%",
                          value: "\(m.inBandWithDNA)/\(m.inBandResponses) (fresh render on \(m.freshDNARequests))",
                          n: m.inBandResponses, status: m.inBandWithDNA == m.inBandResponses ? .pass : .fail,
                          note: m.withoutDNA.isEmpty ? nil : m.withoutDNA.prefix(6).joined(separator: "; ")))
        }

        // 13. LLM judge (docs/DNA.md §5.6 step 3).
        if let j = judge, !j.scores.isEmpty {
            let lowFamilies = j.familyMeans.filter { $0.value < Judge.familyFloor }.keys.sorted()
            let ok = (j.mean ?? 0) >= t.judgeMean && j.leaks == 0 && m.leaks.isEmpty
            let fam = j.familyMeans.sorted { $0.key < $1.key }.map { "\($0.key) \(s($0.value))" }.joined(separator: ", ")
            g.append(Gate(id: "judge", metric: "LLM judge vs the DNA state rubric (fits state, no leaks, short, no grovelling, laughs at jokes, no guilt)",
                          target: "mean ≥ \(t.judgeMean); leaks 0",
                          value: "mean \(s(j.mean)) (\(fam)); leaks \(j.leaks) (dismissed \(j.leaksDismissed ?? 0)); fits \(j.fitsState)/\(j.scores.count); grovel \(j.grovels); guilt \(j.guilt); laughed \(j.laughed)/\(j.jokes)",
                          n: j.scores.count, status: ok ? .pass : .fail,
                          note: ([lowFamilies.isEmpty ? nil : "families below \(Judge.familyFloor): \(lowFamilies.joined(separator: ", "))",
                                  j.failures.isEmpty ? nil : "\(j.failures.count) not scored",
                                  (j.unspokenDropped ?? 0) == 0 ? nil : "\(j.unspokenDropped!) verdicts on unheard replies dropped",
                                  "\(j.model)"].compactMap { $0 }).joined(separator: "; ")))
        } else {
            g.append(Gate(id: "judge", metric: "LLM judge vs the DNA state rubric", target: "mean ≥ \(t.judgeMean); leaks 0",
                          value: judge == nil ? "not run (--judge)" : "nothing to score", n: 0, status: .skip))
        }
        // 0.6: the run's wake mode, asserted (always-open = never DORMANT: the tune2 baseline).
        if !m.wakeModes.isEmpty {
            let modes = m.wakeModes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            g.append(Gate(id: "wake_mode", metric: "Wake mode asserted (always-open runs never go DORMANT)", target: "0 violations",
                          value: "\(modes); violations \(m.alwaysOpenViolations.count)", n: m.wakeModes.values.reduce(0, +),
                          status: m.alwaysOpenViolations.isEmpty ? .pass : .fail,
                          note: m.alwaysOpenViolations.isEmpty ? nil : m.alwaysOpenViolations.joined(separator: ", ")))
        }
        return g
    }

    public static func anyFailed(_ gates: [Gate]) -> Bool { gates.contains { $0.status == .fail } }

    static func approximateNote(_ m: Metrics) -> String? {
        m.floorApproximateRuns.isEmpty ? nil
            : "approximate for \(m.floorApproximateRuns.count) run(s) without timed notes (hold ≈ onset + \(Metrics.approximateHoldAfter) s, no ducks)"
    }

    /// Calm (D1): `barge_in` = onset → Dee audibly gives way (a dip or a pause).
    static func yieldGate(_ m: Metrics, _ t: Thresholds) -> Gate {
        let metric = "Barge-in: user onset → Dee gives way (dip or pause); missed = no yield within \(Metrics.bargeMissAfter) s"
        let target = "p90 ≤ \(t.yieldP90) s; missed < \(pct(t.bargeInMissRate))"
        guard m.yieldApplicable > 0 else {
            return Gate(id: "barge_in", metric: metric, target: target,
                        value: m.bargeIns == 0 ? "no barge-ins scripted" : "\(m.bargeIns) scripted, none applicable (Dee's reply had ended)",
                        n: 0, status: m.bargeIns == 0 ? .skip : .fail)
        }
        let ok = (m.yieldP90 ?? .infinity) <= t.yieldP90 + 1e-9 && (m.yieldMissRate ?? 1) < t.bargeInMissRate
        return Gate(id: "barge_in", metric: metric, target: target,
                    value: "p50 \(s(m.yieldP50)) s, p90 \(s(m.yieldP90)) s; missed \(m.yieldMissed)/\(m.yieldApplicable)",
                    n: m.yieldApplicable, status: ok ? .pass : .fail,
                    note: ([m.bargeIns > m.bargeInsApplicable ? "\(m.bargeIns - m.bargeInsApplicable) not applicable" : nil,
                            m.yieldMissList.isEmpty ? nil : "missed: " + m.yieldMissList.prefix(8).joined(separator: ", "),
                            "silent: see `silence`", approximateNote(m)].compactMap { $0 }).joined(separator: "; ").nilIfEmpty)
    }

    /// Calm: `false_pause`, `false_pause_long`, `false_barge`, `silence`, `duck_time`.
    static func calmGates(_ m: Metrics, _ t: Thresholds) -> [Gate] {
        var g: [Gate] = []
        let approx = approximateNote(m)

        // False pauses: a short sound or a continuer over Dee must never silence Dee.
        let fpMetric = "Short sounds (cough, breath, laugh, hmm) and single-clause continuers over Dee: an audible pause (≥ \(Metrics.audiblePause) s) or a stop in [onset − \(Metrics.floorLead) s, EoS + \(Metrics.falsePauseTail) s]"
        let fpTarget = "≤ \(pct(t.falsePauseRate)), pooled n ≥ \(t.falsePauseMinN); 0 stops on a sound"
        if m.falsePauseEvents == 0 {
            g.append(Gate(id: "false_pause", metric: fpMetric, target: fpTarget, value: "no short sounds or continuers scripted",
                          n: 0, status: .skip))
        } else {
            let n = m.falsePauseApplicable
            let rate = n > 0 ? Double(m.falsePauses) / Double(n) : nil
            let rateOK = (rate ?? 1) <= t.falsePauseRate + 1e-9
            let status: Gate.Status = n == 0 || m.falsePauseSoundStops > 0 || !rateOK ? .fail
                : (n >= t.falsePauseMinN ? .pass : .skip)
            g.append(Gate(id: "false_pause", metric: fpMetric, target: fpTarget,
                          value: "\(pct(rate)) (\(m.falsePauses)/\(n)); stops \(m.falsePauseStops) (on sounds \(m.falsePauseSoundStops))",
                          n: n, status: status,
                          note: ([n == 0 ? "none applicable (Dee's reply had ended)" : nil,
                                  m.falsePauseEvents > n ? "\(m.falsePauseEvents - n) not applicable" : nil,
                                  status == .skip ? "under-powered (n < \(t.falsePauseMinN)): not a pass; pool runs" : nil,
                                  m.falsePauseList.isEmpty ? nil : "paused / stopped: " + m.falsePauseList.prefix(12).joined(separator: ", "),
                                  m.ownCapEnds.isEmpty ? nil : "Dee's own cap end, carried on: " + m.ownCapEnds.prefix(8).joined(separator: ", "),
                                  m.answeredAfterOwnCap.isEmpty ? nil : "answered after Dee's own cap end: " + m.answeredAfterOwnCap.prefix(8).joined(separator: ", "),
                                  m.soundsHeardAsWords.isEmpty ? nil : "sound fixtures heard as WORDS (re-render): " + m.soundsHeardAsWords.prefix(8).joined(separator: ", "),
                                  approx].compactMap { $0 }).joined(separator: "; ").nilIfEmpty))
        }

        // Long sounds (a laughing / coughing fit): never a stop; pauses reported.
        let longMetric = "Long sounds over Dee (laughing / coughing fit): stops; pause rate and length (information)"
        if m.longSoundApplicable == 0 {
            g.append(Gate(id: "false_pause_long", metric: longMetric, target: "0 stops", value: "no long sounds over Dee", n: 0, status: .skip))
        } else {
            let mean = m.longSoundPauseSeconds.isEmpty ? nil : m.longSoundPauseSeconds.reduce(0, +) / Double(m.longSoundPauseSeconds.count)
            g.append(Gate(id: "false_pause_long", metric: longMetric, target: "0 stops",
                          value: "stops \(m.longSoundStops)/\(m.longSoundApplicable); paused \(m.longSoundPauses)/\(m.longSoundApplicable), mean pause \(s(mean)) s",
                          n: m.longSoundApplicable, status: m.longSoundStops == 0 ? .pass : .fail,
                          note: ([m.longSoundList.isEmpty ? nil : m.longSoundList.joined(separator: ", "), approx].compactMap { $0 })
                                .joined(separator: "; ").nilIfEmpty))
        }

        // False barges: Dee paused / cut / ducked with nobody scripted talking.
        let fbMetric = "Pauses / cuts while Dee talks with no scripted user audio within ±\(Metrics.falseBargeMargin) s, per 10 Dee-talking minutes and condition (ducks per minute reported)"
        let tvNames = (t.falseBargeTVConditions.sorted() + (t.falseBargeTVPrefix.map { ["\($0)…"] } ?? [])).joined(separator: "/")
        let fbTarget = "0 stops; pauses ≤ \(s(t.falseBargePer10, 0)) per 10 Dee-min (TV rooms \(tvNames): ≤ \(s(t.falseBargeTVPer10, 0)))"
        let conds = m.falseBarge.filter { $0.value.deeMinutes > 0 }.sorted { $0.key < $1.key }
        if conds.isEmpty {
            g.append(Gate(id: "false_barge", metric: fbMetric, target: fbTarget,
                          value: m.falseBarge.isEmpty ? "no timed notes (reports before calm)" : "Dee never talked", n: 0, status: .skip,
                          note: approx))
        } else {
            var ok = true
            let parts = conds.map { c, v -> String in
                let bound = t.isTVCondition(c) ? t.falseBargeTVPer10 : t.falseBargePer10
                if v.stops > 0 || (v.pausesPer10 ?? 0) > bound + 1e-9 { ok = false }
                return String(format: "%@ %d pause / %d cut in %.1f Dee-min (%.1f per 10), ducks %.1f/min", c, v.pauses, v.stops,
                              v.deeMinutes, v.pausesPer10 ?? 0, v.ducksPerMinute ?? 0)
            }
            let list = conds.flatMap(\.value.list)
            g.append(Gate(id: "false_barge", metric: fbMetric, target: fbTarget, value: parts.joined(separator: "; "),
                          n: conds.reduce(0) { $0 + $1.value.pauses + $1.value.stops }, status: ok ? .pass : .fail,
                          note: ([list.isEmpty ? nil : list.prefix(10).joined(separator: "; "), approx].compactMap { $0 })
                                .joined(separator: "; ").nilIfEmpty))
        }

        // Silence: Dee fully silent for real interruptions. Round 2 (D1): bounded from
        // the end of the stop / command phrase; other interruptions are reported.
        let siMetric = t.silenceFromOnset
            ? "Onset → Dee fully silent: multi-word interruptions (c03 c04 c06 c07, questions), lone stop words (c01 c08); stop / command fixtures end the reply"
            : "End of the stop / command phrase → Dee fully silent (c01 c03 c04 c06 c07 c08); other interruptions onset → silent (information); stop / command fixtures end the reply"
        let siTarget = t.silenceFromOnset
            ? "multi p90 ≤ \(t.silenceMultiP90) s; lone p90 ≤ \(t.silenceLoneP90) s; \(pct(t.stopCommandsEnded)) of stop / command fixtures silent for good ≤ \(Metrics.stopEndWithin) s after onset"
            : "stop phrase p90 ≤ \(t.stopWordSilenceP90) s; \(pct(t.stopCommandsEnded)) of stop / command fixtures silent for good ≤ \(Metrics.stopEndWithin) s after the stop phrase"
        if m.silenceMulti.isEmpty && m.silenceLone.isEmpty && m.stopCommands == 0 && m.silenceStopWord.isEmpty {
            g.append(Gate(id: "silence", metric: siMetric, target: siTarget,
                          value: m.yieldApplicable == 0 ? "no interruptions over Dee" : "no interruption made Dee silent", n: 0,
                          status: m.yieldApplicable == 0 ? .skip : .fail))
        } else {
            let endRate = m.stopCommands > 0 ? Double(m.stopCommandsEnded) / Double(m.stopCommands) : nil
            let ended = (endRate ?? 1) >= t.stopCommandsEnded - 1e-9
            let ok: Bool
            let value: String
            let n: Int
            if t.silenceFromOnset {
                ok = (m.silenceMulti.isEmpty || (m.silenceMultiP90 ?? .infinity) <= t.silenceMultiP90 + 1e-9)
                    && (m.silenceLone.isEmpty || (m.silenceLoneP90 ?? .infinity) <= t.silenceLoneP90 + 1e-9) && ended
                value = "multi p90 \(s(m.silenceMultiP90)) s (n=\(m.silenceMulti.count)); lone p90 \(s(m.silenceLoneP90)) s (n=\(m.silenceLone.count)); ended \(m.stopCommandsEnded)/\(m.stopCommands)"
                n = m.silenceMulti.count + m.silenceLone.count
            } else {
                // A stop fixture that never made Dee silent is a miss (counted as 99 s).
                let misses = m.silenceStopWordList.filter { $0.hasSuffix("(never silent)") }.count
                let samples = m.silenceStopWord + Array(repeating: 99.0, count: misses)
                let p90 = Stats.percentile(samples, 0.9)
                ok = (samples.isEmpty || (p90 ?? .infinity) <= t.stopWordSilenceP90 + 1e-9) && ended
                value = "stop phrase → silent p50 \(s(Stats.percentile(samples, 0.5))) s, p90 \(s(p90)) s (n=\(samples.count)); "
                    + "onset → silent: multi p90 \(s(m.silenceMultiP90)) s (n=\(m.silenceMulti.count)), lone p90 \(s(m.silenceLoneP90)) s (n=\(m.silenceLone.count)); "
                    + "ended \(m.stopCommandsEnded)/\(m.stopCommands)"
                n = samples.count
            }
            g.append(Gate(id: "silence", metric: siMetric, target: siTarget, value: value,
                          n: n, status: ok ? .pass : .fail,
                          note: ([m.stopCommandMisses.isEmpty ? nil : "not ended: " + m.stopCommandMisses.prefix(8).joined(separator: ", "),
                                  t.silenceFromOnset || m.silenceStopWordList.isEmpty ? nil
                                    : "stop phrase slow (> 1 s) or never silent: " + m.silenceStopWordList.prefix(8).joined(separator: ", "),
                                  m.silenceMissList.isEmpty ? nil : "not silent by the stop deadline (round 3: before the answer / ≤ 1.5 s after the stop phrase): " + m.silenceMissList.prefix(8).joined(separator: ", "),
                                  approx].compactMap { $0 }).joined(separator: "; ").nilIfEmpty))
        }

        // Duck time: how long Dee stays dipped for a short sound.
        if m.duckTimes.isEmpty {
            g.append(Gate(id: "duck_time", metric: "Duck → unduck for short sounds and continuers (information)",
                          target: "p90 ≤ \(t.duckTimeP90) s", value: "no ducks", n: 0, status: .skip))
        } else {
            g.append(Gate(id: "duck_time", metric: "Duck → unduck for short sounds and continuers (information)",
                          target: "p90 ≤ \(t.duckTimeP90) s",
                          value: "p50 \(s(Stats.percentile(m.duckTimes, 0.5))) s, p90 \(s(m.duckTimeP90)) s", n: m.duckTimes.count,
                          status: (m.duckTimeP90 ?? .infinity) <= t.duckTimeP90 + 1e-9 ? .pass : .fail))
        }

        // Round 3 (information): Dee answered the room (TV) with nobody talking and Dee
        // idle. Not a gate: with Dee idle there is no reply to duck (same as 0.6.0).
        if !m.idleSeconds.isEmpty {
            let tv = m.idleAnswers.filter { t.isTVCondition($0.condition) }
            let tvIdle = m.idleSeconds.filter { t.isTVCondition($0.key) }.values.reduce(0, +) / 60
            let byCond = Dictionary(grouping: m.idleAnswers, by: \.condition).sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value.count)" }
            let rate = tvIdle > 0 ? String(format: " (%.1f per 10 idle min)", Double(tv.count) / tvIdle * 10) : ""
            g.append(Gate(id: "idle_tv_answers",
                          metric: "Dee answered the TV while idle: phantom user turns (no scripted audio) answered while Dee was not talking (information)",
                          target: "information (0 wanted)",
                          value: String(format: "TV rooms %d in %.1f idle min", tv.count, tvIdle) + rate
                            + "; all rooms \(m.idleAnswers.count)" + (byCond.isEmpty ? "" : " (" + byCond.joined(separator: ", ") + ")"),
                          n: tv.count, status: .info,
                          note: tv.isEmpty ? nil : tv.prefix(10).map { String(format: "%@ %.2f s «%@»", $0.scenario, $0.at, $0.transcript ?? "–") }
                            .joined(separator: "; ")))
        }
        return g
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
