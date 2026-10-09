import DeeRealtime
import Foundation
import Synchronization

/// Short sounds Dee makes without a round trip: laughs, a giggle, "sorry, go on",
/// "one sec". Rendered once with OpenAI text-to-speech in her session voice,
/// kept on disk, played locally through the same player as her replies (so echo
/// cancellation hears them and they share the barge-in rules).
public enum VoiceClip: String, CaseIterable, Sendable, Codable {
    case chuckle1, chuckle2, chuckle3
    case laugh1, laugh2, laugh3
    case bigLaugh1, bigLaugh2
    /// When she is tickled.
    case giggle
    case sorryGoOn
    case oneSec

    /// What is spoken.
    public var text: String {
        switch self {
        case .chuckle1: "Hehe."
        case .chuckle2: "Heh!"
        case .chuckle3: "Hm-hm!"
        case .laugh1: "Hehe!"
        case .laugh2: "Hee hee!"
        case .laugh3: "Haha!"
        case .bigLaugh1: "Hahaha!"
        case .bigLaugh2: "Ahahaha!"
        case .giggle: "Hee hee hee! That tickles!"
        case .sorryGoOn: "Oh, sorry. Go on."
        case .oneSec: "One sec."
        }
    }

    /// How it is delivered (text-to-speech `instructions`, added to the base style).
    public var delivery: String {
        switch self {
        case .chuckle1, .chuckle2, .chuckle3:
            "A small, soft, amused chuckle. Very short. Do not say words, just the little laugh."
        case .laugh1, .laugh2, .laugh3:
            "A bright, genuine, happy laugh. Short and light. Do not say words, just the laugh."
        case .bigLaugh1, .bigLaugh2:
            "A big delighted burst of laughter, giddy and bubbly, about one second. Do not say words, just the laugh."
        case .giggle:
            "Squirming, breathless, ticklish giggling, delighted and a little helpless."
        case .sorryGoOn:
            "Quick, warm and a little sheepish: she cut someone off and hands the turn back."
        case .oneSec:
            "Quick and light, as if busy for a moment."
        }
    }

    public var isLaugh: Bool {
        switch self {
        case .chuckle1, .chuckle2, .chuckle3, .laugh1, .laugh2, .laugh3, .bigLaugh1, .bigLaugh2, .giggle: true
        case .sorryGoOn, .oneSec: false
        }
    }

    /// A laugh for `intensity` (0…1); `variant` rotates among equivalent takes.
    public static func laugh(intensity: Double, variant: Int) -> VoiceClip {
        let i = intensity.isFinite ? min(max(intensity, 0), 1) : 0.5
        let options: [VoiceClip]
        switch i {
        case ..<0.34: options = [.chuckle1, .chuckle2, .chuckle3]
        case ..<0.67: options = [.laugh1, .laugh2, .laugh3]
        default: options = [.bigLaugh1, .bigLaugh2]
        }
        return options[((variant % options.count) + options.count) % options.count]
    }
}

/// Renders `VoiceClip`s once with `gpt-4o-mini-tts` (`POST /v1/audio/speech`,
/// `response_format: pcm` = 24 kHz mono PCM16, the player's format), stores them
/// in Application Support and serves them from memory.
///
/// - Same voice as the realtime session (`.named("marin")` / `.custom(id:)`), with
///   a base style (`Configuration.style`) plus each clip's delivery.
/// - A file's name carries the voice and a fingerprint of model, voice, style,
///   text and delivery: changing any of them re-renders that clip on the next
///   `prepare()`. Older renders in the same voice are removed; another voice's
///   files are left alone (another cache may use them) until
///   `removeOtherVoices()`.
/// - A missing clip is looked for on disk once, not on every `pcm` call (again
///   after `prepare()`).
/// - Server error text never reaches `Report.stopped` (an error body can echo
///   part of the key): only the status and OpenAI's short error code.
/// - Leading and trailing silence is trimmed (5 ms fades), so a laugh lands at once.
/// - Graceful when absent: no key, no network or a refused request leave the
///   clip missing (`pcm` returns nil) and the caller simply doesn't play it.
///   `prepare()` is safe to call again later (only missing clips are rendered).
/// - Never throws, never crashes for lack of a key, a directory or the network.
public final class ClipCache: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var model = "gpt-4o-mini-tts"
        /// The session's voice (keep them the same so she sounds like one person).
        public var voice: DeeRealtime.RealtimeVoice = .named("marin")
        /// Base delivery for every clip; each clip adds its own.
        public var style = "You are Dee, a small, sweet, playful robot companion with a bright, youthful, expressive voice."
        public var endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
        /// Where the clips live (default `Application Support/Dee/Clips`).
        public var directory: URL
        public var clips: [VoiceClip] = VoiceClip.allCases
        /// Seconds per request.
        public var timeout: Double = 20

        public init(voice: DeeRealtime.RealtimeVoice = .named("marin"), directory: URL? = nil) {
            self.voice = voice
            self.directory = directory ?? Self.defaultDirectory()
        }

        public static func defaultDirectory() -> URL {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("Dee/Clips", isDirectory: true)
        }
    }

    /// What `prepare()` did.
    public struct Report: Sendable, Equatable {
        public var rendered: [VoiceClip] = []
        public var alreadyThere: [VoiceClip] = []
        public var failed: [VoiceClip] = []
        /// Why it stopped early (no key, key refused, rate limited), if it did.
        public var stopped: String?
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias KeyProvider = @Sendable () -> String?

    public let configuration: Configuration
    private let key: KeyProvider
    private let fetch: Fetch
    private let memory = Mutex<[VoiceClip: Data]>([:])
    /// Clips known not to be on disk (until the next `prepare()`).
    private let missing = Mutex<Set<VoiceClip>>([])
    private let preparing = Mutex(false)

    /// - Parameters:
    ///   - key: the OpenAI key (e.g. `{ try? KeyStore().load() }`).
    ///   - fetch: the HTTP call (tests pass a fake).
    public init(configuration: Configuration = Configuration(), key: @escaping KeyProvider,
                fetch: Fetch? = nil) {
        self.configuration = configuration
        self.key = key
        let timeout = configuration.timeout
        self.fetch = fetch ?? { request in
            var r = request
            r.timeoutInterval = timeout
            return try await URLSession.shared.data(for: r)
        }
    }

    /// The key from the Keychain (`DeeRealtime.KeyStore`).
    public convenience init(voice: DeeRealtime.RealtimeVoice, keyStore: KeyStore = KeyStore(), directory: URL? = nil) {
        self.init(configuration: Configuration(voice: voice, directory: directory), key: { try? keyStore.load() })
    }

    // MARK: Serving

    /// The clip's 24 kHz mono PCM16, or nil when it is not rendered (yet).
    public func pcm(_ clip: VoiceClip) -> Data? {
        if let d = memory.withLock({ $0[clip] }) { return d }
        if missing.withLock({ $0.contains(clip) }) { return nil }
        guard let d = try? Data(contentsOf: fileURL(clip)), d.count >= 2 else {
            missing.withLock { _ = $0.insert(clip) }
            return nil
        }
        memory.withLock { $0[clip] = d }
        return d
    }

    /// Clips ready to play.
    public var available: Set<VoiceClip> { Set(configuration.clips.filter { pcm($0) != nil }) }

    // MARK: Rendering

    /// Renders every missing clip (one request at a time). Stops early without a
    /// key, when the key is refused or when rate limited; a clip that fails for
    /// another reason is skipped. Concurrent calls return an empty report.
    @discardableResult
    public func prepare() async -> Report {
        var report = Report()
        let go = preparing.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard go else { return report }
        defer { preparing.withLock { $0 = false } }
        missing.withLock { $0.removeAll() }               // look on disk again
        try? FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        var dir = configuration.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true                  // re-renderable, keep it out of backups
        try? dir.setResourceValues(values)
        for clip in configuration.clips {
            if pcm(clip) != nil { report.alreadyThere.append(clip); continue }
            guard let apiKey = key(), !apiKey.isEmpty else { report.stopped = "no key"; break }
            do {
                let raw = try await render(clip, apiKey: apiKey)
                let trimmed = Self.trim(raw)
                guard trimmed.count >= 2400 else { report.failed.append(clip); continue }   // < 50 ms: not a clip
                removeStale(clip)
                try trimmed.write(to: fileURL(clip), options: .atomic)
                memory.withLock { $0[clip] = trimmed }
                missing.withLock { _ = $0.remove(clip) }
                report.rendered.append(clip)
            } catch let e as RenderError where e.stopsAll {
                report.failed.append(clip)
                report.stopped = e.description
                break
            } catch {
                report.failed.append(clip)
            }
        }
        return report
    }

    enum RenderError: Error, CustomStringConvertible {
        /// HTTP status and OpenAI's error `code` / `type` (a short token, never the message).
        case status(Int, String?)
        case notAudio

        var stopsAll: Bool {
            if case .status(let code, _) = self { return code == 401 || code == 403 || code == 429 }
            return false
        }

        var description: String {
            switch self {
            case .status(let code, let errorCode): "HTTP \(code)" + (errorCode.map { " (\($0))" } ?? "")
            case .notAudio: "not audio"
            }
        }
    }

    /// The request body for one clip.
    func requestBody(_ clip: VoiceClip) -> [String: Any] {
        let voice: Any
        switch configuration.voice {
        case .named(let n): voice = n
        case .custom(let id): voice = ["id": id]
        }
        return [
            "model": configuration.model,
            "voice": voice,
            "input": clip.text,
            "instructions": configuration.style + " " + clip.delivery,
            "response_format": "pcm",
        ]
    }

    private func render(_ clip: VoiceClip, apiKey: String) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(clip), options: [.sortedKeys])
        let (data, response) = try await fetch(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw RenderError.status(code, Self.errorCode(data))
        }
        // Raw PCM: an error page or JSON would start with "{" / "<".
        if let first = data.first, data.count < 64 || first == UInt8(ascii: "{") && data.count < 4096 {
            throw RenderError.notAudio
        }
        // Ten seconds is far longer than any clip: something went wrong.
        guard data.count <= 24_000 * 2 * 10 else { throw RenderError.notAudio }
        return data.count % 2 == 0 ? data : data.dropLast()
    }

    /// OpenAI's `error.code` (or `error.type`) from an error body: letters,
    /// digits and `_` only, at most 40 characters. Messages are never kept: a
    /// 401 message quotes part of the key.
    static func errorCode(_ body: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let e = o["error"] as? [String: Any] else { return nil }
        for k in ["code", "type"] {
            guard let v = e[k] as? String, !v.isEmpty, v.count <= 40,
                  v.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
                  !v.hasPrefix("sk") else { continue }
            return v
        }
        return nil
    }

    // MARK: Files

    /// `<voice>-<clip>-<fingerprint>.pcm`.
    func fileURL(_ clip: VoiceClip) -> URL {
        configuration.directory.appendingPathComponent("\(voiceKey)-\(clip.rawValue)-\(fingerprint(clip)).pcm")
    }

    /// The voice in a file name: letters, digits, `_` only.
    var voiceKey: String {
        let raw: String
        switch configuration.voice {
        case .named(let n): raw = n
        case .custom(let id): raw = "id_" + id
        }
        let clean = String(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_"
        })
        return clean.isEmpty ? "voice" : String(clean.prefix(48))
    }

    /// Removes the clips rendered in other voices (after Dee's voice changed for good).
    public func removeOtherVoices() {
        let fm = FileManager.default
        let prefix = voiceKey + "-"
        guard let names = try? fm.contentsOfDirectory(atPath: configuration.directory.path) else { return }
        for n in names where n.hasSuffix(".pcm") && !n.hasPrefix(prefix) {
            try? fm.removeItem(at: configuration.directory.appendingPathComponent(n))
        }
    }

    func fingerprint(_ clip: VoiceClip) -> String {
        let voice: String
        switch configuration.voice {
        case .named(let n): voice = n
        case .custom(let id): voice = "id:" + id
        }
        let key = ["v1", configuration.model, voice, configuration.style, clip.text, clip.delivery].joined(separator: "\u{1F}")
        var h: UInt64 = 0xcbf2_9ce4_8422_2325                // FNV-1a 64
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// Older renders of `clip` in this voice (another style or text), and files
    /// of the old `<clip>-<fingerprint>.pcm` naming.
    private func removeStale(_ clip: VoiceClip) {
        let fm = FileManager.default
        let keep = fileURL(clip).lastPathComponent
        guard let names = try? fm.contentsOfDirectory(atPath: configuration.directory.path) else { return }
        for n in names where (n.hasPrefix("\(voiceKey)-\(clip.rawValue)-") || n.hasPrefix(clip.rawValue + "-"))
            && n.hasSuffix(".pcm") && n != keep {
            try? fm.removeItem(at: configuration.directory.appendingPathComponent(n))
        }
    }

    // MARK: Trimming

    /// Drops leading / trailing near-silence (below −45 dBFS) with 10 ms margins
    /// and 5 ms fades.
    static func trim(_ data: Data) -> Data {
        var s = PCM16.samples(data)
        guard !s.isEmpty else { return data }
        let threshold: Int16 = 184                           // ≈ −45 dBFS
        guard let first = s.firstIndex(where: { abs(Int32($0)) > Int32(threshold) }),
              let last = s.lastIndex(where: { abs(Int32($0)) > Int32(threshold) }) else { return Data() }
        let margin = 240                                     // 10 ms
        let lo = max(0, first - margin)
        let hi = min(s.count - 1, last + margin)
        s = Array(s[lo...hi])
        let fade = min(120, s.count / 2)                     // 5 ms
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            s[i] = Int16(Float(s[i]) * g)
            s[s.count - 1 - i] = Int16(Float(s[s.count - 1 - i]) * g)
        }
        return s.withUnsafeBytes { Data($0) }
    }
}
