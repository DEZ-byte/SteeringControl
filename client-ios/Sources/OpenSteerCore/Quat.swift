import Foundation

/// Grouped as CPython groups `math.degrees` and `math.radians`, which multiply by
/// a single precomputed constant. Writing `x * .pi / 180` instead would differ in
/// the last bit and make the two references disagree for no useful reason.
public let degreesToRadians = Double.pi / 180.0
public let radiansToDegrees = 180.0 / Double.pi

/// A unit quaternion in `(w, x, y, z)` order.
///
/// CoreMotion hands out `CMQuaternion` in `(x, y, z, w)` order, so the one place
/// that conversion happens is `MotionEngine`. Everything below this line is in
/// `(w, x, y, z)` and matches `tools/twistmath.py` term for term.
public struct Quat: Sendable, Equatable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public var conjugate: Quat {
        Quat(w: w, x: -x, y: -y, z: -z)
    }

    /// Hamilton product: `(w1,v1) ⊗ (w2,v2) = (w1w2 − v1·v2, w1v2 + w2v1 + v1×v2)`.
    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    /// Rotation of `degrees` about an axis, which does not have to be unit length.
    public static func axisAngle(x ax: Double, y ay: Double, z az: Double,
                                 degrees: Double) -> Quat {
        let n = (ax * ax + ay * ay + az * az).squareRoot()
        let ux = ax / n, uy = ay / n, uz = az / n
        let half = degrees * degreesToRadians / 2.0
        let s = sin(half)
        return Quat(w: cos(half), x: ux * s, y: uy * s, z: uz * s)
    }

    public static func rx(_ degrees: Double) -> Quat {
        axisAngle(x: 1, y: 0, z: 0, degrees: degrees)
    }

    public static func ry(_ degrees: Double) -> Quat {
        axisAngle(x: 0, y: 1, z: 0, degrees: degrees)
    }

    public static func rz(_ degrees: Double) -> Quat {
        axisAngle(x: 0, y: 0, z: 1, degrees: degrees)
    }

    /// The `w` and `z` components of `q_rel = conj(qRef) ⊗ qCur`, and nothing else.
    ///
    /// The discarded `x` and `y` components are the swing, which is exactly the
    /// tilt we do not want to read as steering. Eight multiply-adds instead of
    /// sixteen, and the parts we would have thrown away are never computed.
    ///
    /// Argument order is load-bearing. `qCur ⊗ conj(qRef)` is the same rotation
    /// expressed in the *world* frame, so its Z component shrinks by roughly
    /// cos(tilt): at an 85-degree recline it reports under a tenth of the real
    /// turn. See the TV3 fixture.
    public static func relWZ(_ qRef: Quat, _ qCur: Quat) -> (w: Double, z: Double) {
        let w = qRef.w * qCur.w + qRef.x * qCur.x + qRef.y * qCur.y + qRef.z * qCur.z
        let z = qRef.w * qCur.z - qRef.x * qCur.y + qRef.y * qCur.x - qRef.z * qCur.w
        return (w, z)
    }
}
