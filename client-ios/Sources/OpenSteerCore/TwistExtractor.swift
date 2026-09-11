import Foundation

/// Pulls the steering angle out of a device attitude.
///
/// Invariant I1. The angle is the pure twist about the device +Z axis, which is
/// the screen normal pointing out at the driver. It is NOT `atan2(gravity.y,
/// gravity.x)` and it is NOT a planar projection of any vector. Those two look
/// right on a desk and fall apart in a chair: at an 85-degree recline the
/// projection reads a real 10-degree turn as 7.71 degrees, and with the phone
/// flat on a table it reads a 30-degree turn as exactly zero. Both failures are
/// pinned as fixtures (TV3 and TV3b) so nobody can quietly reintroduce them.
public struct TwistExtractor: Sendable {
    /// Below this, `w² + z²` means the swing is near 180 degrees and the twist is
    /// genuinely undefined rather than merely small. Holding the last angle is the
    /// only honest answer; snapping to zero would yank the wheel.
    public static let degenerateEpsilon = 1e-9

    public private(set) var lastDegrees: Double = 0

    public init() {}

    public mutating func reset() {
        lastDegrees = 0
    }

    /// Wrapped twist about the calibration frame's +Z, in degrees, bounded to ±180.
    ///
    /// Feed the result to `AngleUnwrapper` before mapping it to an axis, or a
    /// 900-degree wheel can never travel past half a turn.
    public mutating func step(reference qRef: Quat, current qCur: Quat) -> Double {
        let degrees = Self.twistDegrees(reference: qRef, current: qCur,
                                        previous: lastDegrees)
        lastDegrees = degrees
        return degrees
    }

    public static func twistDegrees(reference qRef: Quat, current qCur: Quat,
                                    previous: Double) -> Double {
        var (w, z) = Quat.relWZ(qRef, qCur)

        if (w * w + z * z) < degenerateEpsilon {
            return previous
        }

        // q and −q are the same rotation. Without this the angle flips by a full
        // turn as the sign of w crosses zero, which the unwrapper would then
        // faithfully accumulate as a real 360-degree spin.
        if w < 0 {
            w = -w
            z = -z
        }

        // The twist quaternion is (w, 0, 0, z) normalised, but the normalisation
        // cancels inside atan2, so it is never computed.
        //
        // Grouped exactly as CPython's math.degrees(2 * atan2(z, w)) groups it, so
        // the Swift and Python references agree to the last bit rather than merely
        // to the fixture tolerance.
        return (2.0 * atan2(z, w)) * radiansToDegrees
    }
}
