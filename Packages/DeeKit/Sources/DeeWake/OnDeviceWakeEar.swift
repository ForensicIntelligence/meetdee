import Foundation
import Synchronization

/// The real wake ear: Apple on-device recognition (`OnDeviceSpeech`) + `WakeDetector`.
///
/// Nothing here touches the network. While started it listens to the shared
/// recogniser's results; `consume` keeps the energy ring, asks for a final after a
/// 0.3 s pause and feeds the recogniser. If the ear can't run (permission, assets,
/// heat) it publishes the availability and stays quiet — never server recognition,
/// never streaming everything; a tap still wakes Dee.
public final class OnDeviceWakeEar: WakeEar {
    public static let user = "wake"

    private struct State {
        var running = false
        var listening = false     // recogniser up and fed
        var detector = WakeDetector(matcher: WakeMatcher(.default))
        var phrase = WakePhrase.default
        var strict = false
        var thermalPaused = false
    }

    public let speech: OnDeviceSpeech
    public let locale: Locale
    private let requireAuthorization: Bool
    private let state = Mutex(State())
    private let hitCast = Broadcast<WakeHit>()
    private let candidateCast = Broadcast<Void>()
    private let availabilityCast = Broadcast<EarAvailability>(replayLast: true)
    private let listenTask = Mutex<Task<Void, Never>?>(nil)
    private let thermalTask = Mutex<Task<Void, Never>?>(nil)

    public init(speech: OnDeviceSpeech = OnDeviceSpeech(), locale: Locale = Locale(identifier: "en-US"),
                requireAuthorization: Bool = OnDeviceSpeech.defaultRequiresAuthorization) {
        self.speech = speech
        self.locale = locale
        self.requireAuthorization = requireAuthorization
    }

    public var hits: AsyncStream<WakeHit> { hitCast.stream }
    public var candidates: AsyncStream<Void> { candidateCast.stream }
    public var availability: AsyncStream<EarAvailability> { availabilityCast.stream }

    public var isListening: Bool { state.withLock { $0.listening } }

    public func start(phrase: WakePhrase) async {
        state.withLock { s in
            s.running = true
            s.phrase = phrase
            s.detector = WakeDetector(matcher: WakeMatcher(phrase, .tuned, strict: s.strict))
        }
        await bringUp()
        watchThermal()
    }

    public func stop() async {
        state.withLock { $0.running = false; $0.listening = false }
        listenTask.withLock { $0?.cancel(); $0 = nil }
        thermalTask.withLock { $0?.cancel(); $0 = nil }
        await speech.release(Self.user)
    }

    public func setPhrase(_ phrase: WakePhrase) async {
        let running = state.withLock { s -> Bool in
            s.phrase = phrase
            s.detector.setMatcher(WakeMatcher(phrase, .tuned, strict: s.strict))
            return s.running && s.listening
        }
        if running { try? await speech.acquire(Self.user, config(phrase)) }
    }

    public func setStrict(_ strict: Bool) async {
        state.withLock { s in
            s.strict = strict
            s.detector.setMatcher(WakeMatcher(s.phrase, .tuned, strict: strict))
        }
    }

    public func consume(_ pcm16k: [Int16], captureFrame24k: Int64) {
        let pause = state.withLock { s -> Int64? in
            guard s.running, s.listening, !s.thermalPaused else { return nil }
            return s.detector.audio(pcm16k, captureFrame24k: captureFrame24k)
        }
        guard state.withLock({ $0.running && $0.listening && !$0.thermalPaused }) else { return }
        speech.feed(pcm16k, captureFrame24k: captureFrame24k)
        if let pause {
            let speech = self.speech
            Task { await speech.finalize(throughFrame24k: pause) }
        }
    }

    // MARK: - Internals

    private func config(_ phrase: WakePhrase) -> OnDeviceSpeech.Configuration {
        OnDeviceSpeech.Configuration(locale: locale, contextualStrings: phrase.contextualStrings, detector: false, punctuation: true)
    }

    private func bringUp() async {
        let a = await OnDeviceSpeech.availability(locale: locale, requireAuthorization: requireAuthorization)
        guard a == .ready else {
            state.withLock { $0.listening = false }
            availabilityCast.yield(a)
            return
        }
        let phrase = state.withLock { $0.phrase }
        let stream = await speech.results()
        do {
            try await speech.acquire(Self.user, config(phrase))
        } catch {
            state.withLock { $0.listening = false }
            availabilityCast.yield(error.availability)
            return
        }
        state.withLock { $0.listening = true }
        availabilityCast.yield(.ready)
        let task = Task { [weak self] in
            for await segment in stream {
                guard let self else { return }
                self.handle(segment)
            }
        }
        listenTask.withLock { $0?.cancel(); $0 = task }
    }

    private func handle(_ segment: SpeechSegment) {
        let out = state.withLock { s -> WakeDetector.Output? in
            guard s.running, s.listening else { return nil }
            return s.detector.segment(segment)
        }
        guard let out else { return }
        if out.candidate { candidateCast.yield(()) }
        if let hit = out.hit { hitCast.yield(hit) }
        if let f = out.finalizeThrough {
            let speech = self.speech
            Task { await speech.finalize(throughFrame24k: f) }
        }
    }

    private func watchThermal() {
        let task = Task { [weak self] in
            var last = ProcessInfo.processInfo.thermalState
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let now = ProcessInfo.processInfo.thermalState
                guard now != last, let self else { last = now; continue }
                last = now
                let hot = now.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                let changed = self.state.withLock { s -> Bool in
                    defer { s.thermalPaused = hot }
                    return s.thermalPaused != hot
                }
                if changed { self.availabilityCast.yield(hot ? .thermalBackoff : .ready) }
            }
        }
        thermalTask.withLock { $0?.cancel(); $0 = task }
    }
}
