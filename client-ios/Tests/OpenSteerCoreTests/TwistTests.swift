import XCTest
@testable import OpenSteerCore

/// Invariant I1.
final class TwistTests: XCTestCase {
    private let golden = GoldenVectors.shared

    /// 1e-6 radians is about 6e-5 degrees, far tighter than any real sensor and
    /// far looser than the double-precision agreement we actually get.
    private let toleranceDegrees = 1e-6 * 180.0 / Double.pi

    private func quat(_ a: [Double]) -> Quat {
        precondition(a.count == 4)
        return Quat(w: a[0], x: a[1], y: a[2], z: a[3])
    }

    func testTwistVectors() {
        XCTAssertFalse(golden.twist.isEmpty)

        for vector in golden.twist {
            let qRef = quat(vector.qRef)
            let qCur = quat(vector.qCur)

            var extractor = TwistExtractor()
            let theta = extractor.step(reference: qRef, current: qCur)
            XCTAssertEqual(theta, vector.thetaDeg, accuracy: toleranceDegrees, vector.name)

            let mapper = SteerMapper(degreesOfRotation: vector.dorDeg,
                                     deadband: vector.deadband,
                                     gamma: vector.gamma)
            XCTAssertEqual(mapper.normalized(continuousDegrees: theta),
                           vector.steerNorm, accuracy: 1e-9, vector.name)
            XCTAssertEqual(Int(mapper.steer(continuousDegrees: theta)),
                           vector.steerI16, vector.name)
        }
    }

    /// The banned method, restated as a test.
    ///
    /// `atan2(gravity.y, gravity.x)` looks identical to the real thing on a flat
    /// desk. TV3 is a phone reclined 85 degrees and turned 10 degrees: the twist
    /// says 10.000, the projection says 7.706. TV3b is the same recline with no
    /// turn at all: the twist says 0, the projection invents 0.870. A wheel built
    /// on the projection would be 23 per cent short at the angles that matter and
    /// would wander when the driver only shifted in their seat.
    func testNaiveProjectionDisagreesWhereItMatters() {
        for vector in golden.twist where vector.name.hasPrefix("TV3") {
            XCTAssertGreaterThan(abs(vector.thetaDeg - vector.naiveProjectionDeg), 0.5,
                                 "\(vector.name): the fixture no longer distinguishes "
                               + "the twist from the banned projection")
        }

        guard let tv3 = golden.twist.first(where: { $0.name.hasPrefix("TV3-") }) else {
            return XCTFail("TV3 is missing from the fixture")
        }
        var extractor = TwistExtractor()
        let theta = extractor.step(reference: quat(tv3.qRef), current: quat(tv3.qCur))
        XCTAssertGreaterThanOrEqual(theta, 9.99,
                                    "a real 10 degree turn must not read as 7.7")
    }

    /// Tilting the phone without turning it is not steering.
    func testTiltOnlyProducesNoSteering() {
        guard let tv3b = golden.twist.first(where: { $0.name.hasPrefix("TV3b") }) else {
            return XCTFail("TV3b is missing from the fixture")
        }
        var extractor = TwistExtractor()
        let theta = extractor.step(reference: quat(tv3b.qRef), current: quat(tv3b.qCur))
        XCTAssertEqual(theta, 0, accuracy: 1e-9)
        XCTAssertNotEqual(tv3b.naiveProjectionDeg, 0, accuracy: 0.1,
                          "the banned method should invent an angle here")
    }

    /// TV7: a hundred random attitudes, each compared against itself.
    func testIdenticalAttitudesGiveExactlyZero() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let q = Quat(w: .random(in: -1...1, using: &generator),
                         x: .random(in: -1...1, using: &generator),
                         y: .random(in: -1...1, using: &generator),
                         z: .random(in: -1...1, using: &generator))
            let n = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
            guard n > 1e-6 else { continue }
            let unit = Quat(w: q.w / n, x: q.x / n, y: q.y / n, z: q.z / n)

            var extractor = TwistExtractor()
            XCTAssertEqual(extractor.step(reference: unit, current: unit), 0,
                           accuracy: 1e-9)
        }
    }

    /// q and −q are the same rotation. If the sign is not canonicalised, the
    /// angle jumps by a full turn as w crosses zero and the unwrapper faithfully
    /// records a 360 degree spin that never happened.
    func testSignFlipIsInvisible() {
        for vector in golden.twist {
            let qRef = quat(vector.qRef)
            let qCur = quat(vector.qCur)
            let negated = Quat(w: -qCur.w, x: -qCur.x, y: -qCur.y, z: -qCur.z)

            var a = TwistExtractor()
            var b = TwistExtractor()
            XCTAssertEqual(a.step(reference: qRef, current: qCur),
                           b.step(reference: qRef, current: negated),
                           accuracy: 1e-9, vector.name)
        }
    }

    /// Near a 180 degree swing the twist is genuinely undefined. Holding the last
    /// angle is the only safe answer; snapping to zero would yank the wheel
    /// straight at the worst possible moment.
    func testDegenerateSwingHoldsTheLastAngle() {
        var extractor = TwistExtractor()
        let held = extractor.step(reference: .identity, current: Quat.rz(45))
        XCTAssertEqual(held, 45, accuracy: 1e-9)

        // A 180 degree swing about X sends both w and z of the relative
        // quaternion to zero.
        let degenerate = Quat.rx(180)
        XCTAssertEqual(extractor.step(reference: .identity, current: degenerate),
                       held, accuracy: 1e-12)
    }

    /// Argument order is load-bearing: the other order measures the world-frame Z
    /// component, which shrinks by roughly cos(tilt).
    func testReversedArgumentOrderIsWrongAtHighTilt() {
        let qRef = Quat.rx(85)
        let qCur = qRef * Quat.rz(10)

        var extractor = TwistExtractor()
        let correct = extractor.step(reference: qRef, current: qCur)
        XCTAssertEqual(correct, 10, accuracy: 1e-9)

        // The wrong order is qCur ⊗ conj(qRef), which expresses the same rotation
        // in the world frame. Its Z component is the real angle scaled by about
        // cos(85°), so a 10 degree turn arrives as well under one degree.
        let worldFrame = qCur * qRef.conjugate
        let wrong = (2.0 * atan2(worldFrame.z, worldFrame.w)) * radiansToDegrees
        XCTAssertLessThan(abs(wrong), 2.0,
                          "if this fails, the two orders are no longer distinguishable")
    }
}
