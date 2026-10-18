import Foundation

/// Turns a wrapped ±180 degree angle into a continuous one.
///
/// `2·atan2` can only ever return ±180 degrees. A 900-degree wheel needs ±450, so
/// without this the driver hits an invisible wall at half a turn and the axis
/// jumps to the opposite lock. Each step takes the shortest path between the
/// previous reading and the new one and adds it to a running total, which is
/// correct as long as the wheel cannot move more than 180 degrees between two
/// samples. At 120 Hz that is 21 600 degrees per second, so it holds.
public struct AngleUnwrapper: Sendable {
    private var previous: Double?

    /// The accumulated angle in degrees, unbounded.
    public private(set) var total: Double = 0

    public init() {}

    /// Forgets the history. Call this together with recalibration, or the first
    /// sample after a recenter gets treated as a real jump.
    public mutating func reset() {
        previous = nil
        total = 0
    }

    @discardableResult
    public mutating func step(_ degrees: Double) -> Double {
        guard let last = previous else {
            previous = degrees
            total = degrees
            return total
        }

        var delta = degrees - last
        while delta > 180.0 { delta -= 360.0 }
        while delta < -180.0 { delta += 360.0 }

        total += delta
        previous = degrees
        return total
    }
}
