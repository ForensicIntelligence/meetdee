@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import DeeWake

/// Fixture audio (Fixtures/audio.json): macOS `say` voices + the voice-harness clips, 16 kHz mono.
struct FixtureItem: Codable, Sendable {
    var id: String
    var file: String
    var text: String
    var voice: String
    var kind: String          // positive | onset | negative | harness-dee | bed
    var phrase: String?
    var carrier: String
    var samples16k: Int
    var phraseStart16k: Int?
    var phraseEnd16k: Int?
}

enum Fixtures {
    static let directory: URL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static let items: [FixtureItem] = {
        struct Manifest: Codable { var items: [FixtureItem] }
        let data = try! Data(contentsOf: directory.appendingPathComponent("audio.json"))
        return try! JSONDecoder().decode(Manifest.self, from: data).items
    }()

    static func item(_ id: String) -> FixtureItem { items.first { $0.id == id }! }

    static let words10k: [String] = {
        let s = try! String(contentsOf: directory.appendingPathComponent("words-10k.txt"), encoding: .utf8)
        return s.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }()

    /// 16 kHz mono PCM16 samples of a fixture file (exact length for WAV; AAC priming is
    /// trimmed by AVAudioFile).
    static func samples(_ item: FixtureItem) throws -> [Int16] {
        let url = directory.appendingPathComponent(item.file)
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        if file.processingFormat.commonFormat == .pcmFormatInt16 && file.processingFormat.sampleRate == 16_000 {
            return Array(UnsafeBufferPointer(start: src.int16ChannelData![0], count: Int(src.frameLength)))
        }
        let conv = AVAudioConverter(from: src.format, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: src.frameLength + 4096)!
        nonisolated(unsafe) var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }
}

/// Collects segments from the real recogniser.
final class SegmentLog: Sendable {
    private let all = Mutex<[SpeechSegment]>([])
    func append(_ s: SpeechSegment) { all.withLock { $0.append(s) } }
    var segments: [SpeechSegment] { all.withLock { $0 } }
}

enum Recognizer {
    /// Whether the real on-device recogniser can run here (skip-with-reason otherwise).
    static let available: Bool = {
        let box = Mutex<EarAvailability?>(nil)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let a = await OnDeviceSpeech.availability(requireAuthorization: false)
            box.withLock { $0 = a }
            sem.signal()
        }
        sem.wait()
        return box.withLock { $0 } == .ready
    }()

    /// Run fixture samples through a fresh `OnDeviceSpeech`, 100 ms chunks, frame of the
    /// first sample = `startFrame24k`; finalize at the end; all segments in order.
    static func run(_ samples: [Int16], contextual: [String], startFrame24k: Int64 = 0, punctuation: Bool = true, speechTranscriber: Bool = false) async throws -> [SpeechSegment] {
        let speech = OnDeviceSpeech()
        let log = SegmentLog()
        let stream = await speech.results()
        let collector = Task { for await s in stream { log.append(s) } }
        try await speech.start(.init(contextualStrings: contextual, punctuation: punctuation, speechTranscriber: speechTranscriber))
        var i = 0
        while i < samples.count {
            let n = min(1600, samples.count - i)
            speech.feed(Array(samples[i..<(i + n)]), captureFrame24k: startFrame24k + Int64(i) * 3 / 2)
            i += n
        }
        await speech.finish()
        try? await Task.sleep(for: .milliseconds(50))
        collector.cancel()
        return log.segments
    }
}

extension Fixtures {
    /// The pinned real-recogniser corpus (MeasureCorpus → corpus.json).
    static let corpus: [WakeCorpus.Recognition] = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("corpus.json"))
        return try! JSONDecoder().decode([WakeCorpus.Recognition].self, from: data)
    }()
}
