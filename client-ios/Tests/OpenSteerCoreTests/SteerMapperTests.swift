import XCTest
@testable import OpenSteerCore

/// Steering shape and Int16 mapping against the golden vectors. Invariants I9
/// and I10.
final class SteerMapperTests: XCTestCase {
    private let golden = GoldenVectors.shared

    func testSteerMapVectors() {
        for vector in golden.steerMap {
            let mapper = SteerMapper(degreesOfRotation: vector.dorDeg,
                                     deadband: vector.deadband,
                                     gamma: vector.gamma)
            let norm = mapper.normalized(continuousDegrees: vector.thetaContDeg)
            XCTAssertEqual(norm, vector.steerNorm, accuracy: 1e-12,
                           "θc \(vector.thetaContDeg)")
            XCTAssertEqual(Int(mapper.steer(continuousDegrees: vector.thetaContDeg)),
                           vector.steerI16, "θc \(vector.thetaContDeg)")
        }
    }

    func testInt16FromNormalized() {
        for vector in golden.steerI16FromNorm {
            XCTAssertEqual(Int(SteerMapper.int16(fromNormalized: vector.norm)),
                           vector.steerI16, "norm \(vector.norm)")
        }
    }

    func testShapeVectors() {
        for vector in golden.shape {
            XCTAssertEqual(SteerMapper.shape(vector.x,
                                             deadband: vector.deadband,
                                             gamma: vector.gamma),
                           vector.y, accuracy: 1e-12, "x \(vector.x)")
        }
    }

    /// Beyond half the degrees of rotation the wheel is on the stops. Without the
    /// clamp the axis would wrap around to the opposite lock, which at speed means
    /// full opposite steering with no warning.
    func testBeyondLockIsClamped() {
        let mapper = SteerMapper(dor: .dor360, deadband: 0, gamma: 1)
        XCTAssertEqual(mapper.steer(continuousDegrees: 180), -32767)
        XCTAssertEqual(mapper.steer(continuousDegrees: 10_000), -32767)
        XCTAssertEqual(mapper.steer(continuousDegrees: -10_000), 32767)
    }

    /// Positive steer is clockwise as the driver sees it, which is a negative
    /// right-hand rotation about the screen normal.
    func testSignConvention() {
        let mapper = SteerMapper(dor: .dor360, deadband: 0, gamma: 1)
        XCTAssertLessThan(mapper.steer(continuousDegrees: 90), 0,
                          "turning counterclockwise must steer left")
        XCTAssertGreaterThan(mapper.steer(continuousDegrees: -90), 0,
                             "turning clockwise must steer right")
    }

    /// Invariant I10, checked across the whole range rather than at a few points.
    func testNeverEmitsMinimumInt16() {
        for dor in DegreesOfRotation.allCases {
            let mapper = SteerMapper(dor: dor)
            for degrees in stride(from: -1000.0, through: 1000.0, by: 0.5) {
                XCTAssertNotEqual(mapper.steer(continuousDegrees: degrees), -32768)
            }
        }
    }

    /// The deadband rescales, so full lock is still reachable. Without the
    /// `1 − δ` divisor the driver could never quite reach the stops.
    func testDeadbandStillReachesFullLock() {
        let mapper = SteerMapper(degreesOfRotation: 360, deadband: 0.05, gamma: 1.0)
        XCTAssertEqual(mapper.steer(continuousDegrees: -180), 32767)
        XCTAssertEqual(mapper.steer(continuousDegrees: 0), 0)

        // Inside the deadband there is no output at all.
        let insideDegrees = -180.0 * 0.04
        XCTAssertEqual(mapper.steer(continuousDegrees: insideDegrees), 0)
    }

    func testRoundHalfAwayFromZero() {
        XCTAssertEqual(SteerMapper.roundHalfAway(0.5), 1)
        XCTAssertEqual(SteerMapper.roundHalfAway(-0.5), -1)
        XCTAssertEqual(SteerMapper.roundHalfAway(1.5), 2)
        XCTAssertEqual(SteerMapper.roundHalfAway(-1.5), -2)
        XCTAssertEqual(SteerMapper.roundHalfAway(2.5), 3)
        XCTAssertEqual(SteerMapper.roundHalfAway(0.4), 0)
        XCTAssertEqual(SteerMapper.roundHalfAway(-0.4), 0)
        XCTAssertEqual(SteerMapper.roundHalfAway(-16383.5), -16384)
    }

    /// More travel for the same angle is what a larger DOR is for.
    func testLargerDorIsLessSensitive() {
        let tight = SteerMapper(dor: .dor180, deadband: 0, gamma: 1)
        let loose = SteerMapper(dor: .dor360, deadband: 0, gamma: 1)
        XCTAssertGreaterThan(abs(Int(tight.steer(continuousDegrees: 30))),
                             abs(Int(loose.steer(continuousDegrees: 30))))
    }

    /// The defaults are gentler than unshaped near the center. The fixture vectors
    /// use δ=0 and γ=1, so this is the only place the shipping defaults are
    /// checked.
    func testDefaultsSoftenTheCentre() {
        let shaped = SteerMapper(dor: .dor360)
        let raw = SteerMapper(dor: .dor360, deadband: 0, gamma: 1)
        XCTAssertEqual(shaped.deadband, 0.01)
        XCTAssertEqual(shaped.gamma, 1.15)
        XCTAssertLessThan(abs(Int(shaped.steer(continuousDegrees: 30))),
                          abs(Int(raw.steer(continuousDegrees: 30))))
        XCTAssertEqual(shaped.steer(continuousDegrees: -180), 32767,
                       "shaping must not cost full lock")
    }
}

final class AngleUnwrapperTests: XCTestCase {
    private let golden = GoldenVectors.shared

    /// TV4: eighty 5-degree steps of real rotation, up to 400 degrees.
    ///
    /// The fixture lists the nominal angles, but its expected total comes from
    /// running actual quaternions through the twist extractor, so the test does
    /// the same. Feeding the listed degrees straight in would never exercise a
    /// wrap, which is what the vector exists to test.
    func testUnwrapVector() {
        let vector = golden.unwrap
        var extractor = TwistExtractor()
        var unwrapper = AngleUnwrapper()
        var total = 0.0
        var sawWrap = false
        var previousWrapped = 0.0

        for (index, nominal) in vector.sequenceDeg.enumerated() {
            let wrapped = extractor.step(reference: .identity,
                                         current: Quat.rz(nominal))
            if index > 0, abs(wrapped - previousWrapped) > 180 { sawWrap = true }
            previousWrapped = wrapped
            total = unwrapper.step(wrapped)
        }

        XCTAssertTrue(sawWrap, "the sequence never crossed ±180, so nothing was tested")
        XCTAssertEqual(total, vector.continuousDeg, accuracy: 1e-9, vector.name)
        XCTAssertGreaterThan(total, 360,
                             "a 900 degree wheel must travel past one full turn")

        let mapper = SteerMapper(degreesOfRotation: vector.dorDeg,
                                 deadband: 0, gamma: 1)
        XCTAssertEqual(mapper.normalized(continuousDegrees: total),
                       vector.steerNorm, accuracy: 1e-12)
        XCTAssertEqual(Int(mapper.steer(continuousDegrees: total)), vector.steerI16)
    }

    func testWrapsBothWays() {
        var unwrapper = AngleUnwrapper()
        unwrapper.step(179)
        XCTAssertEqual(unwrapper.step(-179), 181, accuracy: 1e-9)
        XCTAssertEqual(unwrapper.step(179), 179, accuracy: 1e-9)
    }

    func testFirstSampleIsTakenAsIs() {
        var unwrapper = AngleUnwrapper()
        XCTAssertEqual(unwrapper.step(-137.5), -137.5, accuracy: 1e-12)
    }

    /// Recalibration has to clear the history, or the first sample afterwards is
    /// read as a real jump of whatever the old angle was.
    func testResetClearsHistory() {
        var unwrapper = AngleUnwrapper()
        for k in 0...72 { unwrapper.step(Double(k) * 5) }
        XCTAssertGreaterThan(unwrapper.total, 300)

        unwrapper.reset()
        XCTAssertEqual(unwrapper.total, 0)
        XCTAssertEqual(unwrapper.step(12), 12, accuracy: 1e-12)
    }

    /// A full turn each way returns to where it started, and passes ±180 on the
    /// way without a discontinuity.
    func testFullTurnAndBack() {
        var unwrapper = AngleUnwrapper()
        for k in stride(from: 0.0, through: 360.0, by: 5.0) {
            unwrapper.step(((k + 180).truncatingRemainder(dividingBy: 360)) - 180)
        }
        XCTAssertEqual(unwrapper.total, 360, accuracy: 1e-9)

        for k in stride(from: 355.0, through: 0.0, by: -5.0) {
            unwrapper.step(((k + 180).truncatingRemainder(dividingBy: 360)) - 180)
        }
        XCTAssertEqual(unwrapper.total, 0, accuracy: 1e-9)
    }
}
