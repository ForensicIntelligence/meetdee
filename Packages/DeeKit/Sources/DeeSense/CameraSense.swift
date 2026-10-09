@preconcurrency import AVFoundation
import CoreImage
import Foundation
import os
import Vision

/// What the camera noticed.
public enum SenseUpdate: Sendable, Equatable {
    case presence(PresenceTracker.Event)
    /// Where the person's face is (−1…1), or nil when nobody is in view.
    case look(SIMD2<Double>?)
    case gesture(Gesture)
    /// Something worth noticing through either camera: sent when a glance holds
    /// something novel, otherwise at most every ~30 s per camera.
    case sight(SightReport)
    /// v0.5: the present person's head pose in **degrees**, from the face observation
    /// already computed (no extra Vision work). `yaw`: 0 = facing the camera, sign as
    /// Vision reports it on the mirrored frame (use |yaw|). `pitch`: negative = looking
    /// down. Sent when someone arrives and then only when either angle moves by ≥ 3°.
    case head(yaw: Double, pitch: Double)
    /// v0.5: every face in the frame, biggest first, for recognition — sent immediately
    /// on arrival and then about every 1.5 s (3 s when constrained) while someone is present.
    case faces([FaceCrop])
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
/// Sight: every ~3 s one front frame is classified (Vision's ClassifyImageRequest
/// plus the cat/dog recogniser) into a few concrete things; with `lookAround` on and
/// a device that supports multi-cam capture, the back camera also runs at the lowest
/// frame rate its format allows (typically 1–2 fps) and is classified every ~4 s. Without multi-cam support the back
/// camera is simply skipped (the front session is never torn down for it). No
/// classification while dozing; the back camera is switched off then.
///
/// Head pose (`.head`) comes free with the face request. Face crops for recognition
/// (`.faces`) are made on arrival and then every ~1.5 s while someone is present: only
/// on those frames does Vision's face-capture-quality request run (fed the faces the
/// face request already found) and the frame get copied into a `CGImage`.
/// `glanceNow(_:)` classifies one frame on demand, bypassing the sight pacer.
///
/// Nothing is recorded or stored; frames are dropped as soon as Vision is done (a
/// `.faces` frame is a private copy handed to the app, never kept here).
public final class CameraSense: NSObject, @unchecked Sendable {
    public enum Failure: Error, Sendable { case denied, noCamera, configuration }

    public let updates: AsyncStream<SenseUpdate>
    private let continuation: AsyncStream<SenseUpdate>.Continuation

    private let session: AVCaptureSession
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
    // Back camera (multi-cam only), touched only on `captureQueue`.
    private var backInput: AVCaptureDeviceInput?
    private var backOutput: AVCaptureVideoDataOutput?
    private var backConnection: AVCaptureConnection?
    private var backRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var backRotationObservation: NSKeyValueObservation?
    private var backUnavailable = false
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
        // Sight.
        var lookAround = false
        var sight = SightPacer()
        var novelty = NoveltyMemory()
        var labels = SightLabels()
        var sightBusy: Set<CameraSide> = []
        // v0.5.
        var head = HeadPoseFilter()
        var facesPacer = FacesPacer()
        var glances = GlanceRequests()
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
            state.withLock { $0.pacer.dozing = newValue; $0.sight.dozing = newValue }
            captureQueue.async {
                self.applyDeviceFrameRate()
                self.updateBackCamera()
            }
        }
    }

    /// Scan the back camera too (multi-cam devices only; ignored elsewhere).
    public var lookAround: Bool {
        get { state.withLock { $0.lookAround } }
        set {
            state.withLock { $0.lookAround = newValue }
            captureQueue.async { self.updateBackCamera() }
        }
    }

    /// Whether this device can watch through both cameras at once.
    public static var supportsLookAround: Bool {
        #if os(iOS)
        return AVCaptureMultiCamSession.isMultiCamSupported
        #else
        return false
        #endif
    }

    /// Classifies one frame right now, bypassing the sight pacer, and always sends the
    /// result as `.sight` with `requested == true` (even when nothing was recognised).
    /// `.back` uses the back camera when this device can run it alongside the front
    /// (multi-cam), switching it on just for this glance if `lookAround` is off (the
    /// first ~0.35 s of frames are skipped while it exposes); otherwise the front camera
    /// answers. Works while dozing. Ignored while the camera is stopped; a request no
    /// frame answers within ~2 s is dropped silently.
    public func glanceNow(_ side: CameraSide) {
        captureQueue.async {
            guard self.state.withLock({ $0.wantsRunning && !$0.finished }) else { return }
            let t = Self.hostNow
            let backAvailable = self.isMultiCam && !self.backUnavailable
            let backRunning = self.backConnection?.isEnabled == true
            let used = self.state.withLock {
                $0.glances.request(side, at: t, backAvailable: backAvailable, backRunning: backRunning)
            }
            if used == .back { self.updateBackCamera() }
        }
    }

    public override init() {
        #if os(iOS)
        // A multi-cam session (when supported) so the back camera can join and leave
        // without ever reconfiguring the front one.
        session = AVCaptureMultiCamSession.isMultiCamSupported ? AVCaptureMultiCamSession() : AVCaptureSession()
        #else
        session = AVCaptureSession()
        #endif
        (updates, continuation) = AsyncStream.makeStream(of: SenseUpdate.self, bufferingPolicy: .unbounded)
        super.init()
        continuation.onTermination = { [weak self] _ in self?.stop() }
        observeSession()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        watchdog?.cancel()
        rotationObservation?.invalidate()
        backRotationObservation?.invalidate()
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
                    self.updateBackCamera()
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
            self.state.withLock { $0.wantsRunning = false; $0.glances.removeAll() }
            if self.session.isRunning { self.session.stopRunning() }
            self.watchdog?.cancel()
            self.watchdog = nil
            self.updateBackCamera()
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
            self.backRotationObservation?.invalidate()
            self.backRotationObservation = nil
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
        #if os(iOS)
        // iPad Split View / Slide Over / Stage Manager: keep seeing while multitasking.
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        #endif
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.configuration }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if isMultiCam {
            #if os(iOS)
            // Multi-cam sessions have no presets: pick a small multi-cam format by hand
            // and cap the rate we pay hardware bandwidth for.
            if !Self.chooseFormat(for: device, minFrameRate: 15) { backUnavailable = true }
            session.addInputWithNoConnections(input)
            session.addOutputWithNoConnections(output)
            guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: .front).first else {
                throw Failure.configuration
            }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw Failure.configuration }
            session.addConnection(connection)
            // (30, not 15: the pacer may ask for up to 30 fps, and the device's frame
            // duration must never go below this override.)
            if Self.supports(device, fps: 30) { input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30) }
            #endif
        } else {
            session.sessionPreset = .vga640x480
            session.addInput(input)
            session.addOutput(output)
        }
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

    private var isMultiCam: Bool {
        #if os(iOS)
        return session is AVCaptureMultiCamSession
        #else
        return false
        #endif
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

    #if os(iOS)
    /// Sets the smallest multi-cam-capable format that still gives ≥ 640×480 at
    /// `minFrameRate`. False when the device has no multi-cam format.
    private static func chooseFormat(for device: AVCaptureDevice, minFrameRate: Double) -> Bool {
        let formats = device.formats
        let candidates = formats.map { f -> FormatCandidate in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return FormatCandidate(
                width: Int(d.width), height: Int(d.height), multiCam: f.isMultiCamSupported, binned: f.isVideoBinned,
                fullRange420: CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                maxFrameRate: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        guard let i = FormatChoice.pick(candidates, minFrameRate: minFrameRate) else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = formats[i]
            device.unlockForConfiguration()
            return true
        } catch {
            log.error("format selection failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    #endif

    private static func supports(_ device: AVCaptureDevice, fps: Double) -> Bool {
        device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
    }

    // MARK: - Back camera (captureQueue)

    /// Brings the back camera in or out to match `lookAround`, dozing and running.
    /// Multi-cam only; the input is added once and then just enabled/disabled, which
    /// AVCaptureMultiCamSession does without disturbing the front camera.
    private func updateBackCamera() {
        #if os(iOS)
        guard isMultiCam, state.withLock({ $0.configured }) else { return }
        let wanted = state.withLock {
            ($0.lookAround && !$0.pacer.dozing || $0.glances.wants(.back)) && $0.wantsRunning && !$0.finished
        }
        if wanted, !backUnavailable, backConnection == nil { addBackCamera() }
        if backUnavailable { state.withLock { $0.glances.backUnavailable(at: Self.hostNow) } }
        let want = wanted && !backUnavailable
        guard let connection = backConnection, connection.isEnabled != want else { return }
        connection.isEnabled = want
        Self.log.notice("back camera \(want ? "on" : "off", privacy: .public)")
        #endif
    }

    #if os(iOS)
    private func addBackCamera() {
        guard let multi = session as? AVCaptureMultiCamSession, let front = device,
              let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            backUnavailable = true
            return
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(front) && $0.contains(back) }),
              Self.chooseFormat(for: back, minFrameRate: 5) else {
            Self.log.notice("front+back multi-cam not supported here; looking forward only")
            backUnavailable = true
            return
        }
        // Glanced at only every ~4 s: run the sensor as slowly as the format allows.
        let ranges = back.activeFormat.videoSupportedFrameRateRanges.map { (min: $0.minFrameRate, max: $0.maxFrameRate) }
        let backFPS = BackCameraRate.pick(ranges: ranges) ?? 5
        do {
            try back.lockForConfiguration()
            if !ranges.isEmpty {
                let duration = CMTime(seconds: 1 / backFPS, preferredTimescale: 600)
                back.activeVideoMinFrameDuration = duration
                back.activeVideoMaxFrameDuration = duration
            }
            back.unlockForConfiguration()
        } catch {
            Self.log.error("back camera lock failed: \(String(describing: error), privacy: .public)")
        }
        guard let input = try? AVCaptureDeviceInput(device: back) else { backUnavailable = true; return }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(out) else {
            session.commitConfiguration()
            backUnavailable = true
            return
        }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(out)
        var connection: AVCaptureConnection?
        if let port = input.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first {
            let c = AVCaptureConnection(inputPorts: [port], output: out)
            if session.canAddConnection(c) { session.addConnection(c); connection = c }
        }
        if connection != nil, Self.supports(back, fps: backFPS) {
            input.videoMinFrameDurationOverride = CMTime(seconds: 1 / backFPS, preferredTimescale: 600)
        }
        session.commitConfiguration()

        // Too expensive for this device right now: give up on the back camera
        // rather than risk the front one.
        if connection == nil || multi.hardwareCost > 1 || multi.systemPressureCost > 1 {
            Self.log.notice("back camera too costly (hw \(multi.hardwareCost), pressure \(multi.systemPressureCost)); looking forward only")
            session.beginConfiguration()
            if let connection { session.removeConnection(connection) }
            session.removeInput(input)
            session.removeOutput(out)
            session.commitConfiguration()
            backUnavailable = true
            return
        }
        backInput = input
        backOutput = out
        backConnection = connection
        let coordinator = AVCaptureDevice.RotationCoordinator(device: back, previewLayer: nil)
        backRotationCoordinator = coordinator
        applyBackRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        backRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            guard let self else { return }
            self.captureQueue.async { self.applyBackRotation(angle) }
        }
    }

    private func applyBackRotation(_ angle: CGFloat) {
        guard let connection = backConnection, connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
    }
    #endif

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
        state.withLock { $0.restartAttempts = 0; $0.sight.reset() }
        appliedDeviceFPS = 0
        applyDeviceFrameRate()
        updateBackCamera()
    }

    private func handleRuntimeError(_ error: String) {
        Self.log.error("camera runtime error: \(error, privacy: .public)")
        forgetEveryone(reason: "runtime error")
        #if os(iOS)
        // If the back camera was running, it is the first suspect: drop it for good so
        // the front camera (presence, gaze, gestures) keeps working.
        if let back = backConnection, back.isEnabled {
            Self.log.notice("dropping the back camera after a runtime error")
            back.isEnabled = false
            backUnavailable = true
            state.withLock { $0.glances.backUnavailable(at: Self.hostNow) }
        }
        #endif
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
            s.head.forget()
            s.facesPacer.reset()
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
        let (out, expired) = state.withLock { s -> ([SenseUpdate], Bool) in
            s.pacer.constrained = constrained
            s.sight.constrained = constrained
            s.facesPacer.constrained = constrained
            let expired = s.glances.expire(at: t)
            var out: [SenseUpdate] = []
            if let e = s.presence.tick(at: t) { out.append(.presence(e)) }
            if !s.presence.isPresent {
                s.head.forget()
                s.facesPacer.reset()
            }
            if s.presence.position == nil, s.lastLook != nil {
                s.lastLook = nil
                out.append(.look(nil))
            }
            if !s.presence.isPresent { _ = s.gestures.update(nil, at: t) }
            return (out, expired)
        }
        applyDeviceFrameRate()
        if expired { updateBackCamera() }
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
        // One handler for all requests, so Vision prepares the image once.
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

        let observed = faces ?? []
        let detected = observed.map(Self.detected)
        let face = detected.max { $0.box.width < $1.box.width }
        let hand = hands?.first.map(Self.pose)

        let (out, wantsCrops): ([SenseUpdate], Bool) = state.withLock { s in
            var out: [SenseUpdate] = []
            guard !s.finished else { s.busy = false; return (out, false) }
            let box = face.map { f -> (center: SIMD2<Double>, width: Double) in
                (SIMD2(Double(f.box.midX), Double(f.box.midY)), Double(f.box.width))
            }
            s.lastFaceFound = box != nil
            let event = s.presence.update(face: box, at: t)
            if let event { out.append(.presence(event)) }
            let look = s.presence.position
            if Self.lookChanged(from: s.lastLook, to: look) {
                s.lastLook = look
                out.append(.look(look))
            }
            if s.presence.isPresent {
                if let face, let pose = s.head.update(visionYaw: face.yaw, visionPitch: face.pitch) {
                    out.append(.head(yaw: pose.yaw, pitch: pose.pitch))
                }
            } else {
                s.head.forget()
            }
            let crops = s.facesPacer.due(at: t, present: s.presence.isPresent, arrived: event == .arrived,
                                         faceFound: !detected.isEmpty)
            if runHands {
                s.pacer.handResult(found: hand != nil, at: t)
                if let g = s.gestures.update(hand, at: t) { out.append(.gesture(g)) }
            } else if !s.presence.isPresent {
                _ = s.gestures.update(nil, at: t)
            }
            // A crop frame keeps the one-frame-in-flight slot until the crops are made.
            if !crops { s.busy = false }
            return (out, crops)
        }
        for u in out { continuation.yield(u) }
        guard wantsCrops else { return }
        await sendCrops(buffer, handler: handler, observed: observed, detected: detected)
        state.withLock { $0.busy = false }
    }

    /// The 1.5 s recognition tick: capture quality for the faces already found, one
    /// upright copy of the frame, and `.faces` (unless they left meanwhile).
    private func sendCrops(_ buffer: PixelBufferBox, handler: ImageRequestHandler,
                           observed: [FaceObservation], detected: [DetectedFace]) async {
        var request = DetectFaceCaptureQualityRequest()
        request.inputFaceObservations = observed
        let scored = (try? await handler.perform(request)) ?? []
        let qualities = scored.compactMap { o -> (box: CGRect, score: Double)? in
            o.captureQuality.map { (o.boundingBox.cgRect, Double($0.score)) }
        }
        guard let image = Self.cgImage(buffer.value) else { return }
        let crops = FaceCrops.make(image: image, faces: detected, qualities: qualities)
        guard !crops.isEmpty, state.withLock({ !$0.finished && $0.presence.isPresent }) else { return }
        continuation.yield(.faces(crops))
    }

    static func detected(_ f: FaceObservation) -> DetectedFace {
        DetectedFace(box: f.boundingBox.cgRect,
                     yaw: f.yaw.converted(to: .degrees).value,
                     roll: f.roll.converted(to: .degrees).value,
                     pitch: f.pitch.converted(to: .degrees).value)
    }

    /// Thread-safe; created on first use (only `.faces` frames use it).
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// A private RGBA copy of a camera frame (never retains the capture buffer).
    static func cgImage(_ pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        return imageContext.createCGImage(image, from: image.extent)
    }

    /// Classifies one frame into a few things and reports them if worth it (always,
    /// when `requested` by `glanceNow`).
    fileprivate func glance(_ buffer: PixelBufferBox, camera: CameraSide, requested: Bool, at t: Double) async {
        let handler = ImageRequestHandler(buffer.value)
        let classify = ClassifyImageRequest()
        let animals = RecognizeAnimalsRequest()
        var labels: [(identifier: String, confidence: Double)] = []
        var pets: [(identifier: String, confidence: Double)] = []
        if let (observations, found) = try? await handler.perform(classify, animals) {
            labels = observations.compactMap { o in
                let c = Double(o.confidence)
                guard c >= 0.15 else { return nil }
                // Keep only labels whose own precision/recall curve says this score is
                // trustworthy; plain threshold when the label has no curve.
                let trusted = o.hasPrecisionRecallCurve ? o.hasMinimumRecall(0.01, forPrecision: 0.85) : c >= 0.5
                return trusted ? (o.identifier, c) : nil
            }
            pets = found.compactMap { o in o.labels.first.map { ($0.identifier, Double(o.confidence)) } }
        }
        let (labelsSeen, petsSeen) = (labels, pets)
        let report: SightReport? = state.withLock { s in
            defer { s.sightBusy.remove(camera) }
            guard !s.finished else { return nil }
            if requested {
                let things = s.labels.pick(labelsSeen, animals: petsSeen)
                return SightReport(camera: camera, things: things, novel: s.novelty.glance(things, at: t), requested: true)
            }
            guard !s.pacer.dozing else { return nil }
            let things = s.labels.pick(labelsSeen, animals: petsSeen)
            let novel = s.novelty.glance(things, at: t)
            guard s.sight.shouldReport(camera, things: things, novel: novel, at: t) else { return nil }
            return SightReport(camera: camera, things: things, novel: novel)
        }
        if let report { continuation.yield(.sight(report)) }
        // A back camera switched on only for this glance goes off again.
        if requested, camera == .back { captureQueue.async { self.updateBackCamera() } }
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
        if let back = backOutput, output === back {
            let admit = state.withLock { s -> Bool? in
                guard !s.finished, !s.sightBusy.contains(.back) else { return nil }
                if s.glances.take(.back, at: t) {
                    s.sightBusy.insert(.back)
                    return true
                }
                guard s.lookAround, s.sight.admit(.back, at: t) else { return nil }
                s.sightBusy.insert(.back)
                return false
            }
            guard let requested = admit else { return }
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                state.withLock { _ = $0.sightBusy.remove(.back) }
                return
            }
            let box = PixelBufferBox(pixels)
            Task { await self.glance(box, camera: .back, requested: requested, at: t) }
            return
        }
        let (plan, look) = state.withLock { s -> (Bool?, Bool?) in
            // Frames are flowing again: a successful restart earns a fresh retry budget.
            s.restartAttempts = 0
            guard !s.finished else { return (nil, nil) }
            var look: Bool?
            if !s.sightBusy.contains(.front) {
                if s.glances.take(.front, at: t) {
                    s.sightBusy.insert(.front)
                    look = true
                } else if s.sight.admit(.front, at: t) {
                    s.sightBusy.insert(.front)
                    look = false
                }
            }
            guard !s.busy, s.pacer.admit(at: t) else { return (nil, look) }
            s.busy = true
            return (s.pacer.wantsHands(at: t, someoneHere: s.presence.isPresent || s.lastFaceFound), look)
        }
        let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        if let requested = look {
            if let pixels {
                let box = PixelBufferBox(pixels)
                Task { await self.glance(box, camera: .front, requested: requested, at: t) }
            } else {
                state.withLock { _ = $0.sightBusy.remove(.front) }
            }
        }
        guard let runHands = plan, let pixels else {
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
