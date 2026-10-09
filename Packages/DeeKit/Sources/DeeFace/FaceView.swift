import Foundation
import Observation
import SwiftUI

/// Dee's live face. Feed it inputs; it animates itself.
///
/// Frame rate follows what is on screen (see `FaceFrameRate`): 60 Hz by default,
/// the display's full rate (120 Hz on ProMotion) only while blinking, saccading or
/// speaking, and 30 Hz while asleep, under Reduce Motion, in Low Power Mode or when
/// the device is hot (thermal state serious or worse).
public struct FaceView: View {
    public var inputs: FaceInputs
    public var renderer: FaceRenderer
    @State private var driver = Driver()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(inputs: FaceInputs, renderer: FaceRenderer = FaceRenderer()) {
        self.inputs = inputs
        self.renderer = renderer
    }

    public var body: some View {
        let interval = FaceFrameRate.minimumInterval(
            sleeping: inputs.activity == .sleeping,
            wantsHighFrameRate: driver.wantsHighFrameRate,
            reduceMotion: reduceMotion,
            lowPower: driver.lowPower,
            thermal: driver.thermal
        )
        TimelineView(.animation(minimumInterval: interval)) { timeline in
            var current = inputs
            let _ = current.reduceMotion = reduceMotion
            let frame = driver.frame(at: timeline.date, inputs: current)
            Canvas(rendersAsynchronously: false) { context, size in
                renderer.draw(frame, in: &context, size: size)
            }
        }
        .task { await driver.observePower() }
        .accessibilityElement()
        .accessibilityLabel("Dee looks \(inputs.emotion.rawValue)")
    }

    /// Holds the animator across frames. Only the frame-rate inputs are observed;
    /// the animator itself is ignored so stepping it during body evaluation doesn't
    /// invalidate the view.
    @MainActor @Observable final class Driver {
        @ObservationIgnored var animator = FaceAnimator(seed: UInt64.random(in: 1...UInt64.max))
        @ObservationIgnored var last: Date?
        /// Keep the high rate a moment after the animator stops asking (no flapping).
        @ObservationIgnored var highUntil: Date?
        @ObservationIgnored private var pendingHigh: Bool?

        private(set) var wantsHighFrameRate = false
        private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        private(set) var thermal = ProcessInfo.processInfo.thermalState

        func frame(at date: Date, inputs: FaceInputs) -> FaceFrame {
            let dt = last.map { date.timeIntervalSince($0) } ?? 1.0 / 60
            last = date
            let frame = animator.step(dt, inputs: inputs)
            if animator.wantsHighFrameRate { highUntil = date.addingTimeInterval(0.25) }
            let high = highUntil.map { date < $0 } ?? false
            // Changing observed state mid-update is not allowed; apply it right after.
            if high != (pendingHigh ?? wantsHighFrameRate) {
                pendingHigh = high
                Task { @MainActor [weak self] in
                    guard let self, let want = self.pendingHigh else { return }
                    self.pendingHigh = nil
                    if self.wantsHighFrameRate != want { self.wantsHighFrameRate = want }
                }
            }
            return frame
        }

        /// Tracks Low Power Mode and thermal state for as long as the view is on screen.
        func observePower() async {
            refreshPower()
            async let thermalChanges: Void = watch(ProcessInfo.thermalStateDidChangeNotification)
            async let powerChanges: Void = watch(.NSProcessInfoPowerStateDidChange)
            _ = await (thermalChanges, powerChanges)
        }

        private func watch(_ name: Notification.Name) async {
            for await _ in NotificationCenter.default.notifications(named: name) { refreshPower() }
        }

        private func refreshPower() {
            let info = ProcessInfo.processInfo
            if lowPower != info.isLowPowerModeEnabled { lowPower = info.isLowPowerModeEnabled }
            if thermal != info.thermalState { thermal = info.thermalState }
        }
    }
}

/// Frame-rate policy for the live face, kept pure so it can be tested.
public enum FaceFrameRate {
    public static let low = 1.0 / 30
    public static let normal = 1.0 / 60
    public static let high = 1.0 / 120

    /// Minimum seconds between frames.
    public static func minimumInterval(sleeping: Bool, wantsHighFrameRate: Bool, reduceMotion: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Double {
        if sleeping || reduceMotion || lowPower || thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return low
        }
        return wantsHighFrameRate ? high : normal
    }
}
