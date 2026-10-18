import XCTest
@testable import OpenSteerCore

/// The link state table, transition by transition.
final class LinkStateMachineTests: XCTestCase {
    func testHappyPath() {
        var machine = LinkStateMachine()
        XCTAssertEqual(machine.state, .idle)

        var effects = machine.handle(.start)
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertTrue(effects.contains(.createConnection))
        XCTAssertTrue(effects.contains(.startMotion))
        XCTAssertTrue(effects.contains(.setIdleTimerDisabled(true)))

        effects = machine.handle(.ready)
        XCTAssertEqual(machine.state, .streaming)
        XCTAssertTrue(effects.contains(.armReceiveLoop))
        XCTAssertTrue(effects.contains(.startHaptics))
    }

    func testConnectTimeoutGoesToDisconnectedWithBackoff() {
        var machine = LinkStateMachine(state: .connecting)
        let effects = machine.handle(.connectTimedOut)
        XCTAssertEqual(machine.state, .disconnected)
        XCTAssertTrue(effects.contains(.showDisconnectedReason))
        XCTAssertTrue(effects.contains(.scheduleBackoff))
    }

    /// Telemetry stopping costs haptics and nothing else. The driver keeps
    /// control of the car.
    func testDownlinkSilenceDegradesButKeepsStreaming() {
        var machine = LinkStateMachine(state: .streaming, hasSeenDownlink: true)
        var effects = machine.handle(.downlinkSilent)
        XCTAssertEqual(machine.state, .degraded)
        XCTAssertEqual(effects, [.muteHaptics])
        XCTAssertFalse(effects.contains(.cancelConnection))
        XCTAssertFalse(effects.contains(.stopMotion))

        effects = machine.handle(.downlinkReceived)
        XCTAssertEqual(machine.state, .streaming)
        XCTAssertEqual(effects, [.unmuteHaptics])
    }

    /// Dropping the link must not restart CoreMotion. That would throw away the
    /// calibration reference and recenter the wheel under the driver's hands.
    func testDisconnectKeepsTheMotionLoopAlive() {
        for start in [LinkState.streaming, .degraded] {
            for event in [LinkEvent.viabilityLostTooLong, .sendErrorLimitReached, .failed] {
                var machine = LinkStateMachine(state: start)
                let effects = machine.handle(event)
                XCTAssertEqual(machine.state, .disconnected, "\(start) + \(event)")
                XCTAssertTrue(effects.contains(.cancelConnection))
                XCTAssertTrue(effects.contains(.scheduleBackoff))
                XCTAssertFalse(effects.contains(.stopMotion), "\(start) + \(event)")
            }
        }
    }

    /// Degraded at 500 ms only if a downlink was seen.
    ///
    /// The ESP32 bridge never sends telemetry. Without this gate every bridge
    /// session would drop to Degraded half a second in and stay there, reporting
    /// a fault for a device that has no telemetry to send.
    func testSilenceIsNotAFaultUntilTelemetryHasBeenSeenOnce() {
        var machine = LinkStateMachine()
        machine.handle(.start)
        machine.handle(.ready)
        XCTAssertEqual(machine.state, .streaming)
        XCTAssertFalse(machine.hasSeenDownlink)

        XCTAssertEqual(machine.handle(.downlinkSilent), [],
                       "a link that never had telemetry cannot have lost it")
        XCTAssertEqual(machine.state, .streaming)

        machine.handle(.downlinkReceived)
        XCTAssertTrue(machine.hasSeenDownlink)

        XCTAssertEqual(machine.handle(.downlinkSilent), [.muteHaptics])
        XCTAssertEqual(machine.state, .degraded)
    }

    /// A new session starts from scratch. Carrying the flag over would make the
    /// first half second after reconnecting to a bridge report a fault.
    func testStartForgetsThatTelemetryWasEverSeen() {
        var machine = LinkStateMachine()
        machine.handle(.start)
        machine.handle(.ready)
        machine.handle(.downlinkReceived)
        XCTAssertTrue(machine.hasSeenDownlink)

        machine.handle(.stop)
        machine.handle(.start)
        XCTAssertFalse(machine.hasSeenDownlink)
    }

    func testBackoffReconnects() {
        var machine = LinkStateMachine(state: .disconnected)
        let effects = machine.handle(.backoffElapsed)
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertEqual(effects, [.createConnection])
    }

    /// Stop and background win from every state. If they only matched in a few,
    /// a stop arriving mid-connect would leave a live socket behind.
    func testStopAndBackgroundAlwaysReturnToIdle() {
        let states: [LinkState] = [.idle, .connecting, .streaming, .degraded, .disconnected]
        for state in states {
            for event in [LinkEvent.stop, .enteredBackground] {
                var machine = LinkStateMachine(state: state)
                let effects = machine.handle(event)
                XCTAssertEqual(machine.state, .idle, "\(state) + \(event)")
                XCTAssertTrue(effects.contains(.cancelConnection))
                XCTAssertTrue(effects.contains(.stopMotion))
                XCTAssertTrue(effects.contains(.stopHaptics))
                XCTAssertTrue(effects.contains(.setIdleTimerDisabled(false)))
            }
        }
    }

    /// Anything not in the table leaves the state alone and does nothing.
    func testUnlistedTransitionsAreInert() {
        var machine = LinkStateMachine(state: .idle)
        XCTAssertEqual(machine.handle(.ready), [])
        XCTAssertEqual(machine.state, .idle)

        machine = LinkStateMachine(state: .streaming)
        XCTAssertEqual(machine.handle(.ready), [])
        XCTAssertEqual(machine.state, .streaming)

        machine = LinkStateMachine(state: .degraded, hasSeenDownlink: true)
        XCTAssertEqual(machine.handle(.downlinkSilent), [])
        XCTAssertEqual(machine.state, .degraded)
    }

    func testTimingConstantsMatchTheDocumentedValues() {
        XCTAssertEqual(LinkStateMachine.degradeAfterMs, 500)
        XCTAssertEqual(LinkStateMachine.connectTimeoutMs, 3000)
        XCTAssertEqual(LinkStateMachine.viabilityGraceMs, 2000)
        XCTAssertEqual(LinkStateMachine.sendErrorLimit, 24)
        XCTAssertEqual(LinkStateMachine.backoffStartMs, 250)
        XCTAssertEqual(LinkStateMachine.backoffCapMs, 2000)
    }
}
