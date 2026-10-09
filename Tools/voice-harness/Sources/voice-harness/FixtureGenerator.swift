import Foundation
import HarnessCore
import HarnessRunner

/// `voice-harness fixtures`: renders the catalog once (OpenAI TTS + macOS `say`),
/// synthesizes the room beds and the impulse response, writes the manifest.
struct FixtureGenerator {
    let root: URL
    let force: Bool
    let only: Set<String>?
    let maxUSD: Double
    let log: (String) -> Void

    static let rate = 24_000
    static let bedSeconds = 20.0

    var dir: URL { root.appendingPathComponent("Fixtures") }

    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("utterances"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("noise"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("ir"), withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let existing = try? FixtureManifest.load(manifestURL)

        let specs = FixtureCatalog.all.filter { only == nil || only!.contains($0.id) }
        let needsTTS = specs.contains { $0.engine == .openai && (force || !exists($0)) }
        // gpt-4o-mini-tts: ~1 text token / 4 chars in, ~1200 audio tokens / min out.
        let chars = specs.filter { $0.engine == .openai }.reduce(0) { $0 + $1.text.count }
        let projected = Double(chars) / 4 * Pricing.ttsTextIn / 1e6 + Double(chars) / 15 / 60 * 1200 * Pricing.ttsAudioOut / 1e6
        log(String(format: "fixtures: %d specs, TTS projection ≈ $%.3f (cap $%.2f)", specs.count, projected, maxUSD))
        if needsTTS && projected > maxUSD { throw HarnessError("TTS projection over --max-usd") }
        let key = needsTTS ? try KeyFile.load() : nil

        var utterances: [String: FixtureManifest.Utterance] = [:]
        for u in existing?.utterances ?? [] { utterances[u.id] = u }
        for spec in specs {
            if !force, exists(spec), let old = utterances[spec.id], old.text == spec.text {
                continue
            }
            log("render \(spec.id) [\(spec.engine.rawValue) \(spec.voice) \(spec.style.rawValue)] “\(spec.text)”")
            var segments: [FixtureAssembler.Segment] = []
            for part in spec.parts {
                switch part {
                case .pause(let s): segments.append(.pause(s))
                case .words(let w):
                    let audio = spec.engine == .openai
                        ? try await tts(w, voice: spec.voice, style: spec.style, key: key!)
                        : try say(w, voice: spec.voice, rate: spec.style.sayRate)
                    segments.append(.audio(audio))
                }
            }
            let a = FixtureAssembler.assemble(segments, sampleRate: Self.rate, levelDB: spec.style.levelDB)
            let file = "utterances/\(spec.id).wav"
            try WAV.write(a.samples, sampleRate: Self.rate, to: dir.appendingPathComponent(file))
            utterances[spec.id] = .init(
                id: spec.id, file: file, category: spec.category, engine: spec.engine, voice: spec.voice, style: spec.style,
                text: spec.text, sampleRate: Self.rate, samples: a.samples.count, onsetSample: a.onset,
                endOfSpeechSample: a.endOfSpeech, spans: a.spans, scriptedPauses: spec.pauses,
                activeLevelDB: DSP.activeLevelDB(a.samples, sampleRate: Self.rate))
        }

        var beds = existing?.noise ?? []
        func bed(_ id: String, provenance: String, _ make: () throws -> [Float]) throws {
            let file = "noise/\(id).wav"
            if !force, beds.contains(where: { $0.id == id }), fm.fileExists(atPath: dir.appendingPathComponent(file).path) { return }
            log("bed \(id)")
            let x = try make()
            try WAV.write(x, sampleRate: Self.rate, to: dir.appendingPathComponent(file))
            beds.removeAll { $0.id == id }
            beds.append(.init(id: id, file: file, seconds: Double(x.count) / Double(Self.rate),
                              levelDB: DSP.db(DSP.rms(x)), provenance: provenance))
        }
        try bed("fan", provenance: "Synthesized (HarnessCore Beds.fan, seed 0xFA11): low-passed noise rush, 31 Hz blade-pass hum + harmonics, 120 Hz motor whine, 0.7 Hz beat. No recorded material.") {
            Beds.fan(seconds: Self.bedSeconds, sampleRate: Self.rate)
        }
        try bed("kitchen", provenance: "Synthesized (HarnessCore Beds.kitchen, seed 0xC0C0): band-passed running tap with gurgle (two stretches), 60/180 Hz fridge hum, random dish clinks (decaying inharmonic partials). No recorded material.") {
            Beds.kitchen(seconds: Self.bedSeconds, sampleRate: Self.rate)
        }
        try bed("tv", provenance: "Rendered with macOS `say` (voices Daniel, Samantha, Fred, Kathy; original text written for the harness), staggered and summed, band-limited 180 Hz–5 kHz like a small TV speaker, plus a soft synthesized chord drone (HarnessCore Beds.tv, seed 0x7E1E).") {
            let lines = [
                ("Daniel", "In tonight's news, the city council approved a plan to repave the main bridge, and work is expected to begin early next spring, weather permitting."),
                ("Samantha", "Coming up after the break, our chef shows you three easy ways to cook a weeknight dinner in under twenty minutes, so stay with us."),
                ("Fred", "The home team took the lead late in the third quarter and held on through a tense finish to win by a single point."),
                ("Kathy", "Tomorrow will be partly cloudy with a light breeze from the west and highs near seventy degrees across most of the region."),
            ]
            let talkers = try lines.map { try say($0.1, voice: $0.0, rate: nil) }
            return Beds.tv(talkers: talkers, seconds: Self.bedSeconds, sampleRate: Self.rate)
        }

        var irs = existing?.impulseResponses ?? []
        let irFile = "ir/room.wav"
        if force || !fm.fileExists(atPath: dir.appendingPathComponent(irFile).path) || irs.isEmpty {
            let h = Beds.roomImpulse(sampleRate: Self.rate)
            try WAV.write(h, sampleRate: Self.rate, to: dir.appendingPathComponent(irFile))
            irs = [.init(id: "room", file: irFile, seconds: Double(h.count) / Double(Self.rate), levelDB: DSP.db(DSP.rms(h)),
                         provenance: "Synthesized (HarnessCore Beds.roomImpulse, seed 0x1A0): unit direct path, 5 early reflections (3–23 ms), exponentially decaying low-passed diffuse tail, RT60 ≈ 0.35 s, 0.4 s long, peak-normalized.")]
        }

        let ordered = FixtureCatalog.all.compactMap { utterances[$0.id] }
        let manifest = FixtureManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            notes: "24 kHz mono PCM16. User voices are gpt-4o-mini-tts (alloy, ash, ballad, coral, echo, sage, shimmer, verse; never Dee's marin/cedar) and macOS say. Each spoken segment is trimmed to its voiced extent (±30 ms), normalized to its style's active level, and joined with exact digital-silence pauses; 0.15 s lead, 0.4 s tail. onsetSample / endOfSpeechSample / spans come from a 10 ms energy detector on the final file (threshold max(−55 dBFS, loudest − 38 dB), gaps < 200 ms bridged).",
            utterances: ordered, noise: beds.sorted { $0.id < $1.id }, impulseResponses: irs)
        try manifest.write(manifestURL)
        let total = try directorySize(dir)
        log(String(format: "wrote %d utterances, %d beds, %d IR; %.1f MB", ordered.count, beds.count, irs.count, Double(total) / 1e6))
    }

    func exists(_ spec: FixtureSpec) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("utterances/\(spec.id).wav").path)
    }

    func directorySize(_ url: URL) throws -> Int {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = e?.nextObject() as? URL { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    /// `gpt-4o-mini-tts`, raw 24 kHz PCM16.
    func tts(_ text: String, voice: String, style: FixtureStyle, key: String) async throws -> [Float] {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": "gpt-4o-mini-tts", "input": text, "voice": voice,
                                   "instructions": style.ttsInstructions, "response_format": "pcm"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var lastError = ""
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, data.count > 4800 { return WAV.floats(pcm16: data) }
                // Never echo the body wholesale: only the error code.
                let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["code"] as? String } ?? "-"
                lastError = "HTTP \(status) (\(code))"
                if status == 401 || status == 403 { break }
            } catch {
                lastError = KeyFile.describe(error)
            }
            try await Task.sleep(for: .seconds(Double(attempt + 1)))
        }
        throw HarnessError("TTS failed for “\(text.prefix(30))…”: \(Redact.secrets(lastError))")
    }

    /// macOS `say` → 24 kHz PCM16 WAV.
    func say(_ text: String, voice: String, rate: Int?) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vh-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-v", voice, "-o", tmp.path, "--file-format=WAVE", "--data-format=LEI16@24000"]
        if let rate { args += ["-r", "\(rate)"] }
        p.arguments = args + [text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw HarnessError("say failed (\(voice))") }
        let a = try WAV.read(tmp)
        return DSP.resampled(a.samples, from: a.sampleRate, to: Self.rate)
    }
}
