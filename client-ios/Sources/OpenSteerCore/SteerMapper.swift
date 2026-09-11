import Foundation

/// How far **the phone** turns, lock to lock, in degrees.
///
/// This is not the car's steering lock and it is not a physical wheel's rotation.
/// It is how far you rotate the phone in your hands to command full lock, and the
/// two numbers have nothing to do with each other.
///
/// Getting this backwards is the easiest mistake in the project, and the values
/// below exist to make it hard. A real 900 degree wheel turns two and a half
/// times. Hands holding a phone manage about 90 degrees each way before the arms
/// cross over, so a phone set to 900 can only ever ask for 90/450, which is a
/// fifth of the car's lock, no matter how hard the driver tries. The symptom is a
/// car that will barely turn.
///
/// So the useful range is roughly twice whatever the wrists can comfortably
/// reach, and every option here is in that range.
public enum DegreesOfRotation: Int, Sendable, CaseIterable, Identifiable {
    /// Quick hands. Full lock at 60 degrees of phone rotation each way.
    case dor120 = 120
    case dor150 = 150
    /// The default. Full lock at 90 degrees each way, which is about as far as
    /// most people can turn without regripping.
    case dor180 = 180
    case dor240 = 240
    /// Needs a regrip to reach full lock, so it suits drifting and anything where
    /// the wheel is wound on slowly and held.
    case dor360 = 360

    public var id: Int { rawValue }
    public var degrees: Double { Double(rawValue) }
    public var label: String { "\(rawValue)°" }

    /// How far the phone must rotate from centre to reach full lock.
    public var wristReachDegrees: Double { Double(rawValue) / 2.0 }
}

/// Turns a continuous steering angle into the wire axis value.
///
/// Invariant I9: this shaping happens exactly once, here on the phone. The host
/// has no shaper at all, so what the phone sends is what the game receives. That
/// is why `--dor` on the daemon is print-only.
public struct SteerMapper: Sendable, Equatable {
    /// A touch of deadband stops thumb tremor registering as steering input.
    public static let defaultDeadband = 0.01

    /// Above 1 this softens the centre and sharpens the ends, which is what makes
    /// a phone feel like a wheel rather than a switch.
    public static let defaultGamma = 1.15

    public var degreesOfRotation: Double
    public var deadband: Double
    public var gamma: Double

    public init(degreesOfRotation: Double = 360,
                deadband: Double = SteerMapper.defaultDeadband,
                gamma: Double = SteerMapper.defaultGamma) {
        self.degreesOfRotation = degreesOfRotation
        self.deadband = deadband
        self.gamma = gamma
    }

    public init(dor: DegreesOfRotation,
                deadband: Double = SteerMapper.defaultDeadband,
                gamma: Double = SteerMapper.defaultGamma) {
        self.init(degreesOfRotation: dor.degrees, deadband: deadband, gamma: gamma)
    }

    /// `f(x) = sign(x) · max(0, (|x| − δ) / (1 − δ))^γ`
    ///
    /// The rescale by `1 − δ` matters: without it the deadband would also cap the
    /// output below full lock, so the driver could never reach the stops.
    public static func shape(_ x: Double, deadband: Double, gamma: Double) -> Double {
        let sign: Double = x < 0 ? -1 : 1
        var magnitude = abs(x)

        if deadband > 0 {
            magnitude = max(0, (magnitude - deadband) / (1 - deadband))
        }

        return sign * pow(magnitude, gamma)
    }

    /// Positive steer is clockwise as the driver sees it, which is a negative
    /// right-hand rotation about the screen normal. Hence the leading minus.
    public func normalized(continuousDegrees: Double) -> Double {
        var x = -continuousDegrees / (degreesOfRotation / 2.0)
        x = min(1.0, max(-1.0, x))
        return Self.shape(x, deadband: deadband, gamma: gamma)
    }

    /// Half away from zero, grouped exactly as `AxisMath.RoundHalfAway` in the C#
    /// core and `round_half_away` in the Python reference. A plain `.rounded()`
    /// agrees on every value we care about, but writing it out keeps the three
    /// implementations obviously identical instead of merely probably identical.
    public static func roundHalfAway(_ v: Double) -> Int {
        Int(v >= 0 ? (v + 0.5).rounded(.down) : (v - 0.5).rounded(.up))
    }

    /// Invariant I10: senders never emit −32768. It is the one Int16 with no
    /// positive twin, so a game that mirrors the axis would see a value it cannot
    /// represent, and the host has to spend a branch saturating it.
    public static func int16(fromNormalized norm: Double) -> Int16 {
        let v = roundHalfAway(norm * 32767.0)
        return Int16(min(32767, max(-32767, v)))
    }

    public func steer(continuousDegrees: Double) -> Int16 {
        Self.int16(fromNormalized: normalized(continuousDegrees: continuousDegrees))
    }
}
