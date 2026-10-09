import AVFAudio
import Foundation

/// Plays prepared audio into the microphone's place in real time — for the iOS
/// Simulator (no usable mic or voice processing), XCUITests and harness runs.
///
/// Enabled with `DEE_VOICE_INJECT=<path>`. The path is either one audio file or a
/// JSON manifest:
///
///     { "leadIn": 2.0, "loop": false,
///       "items": [ { "file": "hi.wav", "gap": 1.5 }, { "file": "how-are-you.wav" } ] }
///
/// `file` paths are relative to the manifest. `gap` is silence *before* the item
/// (default 1.0 s), `leadIn` silence before everything (default 1.0 s). Between and
/// after the items the injector keeps feeding silence, exactly like a quiet room,
/// so the VAD and endpointing see what they would see live. `loop` restarts the
/// script after the last item.
final class AudioInjector: @unchecked Sendable {
    static let sampleRate = 24_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    static let chunkFrames = 480                      // 20 ms

    struct Manifest: Decodable {
        struct Item: Decodable {
            var file: String
            var gap: Double?
        }
        var leadIn: Double?
        var loop: Bool?
        var items: [Item]
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self { case .unreadable(let why): "Voice injection: \(why)" }
        }
    }

    /// The whole script rendered at 24 kHz mono.
    let script: [Float]
    let loop: Bool

    private let queue = DispatchQueue(label: "dee.voice.inject", qos: .userInitiated)
    private var timer: DispatchSourceTimer?             // queue-confined
    private var origin = 0.0                            // queue-confined
    private var pushed: Int64 = 0                       // queue-confined

    init(script: [Float], loop: Bool) {
        self.script = script
        self.loop = loop
    }

    /// Loads a manifest or a single audio file.
    convenience init(url: URL) throws {
        if url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable("can't read \(url.path)") }
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch {
                throw Failure.unreadable("bad manifest \(url.lastPathComponent): \(error)")
            }
            let base = url.deletingLastPathComponent()
            var script = Self.silence(manifest.leadIn ?? 1)
            for item in manifest.items {
                let file = item.file.hasPrefix("/") ? URL(fileURLWithPath: item.file) : base.appendingPathComponent(item.file)
                script += Self.silence(item.gap ?? 1)
                script += try Self.load(file)
            }
            self.init(script: script, loop: manifest.loop ?? false)
        } else {
            self.init(script: Self.silence(1) + (try Self.load(url)), loop: false)
        }
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: max(0, Int(seconds * sampleRate)))
    }

    /// An audio file as 24 kHz mono float samples.
    static func load(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw Failure.unreadable("can't open \(url.path): \(error.localizedDescription)")
        }
        let converter = BufferConverter(target: format)
        var out: [Float] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            do { try file.read(into: buf, frameCount: 8192) } catch {
                throw Failure.unreadable("can't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            if buf.frameLength == 0 { break }
            if let c = converter.convert(buf) { out += c.firstChannelSamples() }
        }
        if let tail = converter.finish() { out += tail.firstChannelSamples() }
        return out
    }

    /// Samples `start ..< start + count` of the endless signal: the script, then
    /// silence (or the script again when looping).
    func samples(from start: Int64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let n = Int64(script.count)
        guard n > 0 else { return out }
        for i in 0..<count {
            var p = start + Int64(i)
            if loop { p %= n }
            if p < n { out[i] = script[Int(p)] }
        }
        return out
    }

    /// Starts feeding 20 ms buffers in real time. `feed(buffer, hostTimeOfLastSample)`.
    func start(feed: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            origin = ProcessInfo.processInfo.systemUptime
            pushed = 0
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.pump(feed) }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Pushes every chunk that is due by now (catches up after a stall, no drift).
    private func pump(_ feed: @Sendable (AVAudioPCMBuffer, Double) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let due = Int64((now - origin) * Self.sampleRate)
        while pushed + Int64(Self.chunkFrames) <= due {
            let samples = self.samples(from: pushed, count: Self.chunkFrames)
            guard let buf = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else { return }
            buf.frameLength = AVAudioFrameCount(Self.chunkFrames)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: Self.chunkFrames)
            }
            pushed += Int64(Self.chunkFrames)
            feed(buf, origin + Double(pushed) / Self.sampleRate)
        }
    }
}
