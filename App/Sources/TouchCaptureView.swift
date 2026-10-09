import DeeSense
import SwiftUI
import UIKit

/// Captures raw touches on Dee's face — position, contact size and timing — so the
/// touch interpreter can tell a gentle stroke from a poke or a slap. SwiftUI
/// gestures don't expose `majorRadius`, so this is a thin UIKit layer.
struct TouchCaptureView: UIViewRepresentable {
    var onSample: @MainActor (TouchSample) -> Void

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onSample = onSample
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Dee"
        view.accessibilityHint = "Stroke gently to pet her. Tap an eye to make her blink."
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onSample = onSample
    }

    final class CaptureView: UIView {
        var onSample: (@MainActor (TouchSample) -> Void)?
        private var ids: [ObjectIdentifier: Int] = [:]
        private var nextID = 1

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, .began) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, .moved) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, .ended) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { emit(touches, .cancelled) }

        private func emit(_ touches: Set<UITouch>, _ phase: TouchSample.Phase) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            for touch in touches {
                let key = ObjectIdentifier(touch)
                let id: Int
                if let existing = ids[key] {
                    id = existing
                } else {
                    id = nextID
                    nextID += 1
                    ids[key] = id
                }
                let p = touch.location(in: self)
                let sample = TouchSample(
                    id: id,
                    time: touch.timestamp, // monotonic (seconds since boot)
                    location: SIMD2(Double(p.x / bounds.width), Double(p.y / bounds.height)),
                    majorRadius: Double(touch.majorRadius),
                    phase: phase
                )
                if phase == .ended || phase == .cancelled { ids[key] = nil }
                MainActor.assumeIsolated { onSample?(sample) }
            }
        }
    }
}
