import XCTest
@testable import OpenSteerCore

final class PedalMapperTests: XCTestCase {
    /// Screen y grows downward, so pulling the thumb down the screen means a
    /// smaller y and a larger pedal value.
    func testTouchDownStartsAtZeroWhereverItLands() {
        var pedal = PedalMapper(travel: 140)
        for start in [0.0, 137.5, 400.0, 812.0] {
            pedal.began(at: start)
            XCTAssertEqual(pedal.value, 0, "anchor at \(start)")
            XCTAssertEqual(pedal.raw, 0)
            XCTAssertTrue(pedal.isPressed)
        }
    }

    func testLinearBetweenAnchorAndFullTravel() {
        var pedal = PedalMapper(travel: 140)
        pedal.began(at: 500)

        pedal.moved(to: 500 - 35)
        XCTAssertEqual(pedal.value, 0.25, accuracy: 1e-12)

        pedal.moved(to: 500 - 70)
        XCTAssertEqual(pedal.value, 0.5, accuracy: 1e-12)

        pedal.moved(to: 500 - 140)
        XCTAssertEqual(pedal.value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(pedal.raw, 65535)
    }

    /// The ratchet down. A thumb that runs past full travel drags the anchor with
    /// it, so the pedal stays pinned at 100 per cent instead of being stuck at an
    /// anchor the thumb can no longer reach.
    func testRatchetFollowsTheThumbPastFullTravel() {
        var pedal = PedalMapper(travel: 140)
        pedal.began(at: 500)
        pedal.moved(to: 100)
        XCTAssertEqual(pedal.value, 1.0, accuracy: 1e-12)

        // Coming back up by a quarter of the travel must give exactly 0.75, which
        // it only can if the anchor moved down to 240.
        pedal.moved(to: 100 + 35)
        XCTAssertEqual(pedal.value, 0.75, accuracy: 1e-12)
    }

    /// The ratchet up. Sliding above the anchor re-anchors, so releasing is
    /// immediate no matter how far the thumb wandered.
    func testRatchetFollowsTheThumbAboveTheAnchor() {
        var pedal = PedalMapper(travel: 140)
        pedal.began(at: 500)
        pedal.moved(to: 430)
        XCTAssertEqual(pedal.value, 0.5, accuracy: 1e-12)

        pedal.moved(to: 700)
        XCTAssertEqual(pedal.value, 0, accuracy: 1e-12)

        pedal.moved(to: 700 - 70)
        XCTAssertEqual(pedal.value, 0.5, accuracy: 1e-12)
    }

    /// No easing on release. A throttle that coasts down after the thumb leaves
    /// it is how you spin the car on corner exit.
    func testLiftingTheThumbReleasesAtOnce() {
        var pedal = PedalMapper(travel: 140)
        pedal.began(at: 500)
        pedal.moved(to: 400)
        XCTAssertGreaterThan(pedal.value, 0)

        pedal.ended()
        XCTAssertEqual(pedal.value, 0)
        XCTAssertEqual(pedal.raw, 0)
        XCTAssertFalse(pedal.isPressed)
    }

    /// A move with no touch down must do nothing. Otherwise a stray event during
    /// a gesture cancellation applies a pedal nobody is touching.
    func testMoveWithoutTouchIsIgnored() {
        var pedal = PedalMapper(travel: 140)
        pedal.moved(to: 0)
        XCTAssertEqual(pedal.value, 0)
        XCTAssertFalse(pedal.isPressed)
    }

    func testRawEndpoints() {
        var pedal = PedalMapper(travel: 100)
        pedal.began(at: 300)
        XCTAssertEqual(pedal.raw, 0)
        pedal.moved(to: 250)
        XCTAssertEqual(pedal.raw, 32768, "half travel rounds half away from zero")
        pedal.moved(to: 200)
        XCTAssertEqual(pedal.raw, 65535)
    }

    func testTravelIsClampedToUsableRange() {
        XCTAssertEqual(PedalMapper(travel: 1).travel, PedalMapper.minimumTravel)
        XCTAssertEqual(PedalMapper(travel: 9999).travel, PedalMapper.maximumTravel)
        XCTAssertEqual(PedalMapper(travel: 140).travel, 140)
    }

    /// The value must never leave 0...1, whatever the touch does.
    func testValueStaysInRangeUnderRandomInput() {
        var pedal = PedalMapper(travel: 140)
        pedal.began(at: 400)
        for _ in 0..<5000 {
            pedal.moved(to: Double.random(in: -2000...2000))
            XCTAssertTrue(pedal.value >= 0 && pedal.value <= 1,
                          "value escaped: \(pedal.value)")
        }
    }
}

final class ButtonMaskTests: XCTestCase {
    func testBitPositionsMatchTheWireContract() {
        XCTAssertEqual(ButtonMask.upshift.rawValue, 1)
        XCTAssertEqual(ButtonMask.downshift.rawValue, 2)
        XCTAssertEqual(ButtonMask.handbrake.rawValue, 4)
    }

    /// A paddle tap can be shorter than one 8.3 ms uplink tick. Without the latch
    /// the bit would appear in zero packets and the shift would never happen.
    func testShortTapSurvivesThreeTicks() {
        var latch = PulseLatch()
        latch.press()
        latch.release()

        XCTAssertTrue(latch.tick())
        XCTAssertTrue(latch.tick())
        XCTAssertTrue(latch.tick())
        XCTAssertFalse(latch.tick())
    }

    /// Holding the paddle keeps the bit set for as long as it is held, so a
    /// clutch-style hold works too.
    func testHeldButtonStaysSet() {
        var latch = PulseLatch()
        latch.press()
        for _ in 0..<50 { XCTAssertTrue(latch.tick()) }
        latch.release()
        XCTAssertFalse(latch.tick())
    }

    func testUntouchedLatchIsQuiet() {
        var latch = PulseLatch()
        XCTAssertFalse(latch.tick())
        XCTAssertFalse(latch.isActive)
    }
}
