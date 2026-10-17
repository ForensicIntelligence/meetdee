import AVFAudio
import Foundation
import Speech

/// Calm round 2: does a sound fixture speak words? Apple's on-device recogniser
/// (`SpeechAnalyzer` + `DictationTranscriber`, en-US, the assets the app and the wake
/// suite already use) transcribes the rendering offline: no key, no network, no cost.
/// `SoundWords.hasWords` then decides. It is a guard, not the live server's ear
/// (gpt-transcribe hallucinates more on noise); it caught the round-1 TTS coughs
/// (a `say` "Cough, cough." is heard as "Cough").
enum WordCheck {
    /// The final transcript of `samples` (24 kHz mono), or nil when the recogniser is
    /// unavailable (locale, assets, or an analyzer error).
    static func transcript(_ samples: [Float], sampleRate: Int = 24_000) async -> String? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return nil }
        let t = DictationTranscriber(locale: locale, contentHints: [.shortForm, .farField], transcriptionOptions: [.punctuation],
                                     reportingOptions: [], attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]),
              let src = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let converter = AVAudioConverter(from: src, to: format) else { return nil }
        // 0.5 s of silence either side: the recogniser finalizes on the tail.
        let pad = [Float](repeating: 0, count: sampleRate / 2)
        let x = pad + samples + pad
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(x.count)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let outCap = AVAudioFrameCount(Double(x.count) * format.sampleRate / Double(sampleRate)) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { return nil }
        nonisolated(unsafe) var fed = false
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil else { return nil }
        let analyzer = SpeechAnalyzer(modules: [t])
        let collect = Task { () -> String in
            var s: [String] = []
            for try await r in t.results where r.isFinal { s.append(String(r.text.characters)) }
            return s.joined(separator: " ")
        }
        do {
            let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            c.yield(AnalyzerInput(buffer: outBuf))
            c.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            collect.cancel()
            return nil
        }
    }
}
