@preconcurrency import AVFoundation
import Foundation
import os
import Vision

/// What the camera noticed.
public enum SenseUpdate: Sendable, Equatable {
    case presence(PresenceTracker.Event)
    /// Where the person's face is (−1…1), or nil when nobody is in view.
    case look(SIMD2<Double>?)
    case gesture(Gesture)
}

/// Dee's eyes on the world: the front camera, analysed on-device with Vision.
///
/// The sensor runs at 15 fps and low resolution with at most one frame in flight.
/// Faces are analysed at `framesPerSecond` (12 by default); hand pose only while
/// someone is in view, at ≤ 6 fps until a hand shows up (then at the face rate
/// for a moment so a wave isn't aliased). `isDozing` drops to ~2 fps, face only;
/// Low Power Mode or a serious thermal state halves everything.
///
/// Leaving is detected from time passing (a timer on the capture queue), so an
/// interrupted or stopped camera reads as "nobody here" rather than freezing the
/// last state. Presence and gesture events are never dropped (the stream is
/// unbounded; look updates are only sent when the position actually moves).
///
/// Nothing is recorded or stored; frames are dropped as soon as Vision is done.
public final class CameraSense: NSObject, @unchecked Sendable {
    public enum Failure: Error, Sendable { case denied, noCamera, configuration }

    public let updates: AsyncStream<SenseUpdate>
    private let continuation: AsyncStream<SenseUpdate>.Continuation

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "dee.camera", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let log = Logger(subsystem: "ca.forensicintelligence.dee", category: "camera")

    // Touched only on `captureQueue`.
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var watchdog: DispatchSourceTimer?
    private var appliedDeviceFPS = 0.0
    // Set in init, removed once in `shutdown()`/deinit.
    private var observers: [any NSObjectProtocol] = []

    struct State {
        var busy = false
        var pacer = SensePacer()
        var presence = PresenceTracker()
        var gestures = GestureRecognizer()
        var lastLook: SIMD2<Double>?
        var lastFaceFound = false
        var configured = false
        var wantsRunning = false
        var restartAttempts = 0
        var finished = false
    }

    /// Face-analysis rate cap (≥ 1).
    public var framesPerSecond: Double {
        get { state.withLock { $0.pacer.framesPerSecond } }
        set { state.withLock { $0.pacer.framesPerSecond = max(1, newValue.isFinite ? newValue : 1) } }
    }

    /// Set while Dee sleeps: ~2 fps, face only — enough to notice someone arriving.
    public var isDozing: Bool {
        get { state.withLock { $0.pacer.dozing } }
        set {
            state.withLock { $0.pacer.dozing = newValue }
            captureQueue.async { self.applyDeviceFrameRate() }
        }
    }

    public override init() {
        (updates, continuation) = AsyncStream.makeStream(of: SenseUpdate.self, bufferingPolicy: .unbounded)
        super.init()
        continuation.onTermination = { [weak self] _ in self?.stop() }
        observeSession()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        watchdog?.cancel()
        rotationObservation?.invalidate()
        continuation.finish()
        let session = session
        captureQueue.async { if session.isRunning { session.stopRunning() } }
    }

    public static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    public func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw Failure.denied }
        default: throw Failure.denied
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                do {
                    guard !self.state.withLock({ $0.finished }) else { throw Failure.configuration }
                    try self.configureIfNeeded()
                    self.state.withLock { $0.wantsRunning = true; $0.restartAttempts = 0 }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.applyDeviceFrameRate()
                    self.startWatchdog()
                    c.resume()
                } catch {
                    Self.log.error("camera start failed: \(String(describing: error), privacy: .public)")
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the camera. Whoever was in view counts as gone (a stopped camera sees nobody).
    public func stop() {
        captureQueue.async {
            self.state.withLock { $0.wantsRunning = false }
            if self.session.isRunning { self.session.stopRunning() }
            self.watchdog?.cancel()
            self.watchdog = nil
            self.forgetEveryone(reason: "stopped")
        }
    }

    /// Stops the camera for good and finishes `updates`. Idempotent.
    public func shutdown() {
        let first = state.withLock { s -> Bool in
            defer { s.finished = true; s.wantsRunning = false }
            return !s.finished
        }
        guard first else { return }
        let tokens = observers
        captureQueue.async {
            for o in tokens { NotificationCenter.default.removeObserver(o) }
            if self.session.isRunning { self.session.stopRunning() }
            self.watchdog?.cancel()
            self.watchdog = nil
            self.rotationObservation?.invalidate()
            self.rotationObservation = nil
            self.continuation.finish()
        }
    }

    // MARK: - Configuration (captureQueue)

    private func configureIfNeeded() throws {
        guard !state.withLock({ $0.configured }) else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw Failure.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        #if os(iOS)
        // iPad Split View / Slide Over / Stage Manager: keep seeing while multitasking.
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        #endif
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.configuration }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // Mirrored, so image-left is the user's left.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        self.device = device
        // Upright for any orientation (iPad rotates all four ways): follow the
        // coordinator's horizon-level capture angle instead of assuming portrait.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            guard let self else { return }
            self.captureQueue.async { self.applyRotation(angle) }
        }
        state.withLock { $0.configured = true }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
    }

    /// Locks the sensor to the rate the pacer needs (15 fps awake, lower when dozing or
    /// constrained) so the ISP isn't producing frames we'd only throw away.
    private func applyDeviceFrameRate() {
        guard let device else { return }
        let want = state.withLock { $0.pacer.deviceFramesPerSecond }
        guard want != appliedDeviceFPS else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let lo = ranges.map(\.minFrameRate).min(), let hi = ranges.map(\.maxFrameRate).max() else { return }
        let fps = min(max(want, lo), hi)
        do {
            try device.lockForConfiguration()
            let duration = CMTime(seconds: 1 / fps, preferredTimescale: 600)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            appliedDeviceFPS = want
        } catch {
            Self.log.error("frame-rate lock failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Interruptions

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reason = Self.interruptionReason(note)
            guard let self else { return }
            self.captureQueue.async { self.handleInterruption(reason: reason) }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.captureQueue.async { self.handleInterruptionEnded() }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "unknown"
            guard let self else { return }
            self.captureQueue.async { self.handleRuntimeError(error) }
        })
    }

    private static func interruptionReason(_ note: Notification) -> String {
        #if os(iOS)
        if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int { return "reason \(raw)" }
        #endif
        return "unknown reason"
    }

    private func handleInterruption(reason: String) {
        Self.log.notice("camera interrupted (\(reason, privacy: .public))")
        // The session stops delivering frames; nobody can be seen until it resumes.
        forgetEveryone(reason: "interrupted")
    }

    private func handleInterruptionEnded() {
        Self.log.notice("camera interruption ended")
        state.withLock { $0.restartAttempts = 0 }
        appliedDeviceFPS = 0
        applyDeviceFrameRate()
    }

    private func handleRuntimeError(_ error: String) {
        Self.log.error("camera runtime error: \(error, privacy: .public)")
        forgetEveryone(reason: "runtime error")
        let attempt = state.withLock { s -> Int? in
            guard s.wantsRunning, !s.finished, s.restartAttempts < 5 else { return nil }
            s.restartAttempts += 1
            return s.restartAttempts
        }
        guard let attempt else { return }
        // Back off: 0.5 s, 1 s, 2 s, ...
        captureQueue.asyncAfter(deadline: .now() + 0.5 * pow(2, Double(attempt - 1))) {
            guard self.state.withLock({ $0.wantsRunning && !$0.finished }), !self.session.isRunning else { return }
            Self.log.notice("restarting camera (attempt \(attempt))")
            self.session.startRunning()
            self.appliedDeviceFPS = 0
            self.applyDeviceFrameRate()
        }
    }

    /// Resets presence and gestures, telling the app if someone was here.
    private func forgetEveryone(reason: String) {
        let t = Self.hostNow
        let out = state.withLock { s -> [SenseUpdate] in
            var out: [SenseUpdate] = []
            if let e = s.presence.reset(at: t) { out.append(.presence(e)) }
            s.gestures = GestureRecognizer()
            s.lastFaceFound = false
            if s.lastLook != nil {
                s.lastLook = nil
                out.append(.look(nil))
            }
            return out
        }
        for u in out { continuation.yield(u) }
    }

    // MARK: - Watchdog (captureQueue)

    /// Lets time pass for the presence tracker even when no frames arrive, and keeps the
    /// pacer's Low Power / thermal view current.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let t = Self.hostNow
        let out = state.withLock { s -> [SenseUpdate] in
            s.pacer.constrained = constrained
            var out: [SenseUpdate] = []
            if let e = s.presence.tick(at: t) { out.append(.presence(e)) }
            if s.presence.position == nil, s.lastLook != nil {
                s.lastLook = nil
                out.append(.look(nil))
            }
            if !s.presence.isPresent { _ = s.gestures.update(nil, at: t) }
            return out
        }
        applyDeviceFrameRate()
        for u in out { continuation.yield(u) }
    }

    // MARK: - Analysis

    /// Monotonic seconds on the host clock (the clock capture timestamps use).
    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// A frame's presentation time on the host clock (monotonic; immune to wall-clock changes).
    private func frameTime(_ sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return Self.hostNow }
        let host = CMClockGetHostTimeClock()
        let t = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: host) } ?? pts
        return t.isValid && t.seconds.isFinite ? t.seconds : Self.hostNow
    }

    fileprivate func analyze(_ buffer: PixelBufferBox, at t: Double, hands runHands: Bool) async {
        // One handler for both requests, so Vision prepares the image once.
        let handler = ImageRequestHandler(buffer.value)
        let faceRequest = DetectFaceRectanglesRequest()
        var faces: [FaceObservation]?
        var hands: [HumanHandPoseObservation]?
        if runHands {
            var handRequest = DetectHumanHandPoseRequest()
            handRequest.maximumHandCount = 1
            if let r = try? await handler.perform(faceRequest, handRequest) { (faces, hands) = (r.0, r.1) }
        } else {
            faces = try? await handler.perform(faceRequest)
        }

        let face = faces?.max { $0.boundingBox.width < $1.boundingBox.width }
        let hand = hands?.first.map(Self.pose)

        let out: [SenseUpdate] = state.withLock { s in
            var out: [SenseUpdate] = []
            defer { s.busy = false }
            guard !s.finished else { return out }
            let box = face.map { f -> (center: SIMD2<Double>, width: Double) in
                let r = f.boundingBox.cgRect
                return (SIMD2(Double(r.midX), Double(r.midY)), Double(r.width))
            }
            s.lastFaceFound = box != nil
            if let event = s.presence.update(face: box, at: t) { out.append(.presence(event)) }
            let look = s.presence.position
            if Self.lookChanged(from: s.lastLook, to: look) {
                s.lastLook = look
                out.append(.look(look))
            }
            if runHands {
                s.pacer.handResult(found: hand != nil, at: t)
                if let g = s.gestures.update(hand, at: t) { out.append(.gesture(g)) }
            } else if !s.presence.isPresent {
                _ = s.gestures.update(nil, at: t)
            }
            return out
        }
        for u in out { continuation.yield(u) }
    }

    /// Look updates are sent only when the face moved noticeably (or appeared/vanished).
    static func lookChanged(from old: SIMD2<Double>?, to new: SIMD2<Double>?, epsilon: Double = 0.01) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a.x - b.x) > epsilon || abs(a.y - b.y) > epsilon
        default: return true
        }
    }

    static func pose(_ obs: HumanHandPoseObservation) -> HandPose {
        let map: [(HumanHandPoseObservation.JointName, HandJoint)] = [
            (.wrist, .wrist), (.thumbTip, .thumbTip), (.thumbIP, .thumbIP), (.thumbMP, .thumbMP),
            (.indexTip, .indexTip), (.indexPIP, .indexPIP), (.indexMCP, .indexMCP),
            (.middleTip, .middleTip), (.middlePIP, .middlePIP), (.middleMCP, .middleMCP),
            (.ringTip, .ringTip), (.ringPIP, .ringPIP), (.ringMCP, .ringMCP),
            (.littleTip, .littleTip), (.littlePIP, .littlePIP), (.littleMCP, .littleMCP),
        ]
        var joints: [HandJoint: SIMD2<Double>] = [:]
        for (vision, ours) in map {
            if let j = obs.joint(for: vision), j.confidence > 0.3 {
                joints[ours] = SIMD2(Double(j.location.x), Double(j.location.y))
            }
        }
        return HandPose(joints)
    }
}

extension CameraSense: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = frameTime(sampleBuffer)
        let plan = state.withLock { s -> Bool? in
            // Frames are flowing again: a successful restart earns a fresh retry budget.
            s.restartAttempts = 0
            guard !s.busy, !s.finished, s.pacer.admit(at: t) else { return nil }
            s.busy = true
            return s.pacer.wantsHands(at: t, someoneHere: s.presence.isPresent || s.lastFaceFound)
        }
        guard let runHands = plan, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if plan != nil { state.withLock { $0.busy = false } }
            return
        }
        let box = PixelBufferBox(pixels)
        Task { await self.analyze(box, at: t, hands: runHands) }
    }
}

/// Decides which frames get analysed and which also get hand pose. Pure, so testable.
struct SensePacer: Sendable {
    /// Face-analysis rate while awake and unconstrained.
    var framesPerSecond = 12.0
    /// Hand-pose rate while scanning for a hand.
    var handFramesPerSecond = 6.0
    /// Face-only rate while Dee sleeps.
    var dozeFramesPerSecond = 2.0
    /// Seconds after a hand is seen during which hand pose runs at the face rate
    /// (a 2–3 Hz wave needs more than 6 samples a second).
    var handBurst = 1.5
    var dozing = false
    /// Low Power Mode or thermal state serious/critical.
    var constrained = false

    private var nextFrame = -Double.infinity
    private var nextHand = -Double.infinity
    private var handActiveUntil = -Double.infinity

    /// Effective face-analysis rate.
    var faceRate: Double {
        if dozing { return dozeFramesPerSecond }
        let fps = max(1, framesPerSecond)
        return constrained ? max(1, fps / 2) : fps
    }

    /// Effective hand scan rate (nil = no hand pose at all).
    var handRate: Double? {
        if dozing { return nil }
        return constrained ? handFramesPerSecond / 2 : handFramesPerSecond
    }

    /// What the sensor should deliver.
    var deviceFramesPerSecond: Double {
        if dozing { return 5 }
        return max(constrained ? 10 : 15, min(faceRate, 30))
    }

    /// Paces analysed frames to `faceRate` (token bucket, so 15 fps in / 12 fps out
    /// averages 12 rather than collapsing to every other frame).
    mutating func admit(at t: Double) -> Bool {
        let interval = 1 / faceRate
        guard t >= nextFrame - 0.005 else { return false }
        nextFrame = t - nextFrame > interval ? t + interval : nextFrame + interval
        return true
    }

    /// Whether this admitted frame should also run hand pose.
    mutating func wantsHands(at t: Double, someoneHere: Bool) -> Bool {
        guard let rate = handRate, someoneHere else { return false }
        let interval = t < handActiveUntil ? 1 / faceRate : 1 / rate
        guard t >= nextHand - 0.005 else { return false }
        nextHand = t - nextHand > interval ? t + interval : nextHand + interval
        return true
    }

    mutating func handResult(found: Bool, at t: Double) {
        if found { handActiveUntil = t + handBurst }
    }
}

/// CVPixelBuffer is thread-safe to read once captured; Swift just can't prove it.
struct PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ v: CVPixelBuffer) { value = v }
}
