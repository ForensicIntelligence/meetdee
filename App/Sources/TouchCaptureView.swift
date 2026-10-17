import DeeCore
import DeeSense
import SwiftUI
import UIKit

/// Captures raw touches on Dee's face — position, contact size and timing — so the
/// touch interpreter can tell a gentle stroke from a poke or a slap. SwiftUI
/// gestures don't expose `majorRadius`, so this is a thin UIKit layer.
struct TouchCaptureView: UIViewRepresentable {
    var onSample: @MainActor (TouchSample) -> Void
    /// A two-finger long-press (0.8 s) opens Dee's settings. The one-finger 0.8 s press
    /// stays the hug (`TouchInterpreter` `.hold`): the recognizer never cancels touches.
    var onTwoFingerHold: @MainActor () -> Void = {}
    /// The current persona (VoiceOver label and hint).
    var persona: PersonaPreset = PersonaCatalog.classic

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onSample = onSample
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.onTwoFingerHold = onTwoFingerHold
        Self.label(view, persona)
        let hold = UILongPressGestureRecognizer(target: view, action: #selector(CaptureView.twoFingerHold(_:)))
        hold.numberOfTouchesRequired = 2
        hold.minimumPressDuration = 0.8
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        view.addGestureRecognizer(hold)
        return view
    }

    /// "Mira", "Tap to talk to her. …" in the persona's pronouns.
    static func label(_ view: UIView, _ p: PersonaPreset) {
        let t = p.text
        view.accessibilityLabel = p.name
        view.accessibilityHint = "Tap to talk to \(t.them). Stroke gently to pet \(t.them). Tap an eye to make \(t.them) blink. Hold with two fingers for the settings."
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        Self.label(view, persona)
        view.onSample = onSample
        view.onTwoFingerHold = onTwoFingerHold
    }

    final class CaptureView: UIView {
        var onSample: (@MainActor (TouchSample) -> Void)?
        var onTwoFingerHold: (@MainActor () -> Void)?

        @objc func twoFingerHold(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            MainActor.assumeIsolated { onTwoFingerHold?() }
        }
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
