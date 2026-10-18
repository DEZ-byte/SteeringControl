import Foundation

/// The connection lifecycle, as a pure function.
///
/// Nothing here touches a socket, a timer or the UI. `transition` takes a state
/// and an event and returns the next state plus a list of things for the caller
/// to do. That makes the link state table (iOS client in docs/ARCHITECTURE.md)
/// testable line by line rather than by hand on a phone.
public enum LinkState: Sendable, Equatable {
    case idle
    case connecting
    case streaming
    /// Still sending, but telemetry has stopped. The driver keeps control of the
    /// car and only loses haptics.
    case degraded
    case disconnected
}

public enum LinkEvent: Sendable, Equatable {
    case start
    case ready
    /// The connection has been stuck in `.waiting` or `.failed` for longer than
    /// `connectTimeout`.
    case connectTimedOut
    case failed
    case downlinkReceived
    /// No downlink for longer than `degradeAfter`.
    case downlinkSilent
    case viabilityLostTooLong
    case sendErrorLimitReached
    case backoffElapsed
    case stop
    case enteredBackground
}

public enum LinkEffect: Sendable, Equatable {
    case createConnection
    case cancelConnection
    case startMotion
    case stopMotion
    case armReceiveLoop
    case startHaptics
    case stopHaptics
    case muteHaptics
    case unmuteHaptics
    case scheduleBackoff
    case setIdleTimerDisabled(Bool)
    case showDisconnectedReason
}

public struct LinkStateMachine: Sendable {
    /// A downlink can go missing for a few frames on a busy network without
    /// anything being wrong. Half a second is about thirty missed frames, which is
    /// past coincidence.
    public static let degradeAfterMs: Double = 500

    /// Long enough to cover a Local Network permission prompt the driver has not
    /// answered yet.
    public static let connectTimeoutMs: Double = 3000

    public static let viabilityGraceMs: Double = 2000
    public static let sendErrorLimit = 24

    public static let backoffStartMs: Double = 250
    public static let backoffCapMs: Double = 2000

    public private(set) var state: LinkState = .idle

    /// Whether any telemetry has arrived since the session started.
    ///
    /// The ESP32 bridge never sends any. Without this gate every bridge session
    /// would drop to Degraded half a second in and stay there, reporting a fault
    /// for a device that has no telemetry to send.
    public private(set) var hasSeenDownlink = false

    public init(state: LinkState = .idle, hasSeenDownlink: Bool = false) {
        self.state = state
        self.hasSeenDownlink = hasSeenDownlink
    }

    @discardableResult
    public mutating func handle(_ event: LinkEvent) -> [LinkEffect] {
        switch event {
        case .start:
            hasSeenDownlink = false
        case .downlinkReceived:
            hasSeenDownlink = true
        default:
            break
        }

        let (next, effects) = Self.transition(state, event,
                                              hasSeenDownlink: hasSeenDownlink)
        state = next
        return effects
    }

    public static func transition(_ state: LinkState,
                                  _ event: LinkEvent,
                                  hasSeenDownlink: Bool = true) -> (LinkState, [LinkEffect]) {
        // Stopping and backgrounding win from any state, so they are matched
        // first. Otherwise a stop arriving during `.connecting` would fall through
        // to the default and leave a live connection behind.
        switch event {
        case .stop, .enteredBackground:
            return (.idle, [.cancelConnection, .stopMotion, .stopHaptics,
                            .setIdleTimerDisabled(false)])
        default:
            break
        }

        switch (state, event) {
        case (.idle, .start):
            return (.connecting, [.createConnection, .startMotion,
                                  .setIdleTimerDisabled(true)])

        case (.connecting, .ready):
            return (.streaming, [.armReceiveLoop, .startHaptics])

        case (.connecting, .connectTimedOut), (.connecting, .failed):
            return (.disconnected, [.showDisconnectedReason, .scheduleBackoff])

        case (.streaming, .downlinkSilent) where hasSeenDownlink:
            return (.degraded, [.muteHaptics])

        case (.degraded, .downlinkReceived):
            return (.streaming, [.unmuteHaptics])

        case (.streaming, .viabilityLostTooLong),
             (.streaming, .sendErrorLimitReached),
             (.streaming, .failed),
             (.degraded, .viabilityLostTooLong),
             (.degraded, .sendErrorLimitReached),
             (.degraded, .failed):
            // Motion keeps running. Restarting CoreMotion would drop the
            // calibration reference and recenter the wheel under the driver.
            return (.disconnected, [.cancelConnection, .muteHaptics, .scheduleBackoff])

        case (.disconnected, .backoffElapsed):
            return (.connecting, [.createConnection])

        default:
            return (state, [])
        }
    }
}
