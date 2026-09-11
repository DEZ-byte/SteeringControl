import Foundation

/// Uplink button bits. Level-triggered on the wire; the host does its own edge
/// detection, so the phone only has to report what is held right now.
public struct ButtonMask: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let upshift = ButtonMask(rawValue: 1 << 0)
    public static let downshift = ButtonMask(rawValue: 1 << 1)
    public static let handbrake = ButtonMask(rawValue: 1 << 2)
}

/// Holds a momentary press on the wire for a few packets.
///
/// A paddle tap can easily be shorter than one 8.3 ms uplink tick, so a naive
/// level report would send the bit in zero packets and the shift would never
/// happen. Worse, a single packet carrying the bit can be the one that gets lost.
/// Three ticks means a tap survives both, and at 120 Hz it still clears in 25 ms,
/// well under the time anyone can tap twice.
public struct PulseLatch: Sendable {
    public static let defaultMinimumTicks = 3

    public let minimumTicks: Int
    private var remaining: Int = 0
    private var held: Bool = false

    public init(minimumTicks: Int = PulseLatch.defaultMinimumTicks) {
        self.minimumTicks = max(1, minimumTicks)
    }

    /// The button went down. Arms the latch.
    public mutating func press() {
        held = true
        remaining = minimumTicks
    }

    /// The button came up. The latch keeps reporting until its ticks run out.
    public mutating func release() {
        held = false
    }

    /// Advance one uplink tick and report whether the bit should be set.
    public mutating func tick() -> Bool {
        if remaining > 0 {
            remaining -= 1
            return true
        }
        return held
    }

    public var isActive: Bool { held || remaining > 0 }
}
