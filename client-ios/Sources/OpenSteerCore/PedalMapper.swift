import Foundation

/// A thumb pedal with a floating anchor and a ratchet.
///
/// A fixed on-screen slider fails on a phone that is being waved around: there is
/// no edge to feel for, so the thumb drifts off it mid-corner and the pedal
/// silently sticks. Instead the zero point is wherever the thumb lands. Push up
/// from there to apply, and the value is always relative to that anchor.
///
/// The ratchet keeps it working through a long corner. If the thumb runs past
/// full travel the anchor follows it up, so the pedal stays pinned at 100
/// percent instead of saturating at an anchor the thumb can no longer reach. If
/// the thumb goes back below the anchor, the anchor follows it down, so releasing
/// is always immediate no matter how far the thumb wandered.
public struct PedalMapper: Sendable {
    /// Points of thumb travel for the full range. Around a thumb's comfortable
    /// reach without moving the hand.
    public static let defaultTravel: Double = 140
    public static let minimumTravel: Double = 80
    public static let maximumTravel: Double = 260

    public var travel: Double

    private var anchorY: Double?

    /// Normalized 0...1.
    public private(set) var value: Double = 0

    public init(travel: Double = PedalMapper.defaultTravel) {
        self.travel = max(PedalMapper.minimumTravel,
                          min(PedalMapper.maximumTravel, travel))
    }

    public var isPressed: Bool { anchorY != nil }

    /// Screen coordinates grow downward, so pushing the thumb *up* the screen
    /// gives a smaller y and a larger pedal value.
    public mutating func began(at y: Double) {
        anchorY = y
        value = 0
    }

    public mutating func moved(to y: Double) {
        guard let anchor = anchorY else { return }

        var a = anchor

        // Ratchet both ways before measuring. Doing it in this order rather than
        // after gives the same clamped number with no one-frame lag.
        if y < a - travel {
            a = y + travel
        } else if y > a {
            a = y
        }

        anchorY = a
        value = min(1, max(0, (a - y) / travel))
    }

    /// Lifting the thumb releases the pedal at once. No easing: a throttle that
    /// ramps down after the thumb lifts can spin the car on corner exit.
    public mutating func ended() {
        anchorY = nil
        value = 0
    }

    /// The wire value, 0...65535.
    public var raw: UInt16 {
        UInt16((value * 65535.0).rounded(.toNearestOrAwayFromZero))
    }
}
