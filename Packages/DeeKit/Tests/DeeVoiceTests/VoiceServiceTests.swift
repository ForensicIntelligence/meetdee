import AVFAudio
import Foundation
import Testing
@testable import DeeVoice

/// The live service on macOS must fail soft: no crash, a clear error, no hang.
@Suite struct VoiceServiceFailSoftTests {
    func collect(_ service: VoiceService, timeout: Double = 2) async -> [VoiceEvent] {
        let task = Task {
            var out: [VoiceEvent] = []
            for await e in service.events { out.append(e) }
            return out
        }
        try? await Task.sleep(for: .seconds(timeout))
        service.shutdown()
        return await task.value
    }

    #if os(macOS)
    @Test func startOnMacEmitsPermissionFalseAndError() async {
        let v = VoiceService()
        await v.start()
        await v.start()   // idempotent
        let events = await collect(v, timeout: 0.2)
        #expect(events.first == .permission(microphone: false, speech: false))
        #expect(events.contains { if case .error = $0 { true } else { false } })
        #expect(!events.contains(.ready))
    }
    #endif

    @Test func speakingBeforeStartIsHarmless() async {
        let v = VoiceService()
        v.say("Hello!", style: .standard)
        v.stream("Hi there. ", style: .standard)
        v.endStream()
        v.laugh(intensity: 0.8)
        v.stopSpeaking()
        let events = await collect(v, timeout: 0.5)
        #expect(events.contains { if case .error = $0 { true } else { false } })
        #expect(!events.contains(.speakingStarted))
    }

    @Test func listeningFlagRoundTrips() {
        let v = VoiceService()
        #expect(v.listeningEnabled)
        v.listeningEnabled = false
        #expect(!v.listeningEnabled)
        v.shutdown()
        v.shutdown()
        v.say("after shutdown", style: .standard)
    }
}

@Suite struct AudioBufferTests {
    func stereoSine(rate: Double, frames: Int) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 {
            for i in 0..<frames { b.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * 300 * Double(i) / rate)) }
        }
        return b
    }

    @Test func deepCopyIsIndependent() throws {
        let b = stereoSine(rate: 48_000, frames: 480)
        let c = try #require(b.deepCopy())
        #expect(c.firstChannelSamples() == b.firstChannelSamples())
        b.floatChannelData![0][0] = 0.9
        #expect(c.floatChannelData![0][0] != 0.9)
    }

    @Test func convertsToSpeechFormat() throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let conv = BufferConverter(target: target)
        let out = try #require(conv.convert(stereoSine(rate: 48_000, frames: 4800)))
        #expect(out.format == target)
        #expect(out.frameLength > 1200 && out.frameLength <= 1700, "\(out.frameLength)")
        let samples = out.firstChannelSamples()
        #expect(Level.rmsDB(samples) > -15)
        // Second call reuses the converter and still works.
        #expect(conv.convert(stereoSine(rate: 48_000, frames: 4800)) != nil)
    }

    @Test func int16SamplesAreScaled() throws {
        let f = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let b = try #require(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 4))
        b.frameLength = 4
        b.int16ChannelData![0][0] = 16_384
        b.int16ChannelData![0][1] = -32_768
        let s = b.firstChannelSamples()
        #expect(s[0] == 0.5 && s[1] == -1)
    }
}
