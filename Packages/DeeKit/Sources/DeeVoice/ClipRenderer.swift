import AVFAudio
import DeeRealtime
import Foundation

/// Why a clip couldn't be rendered.
public enum ClipRenderError: Error, Sendable, Equatable, CustomStringConvertible {
    /// HTTP status and the server's short error `code` / `type` (never its message:
    /// a 401 message quotes part of the key).
    case status(Int, String?)
    /// The answer wasn't audio.
    case notAudio
    /// The renderer needs a key and has none.
    case noKey
    /// On-device speech isn't available (no voice for the language).
    case unavailable

    /// Rendering more clips would fail the same way (bad key, rate limit, no key).
    public var stopsAll: Bool {
        switch self {
        case .status(let code, _): code == 401 || code == 403 || code == 429
        case .noKey, .unavailable: true
        case .notAudio: false
        }
    }

    public var description: String {
        switch self {
        case .status(let code, let errorCode): "HTTP \(code)" + (errorCode.map { " (\($0))" } ?? "")
        case .notAudio: "not audio"
        case .noKey: "no key"
        case .unavailable: "on-device speech unavailable"
        }
    }
}

/// Turns a clip's text into Dee's voice: OpenAI text-to-speech (mode 1 and 2), a LAN
/// `/v1/audio/speech` server, or the iPhone's own synthesizer (mode 3). One
/// renderer per provider (contract §2); `ClipCache` keeps what it made on disk.
public protocol ClipRenderer: Sendable {
    /// The renderer's model / engine as it goes into a clip's fingerprint (a change
    /// re-renders the clip). OpenAI: the model id, unchanged from v0.5 (no re-render).
    var fingerprintModel: String { get }
    /// The voice as it goes into file names and fingerprints.
    var voiceName: String { get }
    /// 24 kHz mono PCM16 for `text`, delivered as `instructions` say (renderers
    /// without style control ignore them).
    func render(text: String, instructions: String) async throws -> Data
}

// MARK: - /v1/audio/speech (OpenAI or a LAN server)

/// `POST {base}/v1/audio/speech` (OpenAI's API, also served by Kokoro-FastAPI,
/// LocalAI, Speaches, …) through a `Transport` fetch.
public struct SpeechEndpointRenderer: ClipRenderer {
    public enum Format: String, Sendable, Equatable {
        /// Raw 24 kHz mono PCM16 (OpenAI's `pcm`).
        case pcm
        /// A WAV file at whatever rate the server makes, converted to 24 kHz here.
        case wav
    }

    public struct Configuration: Sendable, Equatable {
        /// Scheme + host + port (no `/v1`), e.g. `https://api.openai.com`.
        public var baseURL: URL
        public var model: String
        public var voice: RealtimeVoice
        public var format: Format
        /// Send `instructions` (OpenAI `gpt-4o-mini-tts` style control).
        public var sendsInstructions: Bool
        public var timeout: Double = 20

        public init(baseURL: URL, model: String, voice: RealtimeVoice, format: Format, sendsInstructions: Bool) {
            self.baseURL = baseURL; self.model = model; self.voice = voice
            self.format = format; self.sendsInstructions = sendsInstructions
        }

        /// OpenAI, as v0.5 rendered clips: `gpt-4o-mini-tts`, `pcm`, instructions.
        public static func openAI(voice: RealtimeVoice, model: String = "gpt-4o-mini-tts") -> Configuration {
            Configuration(baseURL: URL(string: "https://api.openai.com")!, model: model, voice: voice,
                          format: .pcm, sendsInstructions: true)
        }

        /// A LAN speech server (WAV, no style instructions).
        public static func lan(baseURL: URL, model: String, voice: String) -> Configuration {
            Configuration(baseURL: baseURL, model: model, voice: .named(voice), format: .wav, sendsInstructions: false)
        }

        public var url: URL { baseURL.appendingPathComponent("v1/audio/speech") }
        public var isOpenAI: Bool { baseURL.host?.lowercased() == "api.openai.com" }
    }

    public typealias KeyProvider = @Sendable () -> String?

    public let configuration: Configuration
    private let key: KeyProvider
    private let fetch: HTTPFetch
    /// Requests need a key (OpenAI always; a LAN server only if it was given one).
    private let keyRequired: Bool

    public init(configuration: Configuration, key: @escaping KeyProvider, keyRequired: Bool? = nil,
                fetch: HTTPFetch? = nil) {
        self.configuration = configuration
        self.key = key
        self.keyRequired = keyRequired ?? configuration.isOpenAI
        self.fetch = fetch ?? Transport.openAIDefault.fetch
    }

    public var fingerprintModel: String {
        configuration.isOpenAI ? configuration.model
            : "lan:\(configuration.baseURL.host ?? "-"):\(configuration.baseURL.port ?? 0):\(configuration.model)"
    }

    public var voiceName: String {
        switch configuration.voice {
        case .named(let n): n
        case .custom(let id): "id:" + id
        }
    }

    /// The JSON body (keys sorted when sent).
    public func requestBody(text: String, instructions: String) -> [String: Any] {
        let voice: Any
        switch configuration.voice {
        case .named(let n): voice = n
        case .custom(let id): voice = ["id": id]
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "voice": voice,
            "input": text,
            "response_format": configuration.format.rawValue,
        ]
        if configuration.sendsInstructions { body["instructions"] = instructions }
        return body
    }

    public func render(text: String, instructions: String) async throws -> Data {
        let apiKey = key().flatMap { $0.isEmpty ? nil : $0 }
        if keyRequired, apiKey == nil { throw ClipRenderError.noKey }
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("clip", forHTTPHeaderField: Transport.purposeHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(text: text, instructions: instructions),
                                                      options: [.sortedKeys])
        let (data, response) = try await fetch(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ClipRenderError.status(code, ClipCache.errorCode(data)) }
        switch configuration.format {
        case .pcm:
            // Raw PCM: an error page or JSON would start with "{" / "<".
            if let first = data.first, data.count < 64 || first == UInt8(ascii: "{") && data.count < 4096 {
                throw ClipRenderError.notAudio
            }
            // Ten seconds is far longer than any clip: something went wrong.
            guard data.count <= 24_000 * 2 * 10 else { throw ClipRenderError.notAudio }
            return data.count % 2 == 0 ? data : data.dropLast()
        case .wav:
            guard let pcm = PCM24k.fromWAV(data), pcm.count >= 2 else { throw ClipRenderError.notAudio }
            return pcm
        }
    }
}

// MARK: - On this iPhone

/// The iPhone's own synthesizer (`AVSpeechSynthesizer.write`, never `speak`: Dee's
/// audio must go through Dee's player for echo cancellation and barge-in),
/// converted to 24 kHz PCM16. Free, private, no network.
public struct OnDeviceClipRenderer: ClipRenderer {
    /// `AVSpeechSynthesisVoice.identifier`; nil = the best installed voice for `language`.
    public var voiceIdentifier: String?
    public var language: String
    public var rate: Float
    public var pitch: Float

    public init(voiceIdentifier: String? = nil, language: String = "en-US",
                rate: Float = AVSpeechUtteranceDefaultSpeechRate, pitch: Float = 1.15) {
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        self.rate = rate
        self.pitch = pitch
    }

    public var fingerprintModel: String { "ondevice:\(language):\(rate):\(pitch)" }
    public var voiceName: String { "ondevice_" + (voiceIdentifier ?? language) }

    /// The best installed voice for `language` (premium > enhanced > default; no
    /// novelty voices), or nil.
    public static func bestVoice(language: String) -> AVSpeechSynthesisVoice? {
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            ($0.language == language || $0.language.hasPrefix(prefix + "-")) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return candidates.max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            // Same quality: the exact language wins.
            return (a.language == language ? 1 : 0) < (b.language == language ? 1 : 0)
        }
    }

    public func render(text: String, instructions: String) async throws -> Data {
        let voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.bestVoice(language: language)
        guard let voice else { throw ClipRenderError.unavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        let box = SynthBox()
        let pcm: Data = try await withCheckedThrowingContinuation { c in
            box.start(utterance, continuation: c)
        }
        guard pcm.count >= 2 else { throw ClipRenderError.notAudio }
        return pcm
    }

    /// Holds the synthesizer alive for one utterance and converts as it writes.
    private final class SynthBox: @unchecked Sendable {
        private let synth = AVSpeechSynthesizer()
        private let converter = BufferConverter(target: PCM16Capture.format)
        private var out = Data()
        private var done = false
        private let lock = NSLock()

        func start(_ u: AVSpeechUtterance, continuation c: CheckedContinuation<Data, Error>) {
            synth.write(u) { [self] buffer in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    if let tail = converter.finish() { out.append(PCM16.data(from: tail)) }
                    let result = out
                    _ = synth           // keep the synthesizer until the end
                    c.resume(returning: result)
                    return
                }
                if let converted = converter.convert(pcm) { out.append(PCM16.data(from: converted)) }
            }
        }
    }
}

// MARK: - 24 kHz conversion

/// Brings any PCM Dee's voice may arrive in (a LAN server's WAV, a synthesizer at
/// 22 050 Hz) to the player's format: 24 kHz mono PCM16 little-endian.
public enum PCM24k {
    /// A RIFF/WAVE file (PCM 8/16/24/32-bit or float 32, any rate, any channels;
    /// streaming WAVs with a 0 / 0xFFFFFFFF data size are read to the end) → 24 kHz
    /// mono PCM16. nil if it isn't a WAV this can read.
    public static func fromWAV(_ wav: Data) -> Data? {
        let b = [UInt8](wav)
        guard b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        var i = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""
            var size = u32(i + 4)
            let body = i + 8
            if id == "fmt ", body + 16 <= b.count {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, body + 26 <= b.count { format = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                if size == 0 || size == 0xFFFF_FFFF || body + size > b.count { size = b.count - body }
                guard channels > 0, rate > 0 else { return nil }
                return convert(Array(b[body..<(body + size)]), format: format, channels: channels, rate: rate, bits: bits)
            }
            i = body + size + (size & 1)
        }
        return nil
    }

    /// Interleaved Int16 PCM at `rate` with `channels` → 24 kHz mono PCM16.
    public static func fromPCM16(_ data: Data, rate: Double, channels: Int = 1) -> Data? {
        convert([UInt8](data), format: 1, channels: channels, rate: Int(rate), bits: 16)
    }

    private static func convert(_ bytes: [UInt8], format: Int, channels: Int, rate: Int, bits: Int) -> Data? {
        let bytesPer = bits / 8
        guard bytesPer > 0, channels > 0 else { return nil }
        let frames = bytes.count / (bytesPer * channels)
        guard frames > 0 else { return Data() }
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var acc: Float = 0
            for ch in 0..<channels {
                let o = (f * channels + ch) * bytesPer
                let v: Float
                switch (format, bits) {
                case (1, 8): v = (Float(bytes[o]) - 128) / 128
                case (1, 16): v = Float(Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)) / 32768
                case (1, 24):
                    let raw = Int32(bytes[o]) << 8 | Int32(bytes[o + 1]) << 16 | Int32(bytes[o + 2]) << 24
                    v = Float(raw) / 2_147_483_648
                case (1, 32):
                    let raw = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                    v = Float(Int32(bitPattern: raw)) / 2_147_483_648
                case (3, 32):
                    let raw = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                    v = Float(bitPattern: raw)
                default: return nil
                }
                acc += v
            }
            mono[f] = acc / Float(channels)
        }
        if rate == 24_000 {
            var out = [Int16](repeating: 0, count: frames)
            for k in 0..<frames { out[k] = PCM16.int16(mono[k]) }
            return out.withUnsafeBytes { Data($0) }
        }
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: frames) }
        let converter = BufferConverter(target: PCM16Capture.format)
        var out = Data()
        if let c = converter.convert(buffer) { out.append(PCM16.data(from: c)) }
        if let tail = converter.finish() { out.append(PCM16.data(from: tail)) }
        return out
    }
}
