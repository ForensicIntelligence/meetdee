import DeeRealtime
import DeeWake
import Foundation
import HarnessCore
import HarnessRunner

// voice-harness — Dee's live voice loopback harness. See Tools/voice-harness/README.md.
//
//   voice-harness fixtures [--force] [--only q01,l01] [--max-usd 0.5]
//   voice-harness suite    [--write]                      (regenerates Scenarios/{full,dna,fallback,smoke-brain}.json)
//   voice-harness validate --scenarios Scenarios/smoke.json
//   voice-harness run      --scenarios Scenarios/smoke.json [--brain realtime|minimal] [--model gpt-realtime-2.1-mini]
//                          [--max-usd 2.00] [--only name,name] [--audio DIR] [--no-sound-classifier] [--quiet]
//                          [--judge] [--judge-model gpt-4.1-mini] [--judge-max-usd 0.50] [--state DIR] [--over-projection]
//   voice-harness replay   --trace Traces/<run>/<scenario>.jsonl [--scenarios FILE]
//   voice-harness gates    --report Reports/<run>/report.json [--write]
//   (run / replay / gates / judge: [--baseline Reports/<run>/report.json | --no-baseline], default tune 7)
//   voice-harness judge    --report Reports/<run>/report.json [--judge-model M] [--write]
//   voice-harness pool     --reports Reports/<runA>,Reports/<runB>[,…]   (gates on pooled counts; offline)
//
// Exit codes: 0 all gates pass · 1 a gate failed · 2 usage / setup error · 3 aborted (spend cap, no connection).

/// The tool's own directory (this file is Sources/voice-harness/main.swift).
let toolRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func stderr(_ s: String) { FileHandle.standardError.write(Data((Redact.secrets(s) + "\n").utf8)) }

struct Args {
    var command: String
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ argv: [String]) {
        command = argv.dropFirst().first ?? "help"
        var i = 2
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { flags[name] = argv[i + 1]; i += 2 }
                else { switches.insert(name); i += 1 }
            } else { i += 1 }
        }
    }

    func url(_ name: String, default d: String) -> URL {
        let p = flags[name] ?? d
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : toolRoot.appendingPathComponent(p)
    }

    func double(_ name: String, default d: Double) -> Double { flags[name].flatMap(Double.init) ?? d }
    func list(_ name: String) -> Set<String>? { flags[name].map { Set($0.split(separator: ",").map(String.init)) } }
}

let args = Args(CommandLine.arguments)

/// The parts of a stored report that `gates` re-evaluates.
struct StoredReport: Decodable {
    var runID: String
    var started: String
    var model: String
    var brain: String
    var maxUSD: Double
    var aborted: String?
    var runs: [RunRecord]
    var judge: Judge.Summary?
}

func runID() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = TimeZone.current
    return f.string(from: Date())
}

func loadScenarios(_ args: Args, library: FixtureLibrary) throws -> [Scenario] {
    let file = try ScenarioFile.load(args.url("scenarios", default: "Scenarios/smoke.json"))
    var list = file.scenarios
    if let only = args.list("only") { list = list.filter { only.contains($0.name) } }
    let issues = list.flatMap { $0.validate(against: library.manifest) }
    if !issues.isEmpty { throw HarnessError(issues.joined(separator: "\n")) }
    return list
}

/// Tune 10: the run every report is compared against for regressions — tune 7, the
/// best so far (16/20). `--baseline FILE` picks another; `--no-baseline` skips it.
let defaultBaseline = "Reports/20261010-063215/report.json"

func loadBaseline() -> StoredReport? {
    guard !args.switches.contains("no-baseline") else { return nil }
    let url = args.url("baseline", default: defaultBaseline)
    do {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(StoredReport.self, from: Data(contentsOf: url))
    } catch {
        stderr("baseline \(url.lastPathComponent) not read (\(error.localizedDescription)): no regressions section")
        return nil
    }
}

func evaluate(_ runs: [RunRecord], model: String, brain: String, maxUSD: Double, started: String, id: String,
              aborted: String?, judge: Judge.Summary? = nil) -> HarnessReport {
    let metrics = Metrics.compute(runs, pricing: Pricing.forModel(model))
    // Stored verdicts get the tune-2 leak check too (judge false positives).
    var judge = judge
    judge?.rescore(runs, metrics: metrics)
    let gates = Gates.evaluate(metrics, judge: judge)
    var regressions: Regressions?
    if let base = loadBaseline(), base.runID != id {
        var baseJudge = base.judge
        let baseMetrics = Metrics.compute(base.runs, pricing: Pricing.forModel(base.model))
        baseJudge?.rescore(base.runs, metrics: baseMetrics)
        regressions = Regressions.compare(current: metrics, judge: judge,
                                          baseline: baseMetrics,
                                          baselineJudge: baseJudge, baselineID: base.runID)
    }
    return HarnessReport(runID: id, started: started, finished: ISO8601DateFormatter().string(from: Date()),
                         model: model, brain: brain, maxUSD: maxUSD, aborted: aborted, gates: gates,
                         metrics: metrics, runs: runs, judge: judge, regressions: regressions)
}

/// The LLM judge over a run's replies (needs the key; a few cents).
func runJudge(_ runs: [RunRecord], model: String, maxUSD: Double, log: @escaping @Sendable (String) -> Void) async throws -> Judge.Summary {
    let metrics = Metrics.compute(runs, pricing: Pricing.forModel("gpt-realtime-2.1-mini"))
    let items = Judge.items(runs, metrics: metrics)
    log("judge: \(items.count) replies with \(model)")
    let client = JudgeClient(model: model, key: try KeyFile.load())
    let summary = await client.judge(items, maxUSD: maxUSD, log: log)
    log(String(format: "judge: mean %@ over %d, leaks %d, $%.4f", summary.mean.map { String(format: "%.2f", $0) } ?? "–",
               summary.scores.count, summary.leaks, Judge.dollars(summary)))
    return summary
}

func writeReport(_ report: HarnessReport, to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try report.json().write(to: dir.appendingPathComponent("report.json"), options: .atomic)
    try Data(report.markdown().utf8).write(to: dir.appendingPathComponent("report.md"), options: .atomic)
}

func printGates(_ report: HarnessReport) {
    for g in report.gates {
        print(String(format: "%-5@ %-14@ %@  (target %@, n=%d)", g.status.rawValue, g.id, g.value, g.target, g.n))
    }
    if let rg = report.regressions {
        print("regressions vs \(rg.baseline): \(rg.regressions.count) of \(rg.baselineCorrect) (fixed \(rg.fixed))"
              + rg.regressions.prefix(12).map { "\n  \($0.scenario):\($0.fixture) — \($0.problems.joined(separator: "; "))" }.joined())
    }
    print(String(format: "spend ≈ $%.4f · verdict %@", report.metrics.cost.total, report.failed ? "FAIL" : "PASS"))
}

func main() async -> Int32 {
    let quiet = args.switches.contains("quiet")
    let logger: @Sendable (String) -> Void = { s in if !quiet { print(Redact.secrets(s)); fflush(stdout) } }
    do {
        switch args.command {
        case "fixtures":
            let gen = FixtureGenerator(root: toolRoot, force: args.switches.contains("force"), only: args.list("only"),
                                       maxUSD: args.double("max-usd", default: 0.50), log: { logger($0) })
            try await gen.run()
            return 0

        case "suite":
            let files: [(String, [Scenario])] = [("full.json", Suite.full()), ("dna.json", Suite.dna()),
                                                 ("fallback.json", Suite.fallback()), ("smoke-brain.json", Suite.smokeBrain()),
                                                 ("tune2.json", Suite.tune2()), ("wake.json", WakeSuite.liveScenarios())]
            let core = Set(FixtureCatalog.core.map(\.id))
            for c in Suite.conditions {
                let used = Set(Suite.acoustic().filter { $0.name.hasSuffix("-\(c.id)") }.flatMap(\.fixtureIDs))
                print("\(c.id): \(core.intersection(used).count)/\(core.count) core fixtures")
            }
            for (name, list) in files {
                print("\(name): \(list.count) scenarios, \(list.reduce(0) { $0 + $1.userUtteranceCount }) utterances")
                if args.switches.contains("write") {
                    let e = JSONEncoder()
                    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    try e.encode(ScenarioFile(scenarios: list)).write(to: toolRoot.appendingPathComponent("Scenarios/\(name)"))
                }
            }
            return 0

        case "judge":
            guard args.flags["report"] != nil else { throw HarnessError("judge needs --report FILE") }
            let url = args.url("report", default: "")
            let d = JSONDecoder()
            d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let old = try d.decode(StoredReport.self, from: Data(contentsOf: url))
            let summary = try await runJudge(old.runs, model: args.flags["judge-model"] ?? Judge.defaultModel,
                                             maxUSD: args.double("judge-max-usd", default: 0.50), log: logger)
            let report = evaluate(old.runs, model: old.model, brain: old.brain, maxUSD: old.maxUSD, started: old.started,
                                  id: old.runID, aborted: old.aborted, judge: summary)
            printGates(report)
            if args.switches.contains("write") {
                try writeReport(report, to: url.deletingLastPathComponent())
                print("rewrote report.md / report.json")
            }
            return report.failed ? 1 : 0

        case "validate":
            let library = try FixtureLibrary(directory: args.url("fixtures", default: "Fixtures"))
            let scenarios = try loadScenarios(args, library: library)
            let pricing = Pricing.forModel(args.flags["model"] ?? "gpt-realtime-2.1-mini")
            var total = 0.0, utterances = 0, seconds = 0.0
            for s in scenarios {
                let userSeconds = s.fixtureIDs.compactMap { library.manifest.utterance($0)?.speechSeconds }.reduce(0, +)
                let replies = s.userUtteranceCount + s.echoOnlyCount
                let p = pricing.projected(replies: replies, userSeconds: userSeconds)
                let t = RunEstimate.seconds(s, manifest: library.manifest)
                total += p
                seconds += t
                utterances += s.userUtteranceCount
                print(String(format: "%@: %d utterances, %d barge-ins, %d echo-only, %d faults, projected ≈ $%.3f, ≈ %.1f min",
                             s.name, s.userUtteranceCount, s.bargeInCount, s.echoOnlyCount, s.faultCount, p, t / 60))
            }
            print(String(format: "total: %d scenarios, %d utterances, projected ≈ $%.2f (live ≈ $%.2f at the tune-1 ratio %.2f) + judge ≈ $%.2f with %@; ≈ %.0f min",
                         scenarios.count, utterances, total, total * RunEstimate.liveOverProjection, RunEstimate.liveOverProjection,
                         Double(utterances) * 0.0005, Judge.defaultModel, seconds / 60))
            return 0

        case "run", "replay":
            let library = try FixtureLibrary(directory: args.url("fixtures", default: "Fixtures"))
            let model = args.flags["model"] ?? "gpt-realtime-2.1-mini"
            let brainName = args.flags["brain"] ?? (args.command == "replay" ? "minimal" : "realtime")
            let maxUSD = args.double("max-usd", default: 2.00)
            let pricing = Pricing.forModel(model)
            let id = (args.command == "replay" ? "replay-" : "") + runID()
            let started = ISO8601DateFormatter().string(from: Date())

            // 0.6: the wake mode is explicit on `run` (the tune2 baseline is `always-open`).
            let wakeMode: WakeMode
            if let w = args.flags["wake"] {
                guard let m = WakeMode(rawValue: w) else { throw HarnessError("--wake must be always-open or phrase") }
                wakeMode = m
            } else if args.command == "replay" {
                wakeMode = .alwaysOpen
            } else {
                throw HarnessError("run needs --wake always-open (the tune2 baseline) or --wake phrase (Scenarios/wake.json)")
            }
            let providerName = args.flags["provider"] ?? "openai"
            var scenarios: [Scenario]
            var connection: HarnessConnection
            var replayServer: TraceReplayServer?
            var traceDir: URL?
            if args.command == "replay" {
                guard let tracePath = args.flags["trace"] else { throw HarnessError("replay needs --trace FILE") }
                let traceURL = args.url("trace", default: tracePath)
                let entries = try TraceRecorder.load(traceURL)
                let scenarioName = traceURL.deletingPathExtension().lastPathComponent
                let scenarioFile = args.flags["scenarios"] != nil
                    ? args.url("scenarios", default: "")
                    : traceURL.deletingLastPathComponent().appendingPathComponent("scenarios.json")
                scenarios = try ScenarioFile.load(scenarioFile).scenarios.filter { $0.name == scenarioName }
                guard !scenarios.isEmpty else { throw HarnessError("scenario \(scenarioName) not in \(scenarioFile.path)") }
                let server = TraceReplayServer(entries: entries)
                let port = try await server.start()
                replayServer = server
                connection = .local(endpoint: URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!)
                logger("replaying \(entries.count) frames of \(traceURL.lastPathComponent) on port \(port)")
            } else {
                scenarios = try loadScenarios(args, library: library)
                let wrongMode = wakeMode.issues(scenarios)
                if !wrongMode.isEmpty { throw HarnessError(wrongMode.joined(separator: "\n")) }
                let projected = scenarios.reduce(0.0) { acc, s in
                    let userSeconds = s.fixtureIDs.compactMap { library.manifest.utterance($0)?.speechSeconds }.reduce(0, +)
                    return acc + pricing.projected(replies: s.userUtteranceCount + s.echoOnlyCount, userSeconds: userSeconds)
                }
                logger(String(format: "run %@: %d scenarios, projected ≈ $%.3f (cap $%.2f)", id, scenarios.count, projected, maxUSD))
                switch SpendPlan.check(projected: projected, cap: maxUSD,
                                       allowOverProjection: args.switches.contains("over-projection")) {
                case .go: break
                case .goOverProjection: logger("projection is over the cap: the live spend guard stops the run at the cap")
                case .refuse(let why): throw HarnessError(why)
                }
                // Checked once up front; each scenario gets its own RealtimeAuth below
                // (a cached ek_ secret is single-use: "ephemeral_token_already_used").
                switch providerName {
                case "openai":
                    _ = try KeyFile.load()
                    connection = .openAI(key: try KeyFile.load(), ttlSeconds: 600)
                case "lan-brain", "lan":
                    connection = .provider(try await LocalProviders.prepare(providerName, flags: args.flags, log: logger))
                default:
                    throw HarnessError("--provider must be openai, lan-brain or lan")
                }
                if args.switches.contains("judge") {
                    _ = try JudgeClient(model: args.flags["judge-model"] ?? Judge.defaultModel, key: KeyFile.load())
                }
                traceDir = args.url("traces", default: "Traces").appendingPathComponent(id)
                try FileManager.default.createDirectory(at: traceDir!, withIntermediateDirectories: true)
                // Keep the scenarios beside the traces so they can be replayed as run.
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try e.encode(ScenarioFile(scenarios: scenarios)).write(to: traceDir!.appendingPathComponent("scenarios.json"))
            }

            var wakeFailed = false
            var options = RunnerOptions()
            options.wake = wakeMode
            options.wakePhrase = args.flags["wake-phrase"] ?? WakeSuite.defaultPhrase
            options.model = model
            options.traceDirectory = traceDir
            options.audioDirectory = args.flags["audio"].map { URL(fileURLWithPath: $0).appendingPathComponent(id) }
            options.classifySounds = !args.switches.contains("no-sound-classifier")
            options.log = logger
            let spend = SpendGuard(pricing: pricing, maxUSD: maxUSD)
            let stateRoot = args.url("state", default: "/tmp/dee-harness-state").appendingPathComponent(id)
            var runs: [RunRecord] = []
            var aborted: String?
            for s in scenarios {
                if spend.exceeded { aborted = String(format: "spend cap: $%.4f > $%.2f", spend.spent, maxUSD); break }
                let brain = try BrainRegistry.make(brainName, scenario: s, stateRoot: stateRoot, voice: options.voice)
                logger("— scenario \(s.name) (\(s.userUtteranceCount) utterances, \(s.bargeInCount) barge-ins, \(s.echoOnlyCount) echo-only, \(s.faultCount) faults)")
                if case .live = connection {
                    connection = .live(KeyFile.auth(key: try KeyFile.load(), ttlSeconds: s.session?.secretTTL ?? 600))
                }
                if case .openAI = connection {
                    connection = .openAI(key: try KeyFile.load(), ttlSeconds: s.session?.secretTTL ?? 600)
                }
                let runner = ScenarioRunner(scenario: s, library: library, connection: connection, brain: brain,
                                            spend: spend, options: options)
                let r = await runner.run()
                runs.append(r)
                if let a = r.aborted { aborted = "\(s.name): \(a)"; if a.hasPrefix("spend cap") || a.hasPrefix("never connected") { break } }
            }
            replayServer?.stop()
            var judge: Judge.Summary?
            if args.switches.contains("judge"), args.command == "run", !runs.isEmpty {
                judge = try? await runJudge(runs, model: args.flags["judge-model"] ?? Judge.defaultModel,
                                            maxUSD: args.double("judge-max-usd", default: 0.50), log: logger)
            }
            let report = evaluate(runs, model: model, brain: brainName, maxUSD: maxUSD, started: started, id: id, aborted: aborted,
                                  judge: judge)
            let out = args.url("reports", default: "Reports").appendingPathComponent(id)
            try writeReport(report, to: out)
            printGates(report)
            if wakeMode == .phrase {
                // The live half of the wake suite: windows, latencies, W1/W2/W3 for this mode.
                var w = WakeReport(runID: id, started: started, finished: report.finished,
                                   engine: "live: on-device OnDeviceWakeEar + \(providerName)", pace: "realtime")
                let mode = LocalProviders.modeName(providerName)
                w.live = runs.map { WakeLive.result($0, metrics: report.metrics, mode: mode) }
                w.invariants = runs.map { WakeLive.invariant($0, mode: mode, allowedHosts: LocalProviders.allowedHosts(providerName, flags: args.flags)) }
                w.gates = WakeGates.evaluate(w)
                try w.json().write(to: out.appendingPathComponent("wake.json"), options: .atomic)
                try Data(WakeGates.markdown(w).utf8).write(to: out.appendingPathComponent("wake.md"), options: .atomic)
                for g in w.gates where g.status != .skip {
                    print(String(format: "%-5@ %-20@ %@", g.status.rawValue, g.id, g.value) + (g.note.map { "\n      \($0)" } ?? ""))
                }
                wakeFailed = w.failed
            }
            print("report: \(out.path)/report.md")
            if let traceDir { print("traces: \(traceDir.path)") }
            if aborted != nil { return 3 }
            if args.command == "replay" { return 0 }      // replay checks plumbing, not the gates
            return report.failed || wakeFailed ? 1 : 0

        case "gates":
            guard args.flags["report"] != nil else { throw HarnessError("gates needs --report FILE") }
            let data = try Data(contentsOf: args.url("report", default: ""))
            let d = JSONDecoder()
            d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            // Metrics and gates are recomputed: only the header and the runs are read.
            let old = try d.decode(StoredReport.self, from: data)
            let report = evaluate(old.runs, model: old.model, brain: old.brain, maxUSD: old.maxUSD, started: old.started,
                                  id: old.runID, aborted: old.aborted, judge: old.judge)
            printGates(report)
            if args.switches.contains("write") {
                try writeReport(report, to: args.url("report", default: "").deletingLastPathComponent())
                print("rewrote report.md / report.json")
            }
            return report.failed ? 1 : 0

        case "wake":
            // 0.6 wake suite. On the device only (W1): no key, no network for the on-device part.
            let library = try FixtureLibrary(directory: args.url("fixtures", default: "Fixtures"))
            let id = "wake-" + runID()
            let started = ISO8601DateFormatter().string(from: Date())
            var options = WakeBench.Options()
            options.pace = WakeBench.Pace(rawValue: args.flags["pace"] ?? "fast") ?? .fast
            options.log = logger
            var availability = await WakeBench.availability()
            if availability == .assetsMissing, !args.switches.contains("no-install") {
                // The one-time on-device model download the app does at onboarding (never audio).
                logger("on-device speech assets missing: installing (one-time model download, no audio)")
                do { try await OnDeviceSpeech.installAssets(progress: { _ in }) } catch { logger("asset install failed: \(error)") }
                availability = await WakeBench.availability()
            }
            let phrases = args.flags["phrases"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ?? WakeSuite.phrases
            let conditions = args.list("conditions")
            let only = args.list("only")
            var report = WakeReport(runID: id, started: started, finished: "", engine: "on-device SpeechAnalyzer DictationTranscriber en-US (DeeWake.OnDeviceWakeEar, matcher thresholds .tuned)",
                                    pace: options.pace.rawValue)
            report.thresholds = "\(WakeMatcher.Thresholds.tuned)"
            report.notes.append("ear availability before the run: \(availability)")
            if availability == .ready, !args.switches.contains("no-device") {
                let bench = WakeBench(library: library, options: options)
                let exposureSeconds = args.double("exposure-seconds", default: WakeSuite.exposureSeconds)
                for p in phrases {
                    let trials = WakeSuite.trials().filter { $0.phrase == p && (conditions?.contains($0.condition) ?? true)
                        && (only?.contains($0.fixture) ?? true) }
                    logger("— phrase “\(p)”: \(trials.count) trials, \(WakeSuite.exposureBeds.count) beds × \(Int(exposureSeconds)) s")
                    let r = try await bench.run(phrase: p, trials: trials, exposures: WakeSuite.exposureBeds, exposureSeconds: exposureSeconds)
                    report.trials += r.trials
                    report.exposures += r.exposures
                }
            } else {
                report.notes.append("on-device part skipped: the ear is \(availability)")
            }
            report.finished = ISO8601DateFormatter().string(from: Date())
            report.gates = WakeGates.evaluate(report)
            let out = args.url("reports", default: "Reports").appendingPathComponent(id)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try report.json().write(to: out.appendingPathComponent("wake.json"), options: .atomic)
            try Data(WakeGates.markdown(report).utf8).write(to: out.appendingPathComponent("wake.md"), options: .atomic)
            for g in report.gates {
                print(String(format: "%-5@ %-20@ %@  (target %@, n=%d)", g.status.rawValue, g.id, g.value, g.target, g.n)
                      + (g.note.map { "\n      \($0)" } ?? ""))
            }
            print("report: \(out.path)/wake.md")
            return report.failed ? 1 : 0

        case "pool":
            // Tune 14: 0.6.0 acceptance — every gate on the pooled counts / percentiles of
            // 2+ consecutive full runs (same thresholds). Offline: reads the reports only.
            let paths = (args.flags["reports"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
            guard paths.count >= 2 else { throw HarnessError("pool needs --reports A,B[,…] (2+ report dirs or report.json files)") }
            let d = JSONDecoder()
            d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            var sources: [Pool.Source] = []
            for p in paths {
                var url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : toolRoot.appendingPathComponent(p)
                if url.pathExtension != "json" { url = url.appendingPathComponent("report.json") }
                let r = try d.decode(StoredReport.self, from: Data(contentsOf: url))
                sources.append(Pool.Source(id: r.runID, model: r.model, aborted: r.aborted, runs: r.runs, judge: r.judge))
            }
            let pooled = Pool.evaluate(sources)
            print("pooled \(sources.count) reports: " + sources.map { "\($0.id) (\($0.runs.count) runs)" }.joined(separator: ", "))
            for s in sources where s.aborted != nil { print("WARN  \(s.id) aborted: \(s.aborted!)") }
            if pooled.judged < sources.count { print("WARN  judge: \(pooled.judged) of \(sources.count) reports judged") }
            for g in pooled.gates {
                print(String(format: "%-5@ %-20@ %@  (target %@, n=%d)", g.status.rawValue, g.id, g.value, g.target, g.n)
                      + (g.note.map { "\n      \($0)" } ?? ""))
            }
            let aborted = sources.contains { $0.aborted != nil }
            let failed = pooled.failed || aborted
            print("pooled verdict \(failed ? "FAIL" : "PASS"): \(pooled.gates.filter { $0.status == .pass }.count) pass, "
                  + "\(pooled.gates.filter { $0.status == .fail }.count) fail, \(pooled.gates.filter { $0.status == .skip }.count) skip")
            return failed ? 1 : 0

        default:
            print("""
            usage: voice-harness fixtures|suite|validate|run|replay|gates|judge|pool [options]
              fixtures  [--force] [--only id,id] [--max-usd 0.50]
              suite     [--write]
              validate  --scenarios FILE
              run       --scenarios FILE [--brain realtime|minimal] [--model gpt-realtime-2.1-mini] [--max-usd 2.00]
                        [--only name,name] [--audio DIR] [--no-sound-classifier] [--quiet]
                        [--judge] [--judge-model gpt-4.1-mini] [--judge-max-usd 0.50] [--state DIR] [--over-projection]
              replay    --trace Traces/<run>/<scenario>.jsonl [--scenarios FILE] [--brain minimal]
              gates     --report Reports/<run>/report.json [--write]
              (run, replay, gates, judge: --baseline Reports/<run>/report.json | --no-baseline; default the tune-7 run)
              judge     --report Reports/<run>/report.json [--judge-model M] [--judge-max-usd 0.50] [--write]
              pool      --reports Reports/<runA>,Reports/<runB>[,…]   (every gate on the pooled counts; offline)
            """)
            return args.command == "help" ? 0 : 2
        }
    } catch {
        stderr("voice-harness: \(KeyFile.describe(error))")
        return 2
    }
}

exit(await main())
