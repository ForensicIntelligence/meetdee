import DeeRealtime
import Foundation
import Synchronization

/// Short sounds Dee makes without a round trip: laughs, a giggle, "sorry, go on",
/// "one sec". Rendered once with OpenAI text-to-speech in Dee's session voice,
/// kept on disk, played locally through the same player as Dee's replies (so echo
/// cancellation hears them and they share the barge-in rules).
public enum VoiceClip: String, CaseIterable, Sendable, Codable {
    case chuckle1, chuckle2, chuckle3
    case laugh1, laugh2, laugh3
    case bigLaugh1, bigLaugh2
    /// When Dee is tickled.
    case giggle
    case sorryGoOn
    case oneSec
    /// When the conversation window closes ("go to sleep", idle close).
    case goodbye

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
        case .goodbye: "Okay, bye for now!"
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
            "Quick, warm and a little sheepish: cutting someone off by accident and handing the turn back."
        case .oneSec:
            "Quick and light, as if busy for a moment."
        case .goodbye:
            "Warm, light and friendly, a little sleepy: signing off for now."
        }
    }

    public var isLaugh: Bool {
        switch self {
        case .chuckle1, .chuckle2, .chuckle3, .laugh1, .laugh2, .laugh3, .bigLaugh1, .bigLaugh2, .giggle: true
        case .sorryGoOn, .oneSec, .goodbye: false
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

/// Renders `VoiceClip`s once with its `ClipRenderer` (v0.5: always `gpt-4o-mini-tts`,
/// `POST /v1/audio/speech`, `response_format: pcm` = 24 kHz mono PCM16, the
/// player's format; v0.6: OpenAI, a LAN speech server, or this iPhone), stores
/// them in Application Support and serves them from memory. Never renders while
/// `renderAllowed` is false (DORMANT).
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
        /// The session's voice (keep them the same so Dee sounds like one person).
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

    public typealias Fetch = HTTPFetch
    public typealias KeyProvider = @Sendable () -> String?

    public let configuration: Configuration
    /// Who makes the clips (OpenAI, a LAN speech server, or this iPhone).
    public let renderer: any ClipRenderer
    private let memory = Mutex<[VoiceClip: Data]>([:])
    /// Clips known not to be on disk (until the next `prepare()`).
    private let missing = Mutex<Set<VoiceClip>>([])
    private let preparing = Mutex(false)
    private let allowed = Mutex(true)

    /// v0.6 (W2): false while Dee is DORMANT (`CloudVoice` sets it): `prepare()`
    /// renders nothing and stops between clips. Playing what is on disk is local and
    /// always allowed.
    public var renderAllowed: Bool {
        get { allowed.withLock { $0 } }
        set { allowed.withLock { $0 = newValue } }
    }

    /// OpenAI text-to-speech (`configuration.model`, `.voice`, `.endpoint`), as v0.5.
    /// - Parameters:
    ///   - key: the OpenAI key (e.g. `{ try? KeyStore().load() }`).
    ///   - fetch: the HTTP call (tests pass a fake; default the shared OpenAI `Transport`).
    public init(configuration: Configuration = Configuration(), key: @escaping KeyProvider,
                fetch: Fetch? = nil) {
        self.configuration = configuration
        var speech = SpeechEndpointRenderer.Configuration.openAI(voice: configuration.voice, model: configuration.model)
        speech.baseURL = Self.base(of: configuration.endpoint)
        speech.timeout = configuration.timeout
        let timeout = configuration.timeout
        let call = fetch ?? Transport.openAIDefault.fetch
        self.renderer = SpeechEndpointRenderer(configuration: speech, key: key, keyRequired: true, fetch: { request in
            var r = request
            r.timeoutInterval = timeout
            return try await call(r)
        })
    }

    /// Any renderer (a LAN speech server, this iPhone). `configuration.voice`,
    /// `.model` and `.endpoint` are not used: the renderer has its own.
    public init(configuration: Configuration, renderer: any ClipRenderer) {
        self.configuration = configuration
        self.renderer = renderer
    }

    /// The key from the Keychain (`DeeRealtime.KeyStore`).
    public convenience init(voice: DeeRealtime.RealtimeVoice, keyStore: KeyStore = KeyStore(), directory: URL? = nil) {
        self.init(configuration: Configuration(voice: voice, directory: directory), key: { try? keyStore.load() })
    }

    /// `https://host[:port]` of a `/v1/audio/speech` URL.
    static func base(of endpoint: URL) -> URL {
        var c = URLComponents()
        c.scheme = endpoint.scheme
        c.host = endpoint.host
        c.port = endpoint.port
        return c.url ?? endpoint
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
        guard renderAllowed else {
            report.alreadyThere = configuration.clips.filter { pcm($0) != nil }
            report.stopped = "dormant"
            return report
        }
        for clip in configuration.clips {
            if pcm(clip) != nil { report.alreadyThere.append(clip); continue }
            guard renderAllowed else { report.stopped = "dormant"; break }
            do {
                let raw = try await renderer.render(text: clip.text, instructions: configuration.style + " " + clip.delivery)
                let trimmed = Self.trim(raw)
                guard trimmed.count >= 2400 else { report.failed.append(clip); continue }   // < 50 ms: not a clip
                removeStale(clip)
                try trimmed.write(to: fileURL(clip), options: .atomic)
                memory.withLock { $0[clip] = trimmed }
                missing.withLock { _ = $0.remove(clip) }
                report.rendered.append(clip)
            } catch let e as ClipRenderError where e.stopsAll {
                if e != .noKey { report.failed.append(clip) }
                report.stopped = e.description
                break
            } catch {
                report.failed.append(clip)
            }
        }
        return report
    }

    /// The request body for one clip (OpenAI-style renderers; `[:]` otherwise).
    func requestBody(_ clip: VoiceClip) -> [String: Any] {
        guard let r = renderer as? SpeechEndpointRenderer else { return [:] }
        return r.requestBody(text: clip.text, instructions: configuration.style + " " + clip.delivery)
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
        let name = renderer.voiceName
        let raw = name.hasPrefix("id:") ? "id_" + name.dropFirst(3) : name
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
        // OpenAI: exactly v0.5's ingredients (model, voice), so nothing re-renders.
        let key = ["v1", renderer.fingerprintModel, renderer.voiceName, configuration.style, clip.text, clip.delivery]
            .joined(separator: "\u{1F}")
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
