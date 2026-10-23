import SwiftUI
import UIKit
import OpenSteerCore

/// The two thumb zones, as a raw UIKit touch surface.
///
/// SwiftUI gestures go through recognizer arbitration, which can delay or steal a
/// touch while it decides whether you meant something else. For a brake pedal
/// that is unacceptable. `touchesBegan` and friends fire immediately and are the
/// only way to track two thumbs deterministically, one per zone, with no chance
/// of the system reassigning them mid-corner.
struct PedalTouchView: UIViewRepresentable {
    /// Fraction of the screen width each pedal zone occupies, measured from its
    /// own edge. The middle half holds the wheel, the heads-up display and every
    /// button, the paddles included.
    static let zoneWidthFraction: CGFloat = 0.25

    var travel: Double
    /// Called on the main actor whenever either pedal changes.
    var onChange: (_ throttle: Double, _ brake: Double) -> Void

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.travel = travel
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: TouchSurface, context: Context) {
        view.travel = travel
        view.onChange = onChange
    }

    final class TouchSurface: UIView {
        var travel: Double = PedalMapper.defaultTravel {
            didSet {
                throttle.travel = travel
                brake.travel = travel
            }
        }

        var onChange: ((Double, Double) -> Void)?

        private var throttle = PedalMapper()
        private var brake = PedalMapper()

        // One tracked touch per zone. A second thumb landing in a zone that is
        // already busy is ignored rather than taking over, so a stray palm cannot
        // steal the brake.
        private var throttleTouch: UITouch?
        private var brakeTouch: UITouch?

        private enum Zone { case brake, throttle, neither }

        // Each zone runs the full height of the glass with nothing cut out of it.
        // A pedal applies as the thumb slides up, so a thumb at full travel ends
        // up near the top of its zone, and the next press can land there. The
        // paddles therefore sit in the middle half with the other buttons rather
        // than in the top corners.
        private func zone(for point: CGPoint) -> Zone {
            let edge = bounds.width * PedalTouchView.zoneWidthFraction
            if point.x < edge { return .brake }
            if point.x > bounds.width - edge { return .throttle }
            return .neither
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let point = touch.location(in: self)
                switch zone(for: point) {
                case .brake where brakeTouch == nil:
                    brakeTouch = touch
                    brake.began(at: point.y)
                case .throttle where throttleTouch == nil:
                    throttleTouch = touch
                    throttle.began(at: point.y)
                default:
                    continue
                }
            }
            report()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let y = touch.location(in: self).y
                if touch === brakeTouch { brake.moved(to: y) }
                if touch === throttleTouch { throttle.moved(to: y) }
            }
            report()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            release(touches)
        }

        /// A cancel is a phone call arriving, or the system taking over the touch.
        /// Treating it as anything other than a full release would leave the
        /// throttle pinned open with nobody touching the screen.
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            release(touches)
        }

        private func release(_ touches: Set<UITouch>) {
            for touch in touches {
                if touch === brakeTouch {
                    brakeTouch = nil
                    brake.ended()
                }
                if touch === throttleTouch {
                    throttleTouch = nil
                    throttle.ended()
                }
            }
            report()
        }

        private func report() {
            onChange?(throttle.value, brake.value)
        }
    }
}
