import Foundation
import AVFAudio
import DeeCore
import Synchronization
import DeeRealtime
import DeeVoice

/// `/v1/audio/speech` streamed as raw 24 kHz PCM16 (OpenAI `gpt-4o-mini-tts`, mode 2): first audio
/// arrives while the rest renders. Instructions carry Dee's style + the DNA's `Voice:` words.
public struct StreamingSpeechVoice: CascadeVoice {
    public let client: CompatClient
    public let model: String
    public let voice: String
    public let sendsInstructions: Bool

    public init(client: CompatClient, model: String = "gpt-4o-mini-tts", voice: String = "marin", sendsInstructions: Bool = true) {
        self.client = client; self.model = model; self.voice = voice; self.sendsInstructions = sendsInstructions
    }

    public var label: ProviderLabel { client.label }

    /// Opens the TLS connection (a free GET) so the first sentence doesn't pay for it.
    public func prepare() async { _ = try? await client.models(deadline: 5) }

    public func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error> {
        let inner = client.speech(text: text, model: model, voice: voice,
                                  instructions: sendsInstructions ? delivery.instructions : nil,
                                  speed: delivery.speed == 1 ? nil : min(max(delivery.speed, 0.25), 4))
        // PCM16 frames must not be split across chunks.
        return AsyncThrowingStream { c in
            let task = Task {
                var carry = Data()
                do {
                    for try await chunk in inner {
                        carry.append(chunk)
                        let even = carry.count - carry.count % 2
                        if even > 0 { c.yield(carry.prefix(even)); carry = Data(carry.dropFirst(even)) }
                    }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// A LAN `/v1/audio/speech` server (Kokoro-FastAPI, LocalAI, Speaches, …): WAV at its own rate,
/// converted to 24 kHz here. No style instructions (most ignore or reject them).
public struct LANSpeechVoice: CascadeVoice {
    public let client: CompatClient
    public let model: String
    public let voice: String

    public init(client: CompatClient, model: String, voice: String) {
        self.client = client; self.model = model; self.voice = voice
    }

    public var label: ProviderLabel { client.label }
    public func prepare() async { _ = try? await client.models(deadline: 3) }

    public func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error> {
        let inner = client.speech(text: text, model: model, voice: voice, instructions: nil,
                                  speed: delivery.speed == 1 ? nil : delivery.speed, format: "wav")
        return AsyncThrowingStream { c in
            let task = Task {
                var wav = Data()
                do {
                    for try await chunk in inner { wav.append(chunk) }
                    guard let pcm = PCM24k.fromWAV(wav) else { throw CompatError.notCompatible }
                    c.yield(pcm)
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// The iPhone's own synthesizer ("on this iPhone": free, private, no network), via DeeVoice's
/// `OnDeviceClipRenderer` (AVSpeechSynthesizer.write → 24 kHz PCM16, never `speak()`), with Dee's
/// mood mapped to pitch and rate.
///
/// The base pitch and rate come from the persona (`AppleVoiceRule`, persona spec §3 step 5):
/// passed in, or else the app's current persona rule (`OnDeviceVoice.personaRule`); with
/// neither (Classic Dee) today's childlike lift of 1.15 at the default rate.
public struct OnDeviceVoice: CascadeVoice {
    public let voiceIdentifier: String?
    public let language: String
    /// Base AVSpeech pitch multiplier before the mood shaping.
    public let basePitch: Float
    /// Base AVSpeech rate before the mood shaping.
    public let baseRate: Float

    public init(voiceIdentifier: String? = nil, language: String = "en-US", persona rule: AppleVoiceRule? = nil) {
        let id = voiceIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        self.voiceIdentifier = id
        self.language = language
        let r = rule ?? Self.personaRule.withLock { $0 }
        let picked = id.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? OnDeviceClipRenderer.bestVoice(language: language)
        let base = PersonaVoicePicker.shape(rule: r, voiceGender: picked.flatMap { PersonaVoicePicker.gender($0.gender) })
        basePitch = base.pitch
        baseRate = base.rate
    }

    /// The app's current persona voice rule, for voices built without one (the app sets
    /// it when the persona changes; nil = Classic Dee).
    public static let personaRule = Mutex<AppleVoiceRule?>(nil)

    public var label: ProviderLabel { .onDevice }

    /// Whether any voice exists for the language.
    public static func available(language: String = "en-US") -> Bool {
        OnDeviceClipRenderer.bestVoice(language: language) != nil
    }

    public func prepare() async {
        _ = try? await OnDeviceClipRenderer(voiceIdentifier: voiceIdentifier, language: language).render(text: "Hm.", instructions: "")
    }

    public func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error> {
        let shape = Self.shape(delivery, basePitch: basePitch, baseRate: baseRate)
        let renderer = OnDeviceClipRenderer(voiceIdentifier: voiceIdentifier, language: language,
                                            rate: shape.rate, pitch: shape.pitch)
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    c.yield(try await renderer.render(text: text, instructions: delivery.instructions ?? ""))
                    c.finish()
                } catch ClipRenderError.unavailable {
                    c.finish(throwing: ProviderIssue.onDeviceSpeechUnavailable(.voice))
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// Mood → AVSpeech rate/pitch, from the DNA's `Voice:` words in the instructions.
    static func shape(_ d: SpeechDelivery, basePitch: Float = PersonaVoicePicker.classicPitch,
                      baseRate: Float = AVSpeechUtteranceDefaultSpeechRate) -> (rate: Float, pitch: Float) {
        let w = (d.instructions ?? "").lowercased()
        var rate = baseRate
        var pitch: Float = basePitch * d.pitch
        let lively = ["bubbly", "lively", "excited", "giddy", "playful", "quick", "bright"]
        let low = ["sad", "quiet", "subdued", "slower", "tired", "sleepy", "low energy", "hurt", "worried", "gentle"]
        if low.contains(where: w.contains) { rate *= 0.9; pitch *= 0.93 }
        else if lively.contains(where: w.contains) { rate *= 1.05; pitch *= 1.06 }
        rate *= Float(min(max(d.speed, 0.5), 1.5))
        return (min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate), min(max(pitch, 0.5), 2))
    }
}

/// Mode 3's on-device voice for a persona (persona spec §3 "Mode-3 voice algorithm"):
/// English voices for the device language, no novelty, Eloquence or Personal Voice;
/// the persona's gender (`.any`: male or female, never `.unspecified`, which is mostly
/// novelty voices); ranked by quality, then the persona's name list, then the locale.
/// Never overrides a voice the user picked by hand (the app only asks when not custom).
public enum PersonaVoicePicker {
    /// One installed voice, as the picker sees it (tests pass a fake list).
    public struct Candidate: Sendable, Equatable {
        public var identifier: String
        public var name: String
        public var language: String
        /// 0 default, 1 enhanced, 2 premium.
        public var quality: Int
        /// nil = unspecified.
        public var gender: VoiceGender?
        public var novelty: Bool
        public var personal: Bool

        public init(identifier: String, name: String, language: String, quality: Int, gender: VoiceGender?,
                    novelty: Bool = false, personal: Bool = false) {
            self.identifier = identifier
            self.name = name
            self.language = language
            self.quality = quality
            self.gender = gender
            self.novelty = novelty
            self.personal = personal
        }

        /// Eloquence voices (the "Eddy / Flo / Grandma…" set) are excluded like novelty ones.
        public var isEloquence: Bool { identifier.lowercased().contains("eloquence") }
    }

    /// Today's fixed childlike lift (Classic Dee).
    public static let classicPitch: Float = 1.15

    /// The best voice for `rule` among `candidates`, or nil (then: `bestVoice(language:)`).
    public static func pick(_ candidates: [Candidate], rule: AppleVoiceRule, language: String = "en-US") -> Candidate? {
        let prefix = language.split(separator: "-").first.map(String.init) ?? "en"
        let usable = candidates.filter { c in
            guard !c.novelty, !c.personal, !c.isEloquence else { return false }
            guard c.language == language || c.language.hasPrefix(prefix + "-") || c.language == "en-US" else { return false }
            switch rule.gender {
            case .female: return c.gender == .female
            case .male: return c.gender == .male
            case .any: return c.gender == .female || c.gender == .male
            }
        }
        let names = rule.names.map { $0.lowercased() }
        func rank(_ c: Candidate) -> Int { names.firstIndex(of: c.name.lowercased()) ?? names.count }
        func locale(_ c: Candidate) -> Int { c.language == language ? 0 : c.language.hasPrefix(prefix + "-") ? 1 : 2 }
        return usable.min { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if locale(a) != locale(b) { return locale(a) < locale(b) }
            return a.identifier < b.identifier
        }
    }

    /// Base pitch and rate for `rule` and the chosen voice's gender (`.any` personas pick
    /// the pitch by it). nil rule: Classic Dee (1.15, the default rate).
    public static func shape(rule: AppleVoiceRule?, voiceGender: VoiceGender?) -> (pitch: Float, rate: Float) {
        guard let rule else { return (classicPitch, AVSpeechUtteranceDefaultSpeechRate) }
        let pitch: Float = switch rule.gender {
        case .female: rule.pitchFemale
        case .male: rule.pitchMale
        case .any: voiceGender == .male ? rule.pitchMale : rule.pitchFemale
        }
        return (pitch, rule.rate)
    }

    /// The download hint when only default-quality voices fit (nil when a better one is
    /// installed or no rule applies).
    public static func downloadHint(_ candidates: [Candidate], rule: AppleVoiceRule, language: String = "en-US") -> String? {
        guard let best = pick(candidates, rule: rule, language: language) else { return rule.downloadHint }
        return best.quality == 0 ? rule.downloadHint : nil
    }

    /// The installed voices.
    public static func installed() -> [Candidate] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            Candidate(identifier: v.identifier, name: v.name, language: v.language,
                      quality: v.quality == .premium ? 2 : v.quality == .enhanced ? 1 : 0, gender: gender(v.gender),
                      novelty: v.voiceTraits.contains(.isNoveltyVoice), personal: v.voiceTraits.contains(.isPersonalVoice))
        }
    }

    /// The voice identifier for `rule` on this device, or nil.
    public static func identifier(rule: AppleVoiceRule, language: String = Locale.current.identifier(.bcp47)) -> String? {
        pick(installed(), rule: rule, language: language)?.identifier
    }

    static func gender(_ g: AVSpeechSynthesisVoiceGender) -> VoiceGender? {
        switch g {
        case .female: .female
        case .male: .male
        default: nil
        }
    }
}
