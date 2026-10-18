import XCTest
@testable import OpenSteerCore

/// The haptics policy: pulse cadences, hysteresis, priority, the rate cap and
/// muting.
final class HapticPolicyTests: XCTestCase {
    private func ms(_ value: Double) -> UInt64 { UInt64(value * 1_000_000) }

    private func telemetry(rpm: UInt16 = 0, abs: Bool = false,
                           tc: Bool = false, slip: Float = 0) -> TelemetryFrame {
        TelemetryFrame(rpm: rpm, absActive: abs, tcActive: tc, slip: slip)
    }

    /// ABS held for one second: a tick on the rising edge, then one every 70 ms.
    func testAbsPulseTrain() {
        var policy = HapticPolicy()
        var fired: [Double] = []
        let frame = telemetry(abs: true)

        // 60 Hz, which is the real downlink rate.
        for step in 0...60 {
            let t = Double(step) * (1000.0 / 60.0)
            let output = policy.step(now: ms(t) + 1, telemetry: frame,
                                     inputs: HapticInputs())
            if output.transients.contains(.abs) { fired.append(t) }
        }

        XCTAssertEqual(fired.first, 0, "the rising edge must tick immediately")
        XCTAssertGreaterThanOrEqual(fired.count, 12, "expected roughly 1000/70 ticks")
        XCTAssertLessThanOrEqual(fired.count, 15)

        for (a, b) in zip(fired, fired.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, HapticPolicy.absIntervalMs - 0.001,
                                        "ticks came closer than 70 ms apart")
        }
    }

    func testTcIsSlowerThanAbs() {
        var policy = HapticPolicy()
        var absCount = 0
        var tcCount = 0
        let frame = telemetry(abs: true, tc: true)

        for step in 0...60 {
            let t = Double(step) * (1000.0 / 60.0)
            let output = policy.step(now: ms(t) + 1, telemetry: frame,
                                     inputs: HapticInputs())
            absCount += output.transients.filter { $0 == .abs }.count
            tcCount += output.transients.filter { $0 == .tc }.count
        }

        XCTAssertGreaterThan(absCount, tcCount)
        XCTAssertGreaterThanOrEqual(tcCount, 9)
        XCTAssertLessThanOrEqual(tcCount, 12)
    }

    /// A flag going low and high again is a new event and must tick again.
    func testFallingAndRisingAgainRetriggers() {
        var policy = HapticPolicy()
        var t = 1.0

        var output = policy.step(now: ms(t), telemetry: telemetry(abs: true),
                                 inputs: HapticInputs())
        XCTAssertTrue(output.transients.contains(.abs))

        t += 10
        output = policy.step(now: ms(t), telemetry: telemetry(abs: false),
                             inputs: HapticInputs())
        XCTAssertFalse(output.transients.contains(.abs))

        // 50 ms later, past the 40 ms per-player floor but well inside the 70 ms
        // cadence. A real new edge still has to be felt.
        t += 50
        output = policy.step(now: ms(t), telemetry: telemetry(abs: true),
                             inputs: HapticInputs())
        XCTAssertTrue(output.transients.contains(.abs))
    }

    /// Brake lockup has hysteresis. Without the lower rearm point a brake hovering
    /// at the threshold would fire the thud over and over.
    func testLockupHysteresis() {
        var policy = HapticPolicy()
        var inputs = HapticInputs()
        var t = 1.0

        func brake(_ value: Double) -> [HapticTransient] {
            inputs.brakeNormalized = value
            t += 50
            return policy.step(now: ms(t), telemetry: telemetry(), inputs: inputs).transients
        }

        XCTAssertFalse(brake(0.79).contains(.lockup))
        XCTAssertTrue(brake(0.80).contains(.lockup))
        XCTAssertFalse(brake(0.95).contains(.lockup), "still the same press")
        XCTAssertFalse(brake(0.75).contains(.lockup), "not rearmed yet")
        XCTAssertFalse(brake(0.85).contains(.lockup), "still not rearmed")
        XCTAssertFalse(brake(0.69).contains(.lockup))
        XCTAssertTrue(brake(0.81).contains(.lockup), "rearmed below 0.70")
    }

    /// The cap protects the Taptic Engine. Past about 25 a second the pulses blur
    /// into one buzz and the driver loses the information they were carrying.
    func testGlobalRateCap() {
        var policy = HapticPolicy(absTicksEnabled: true, tcTicksEnabled: true)
        var fired = 0
        let frame = telemetry(rpm: 6000, abs: true, tc: true, slip: 0.4)

        // 1 kHz for a full second, which is far faster than anything real.
        for step in 1...1000 {
            var inputs = HapticInputs()
            inputs.shiftPressed = step % 3 == 0
            fired += policy.step(now: ms(Double(step)), telemetry: frame,
                                 inputs: inputs).transients.count
        }

        XCTAssertLessThanOrEqual(fired, HapticPolicy.globalTransientsPerSecond,
                                 "fired \(fired) transients in one second")
        XCTAssertGreaterThan(fired, 0)
    }

    /// When the cap bites, tire-chatter noise is dropped before the lockup event
    /// that says the front wheels have stopped turning. Firing order inside a
    /// single pass decides which events are kept.
    func testPriorityOrderPutsLockupFirstAndChatterLast() {
        var policy = HapticPolicy()
        var inputs = HapticInputs()
        inputs.brakeNormalized = 0.9
        inputs.shiftPressed = true

        let output = policy.step(now: ms(1),
                                 telemetry: telemetry(rpm: 6000, abs: true, tc: true),
                                 inputs: inputs)

        XCTAssertEqual(output.transients, [.lockup, .shift, .abs, .tc])
    }

    /// A recenter is a direct answer to a button the driver just pressed, so it is
    /// confirmed even when everything else is silenced.
    func testRecentreIsConfirmedEvenWhenMuted() {
        var policy = HapticPolicy()
        var inputs = HapticInputs()
        inputs.muted = true
        inputs.recenterRequested = true

        let output = policy.step(now: ms(1), telemetry: telemetry(rpm: 6000),
                                 inputs: inputs)
        XCTAssertEqual(output.transients, [.recenter])
        XCTAssertEqual(output.rumble, .silent, "a muted link must not keep buzzing")
    }

    func testMutingSilencesEverythingElse() {
        var policy = HapticPolicy()
        var inputs = HapticInputs()
        inputs.muted = true
        inputs.brakeNormalized = 1.0

        let output = policy.step(now: ms(1), telemetry: telemetry(rpm: 7000, abs: true),
                                 inputs: inputs)
        XCTAssertTrue(output.transients.isEmpty)
        XCTAssertEqual(output.rumble?.intensity, 0)
    }

    func testRumbleCurve() {
        // Below 300 rpm the engine is barely turning and the motor stays still.
        XCTAssertEqual(HapticPolicy.rumble(rpm: 299, slip: 0, redlineRpm: 8000).intensity, 0)
        XCTAssertGreaterThan(HapticPolicy.rumble(rpm: 300, slip: 0, redlineRpm: 8000).intensity, 0)

        // Squared, so idle does not feel like redline.
        let quarter = HapticPolicy.rumble(rpm: 2000, slip: 0, redlineRpm: 8000)
        let redline = HapticPolicy.rumble(rpm: 8000, slip: 0, redlineRpm: 8000)
        XCTAssertEqual(quarter.intensity, 0.10 + 0.55 * 0.0625, accuracy: 1e-12)
        XCTAssertEqual(redline.intensity, 0.65, accuracy: 1e-12)
        XCTAssertGreaterThan(redline.intensity, quarter.intensity * 3)

        // Slip rides on sharpness, which is what makes a slide feel gritty rather
        // than merely louder.
        let gripping = HapticPolicy.rumble(rpm: 4000, slip: 0, redlineRpm: 8000)
        let sliding = HapticPolicy.rumble(rpm: 4000, slip: 0.3, redlineRpm: 8000)
        XCTAssertEqual(gripping.intensity, sliding.intensity)
        XCTAssertEqual(sliding.sharpness - gripping.sharpness, 0.2, accuracy: 1e-12)

        for rpm in stride(from: 0, through: 65535, by: 137) {
            let r = HapticPolicy.rumble(rpm: UInt16(rpm), slip: 2, redlineRpm: 8000)
            XCTAssertTrue(r.intensity >= 0 && r.intensity <= 1)
            XCTAssertTrue(r.sharpness >= 0 && r.sharpness <= 1)
        }
    }

    /// A modded car can rev past the assumed redline. Pinning the rumble flat at
    /// the top of every gear would throw away the most useful part of the signal.
    func testRedlineAutoRaises() {
        var policy = HapticPolicy(redlineRpm: 8000)
        _ = policy.step(now: ms(1), telemetry: telemetry(rpm: 11000), inputs: HapticInputs())
        XCTAssertEqual(policy.redlineRpm, 11000)
    }

    /// Rumble updates are capped at 30 Hz and only sent when something moved.
    /// Pushing parameter changes at the full frame rate makes a haptics engine
    /// stutter.
    func testRumbleUpdatesAreRateLimitedAndDeadbanded() {
        var policy = HapticPolicy()
        var t = 1.0

        let first = policy.step(now: ms(t), telemetry: telemetry(rpm: 4000),
                                inputs: HapticInputs())
        XCTAssertNotNil(first.rumble, "the first frame always publishes")

        t += 5
        let tooSoon = policy.step(now: ms(t), telemetry: telemetry(rpm: 7000),
                                  inputs: HapticInputs())
        XCTAssertNil(tooSoon.rumble, "5 ms later is past the 30 Hz ceiling")

        t += 100
        let unchanged = policy.step(now: ms(t), telemetry: telemetry(rpm: 4000),
                                    inputs: HapticInputs())
        XCTAssertNil(unchanged.rumble, "nothing moved, so nothing to send")

        t += 100
        let moved = policy.step(now: ms(t), telemetry: telemetry(rpm: 7500),
                                inputs: HapticInputs())
        XCTAssertNotNil(moved.rumble)
    }

    func testConstantsMatchTheDocumentedValues() {
        XCTAssertEqual(HapticPolicy.absIntervalMs, 70)
        XCTAssertEqual(HapticPolicy.tcIntervalMs, 90)
        XCTAssertEqual(HapticPolicy.perPlayerMinimumGapMs, 40)
        XCTAssertEqual(HapticPolicy.globalTransientsPerSecond, 25)
        XCTAssertEqual(HapticPolicy.lockupThreshold, 0.80)
        XCTAssertEqual(HapticPolicy.lockupRearm, 0.70)
        XCTAssertEqual(HapticPolicy.rumbleMinimumRpm, 300)
        XCTAssertEqual(HapticPolicy.defaultRedlineRpm, 8000)
    }
}
