import AVFAudio
import CoreMedia
import Foundation
import SoundAnalysis

/// Apple's built-in sound classifier (SoundAnalysis v1, ~300 classes) on the
/// microphone tap. Analysis runs on its own queue because `analyze` may block.
final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    /// Top results plus the host-time span (seconds, `systemUptime`) of the audio
    /// they describe, when it could be worked out.
    var onResult: (@Sendable ([(identifier: String, confidence: Double)], ClosedRange<Double>?) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "dee.voice.sound", qos: .utility)
    private let lock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var position: AVAudioFramePosition = 0
    private var backlog = 0
    private var failed = false
    private var stopped = false
    /// Host time of stream frame 0 (`position == 0`), re-estimated every buffer.
    private var hostTimeOrigin: Double?

    /// Called from the input tap thread; copies the buffer and analyzes it later.
    /// `hostTime` is when the buffer's last sample was captured (systemUptime).
    func analyze(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil) {
        guard reserve() else { return }
        guard let copy = buffer.deepCopy() else { release(); return }
        let box = UncheckedBox(copy)
        queue.async { [weak self] in
            guard let self else { return }
            self.process(box.value, hostTime: hostTime)
            self.release()
        }
    }

    /// Takes a backlog slot; false when analysis is off or saturated.
    func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !stopped, backlog < Self.maxBacklog else { return false }
        backlog += 1
        return true
    }

    /// Returns a backlog slot (every `reserve()` that returned true, on every path).
    func release() {
        lock.lock(); backlog = max(0, backlog - 1); lock.unlock()
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return backlog }

    static let maxBacklog = 8

    /// Host-time span of a result's stream range, given the stream's origin.
    static func hostWindow(origin: Double?, start: Double, duration: Double) -> ClosedRange<Double>? {
        guard let origin, start.isFinite, duration.isFinite, duration >= 0 else { return nil }
        return (origin + start)...(origin + start + duration)
    }

    private func process(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        if analyzer == nil || format != buffer.format {
            analyzer?.removeAllRequests()
            analyzer = nil
            let a = SNAudioStreamAnalyzer(format: buffer.format)
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
                request.overlapFactor = 0.5
                try a.add(request, withObserver: self)
            } catch {
                lock.lock(); failed = true; lock.unlock()
                onError?("Sound recognition unavailable: \(error.localizedDescription)")
                return
            }
            analyzer = a
            format = buffer.format
            position = 0
        }
        let rate = buffer.format.sampleRate
        lock.lock()
        hostTimeOrigin = (hostTime != nil && rate > 0)
            ? hostTime! - Double(position + AVAudioFramePosition(buffer.frameLength)) / rate
            : nil
        lock.unlock()
        analyzer?.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(buffer.frameLength)
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [weak self] in
            self?.analyzer?.removeAllRequests()
            self?.analyzer = nil
        }
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let top = r.classifications
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map { (identifier: $0.identifier, confidence: $0.confidence) }
        lock.lock(); let origin = hostTimeOrigin; lock.unlock()
        let window = Self.hostWindow(origin: origin, start: r.timeRange.start.seconds,
                                     duration: r.timeRange.duration.seconds)
        onResult?(Array(top), window)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError?("Sound recognition stopped: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
