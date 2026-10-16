import Foundation
import AVFAudio
import DeeRealtime
import DeeVoice

/// `/v1/audio/speech` streamed as raw 24 kHz PCM16 (OpenAI `gpt-4o-mini-tts`, mode 2): first audio
/// arrives while the rest renders. Instructions carry her style + the DNA's `Voice:` words.
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
/// `OnDeviceClipRenderer` (AVSpeechSynthesizer.write → 24 kHz PCM16, never `speak()`), with her
/// mood mapped to pitch and rate.
public struct OnDeviceVoice: CascadeVoice {
    public let voiceIdentifier: String?
    public let language: String

    public init(voiceIdentifier: String? = nil, language: String = "en-US") {
        self.voiceIdentifier = voiceIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        self.language = language
    }

    public var label: ProviderLabel { .onDevice }

    /// Whether any voice exists for the language.
    public static func available(language: String = "en-US") -> Bool {
        OnDeviceClipRenderer.bestVoice(language: language) != nil
    }

    public func prepare() async {
        _ = try? await OnDeviceClipRenderer(voiceIdentifier: voiceIdentifier, language: language).render(text: "Hm.", instructions: "")
    }

    public func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error> {
        let shape = Self.shape(delivery)
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
    static func shape(_ d: SpeechDelivery) -> (rate: Float, pitch: Float) {
        let w = (d.instructions ?? "").lowercased()
        var rate = AVSpeechUtteranceDefaultSpeechRate
        var pitch: Float = 1.15 * d.pitch
        let lively = ["bubbly", "lively", "excited", "giddy", "playful", "quick", "bright"]
        let low = ["sad", "quiet", "subdued", "slower", "tired", "sleepy", "low energy", "hurt", "worried", "gentle"]
        if low.contains(where: w.contains) { rate *= 0.9; pitch *= 0.93 }
        else if lively.contains(where: w.contains) { rate *= 1.05; pitch *= 1.06 }
        rate *= Float(min(max(d.speed, 0.5), 1.5))
        return (min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate), min(max(pitch, 0.5), 2))
    }
}
