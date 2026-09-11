import Foundation
import os
import OpenSteerCore

/// The only place three queues meet.
///
/// The motion loop runs at 120 Hz on `ioQueue`, SwiftUI runs on the main actor,
/// and haptics run on a third queue. Each slot holds a whole value type behind an
/// unfair lock, and every reader copies the struct out in one acquisition rather
/// than reading fields one at a time. Reading field by field is how you end up
/// drawing a wheel angle from one sample next to a sequence number from the next.
///
/// `OSAllocatedUnfairLock` rather than a `DispatchQueue`: these critical sections
/// are a handful of machine words long, so a queue hop would cost far more than
/// the work it protects.
final class SnapshotStore: Sendable {
    private let motion = OSAllocatedUnfairLock(initialState: MotionSnapshot())
    private let telemetry = OSAllocatedUnfairLock(initialState: TelemetrySnapshot())
    private let controls = OSAllocatedUnfairLock(initialState: ControlInputs())
    private let display = OSAllocatedUnfairLock(initialState: DisplaySnapshot())

    // MARK: motion, written by ioQueue

    func publishMotion(_ snapshot: MotionSnapshot) {
        motion.withLock { $0 = snapshot }
    }

    func readMotion() -> MotionSnapshot {
        motion.withLock { $0 }
    }

    // MARK: telemetry, written by ioQueue on every downlink frame

    func publishTelemetry(_ frame: TelemetryFrame, at uptimeNs: UInt64) {
        telemetry.withLock {
            $0.frame = frame
            $0.receivedAtNs = uptimeNs
            $0.framesReceived &+= 1
        }
    }

    func readTelemetry() -> TelemetrySnapshot {
        telemetry.withLock { $0 }
    }

    func clearTelemetry() {
        telemetry.withLock { $0 = TelemetrySnapshot() }
    }

    // MARK: display, written by the wheel view's display link on the main actor

    func publishDisplayInterval(_ milliseconds: Double) {
        display.withLock {
            $0.frameIntervalMs = milliseconds
            $0.frames &+= 1
        }
    }

    func readDisplay() -> DisplaySnapshot {
        display.withLock { $0 }
    }

    // MARK: controls, written by the main actor, drained by ioQueue

    /// `@Sendable` because `OSAllocatedUnfairLock.withLock` demands it. The lock
    /// has no idea which thread will be holding it, so anything the closure
    /// captures has to be safe to touch from any of them.
    func updateControls(_ mutate: @Sendable (inout ControlInputs) -> Void) {
        controls.withLock(mutate)
    }

    /// Reads the pedals and takes the one-shot flags in the same acquisition.
    ///
    /// Splitting this into a read and a separate clear is how a paddle tap gets
    /// counted twice, or lost between the two calls.
    func takeControls() -> ControlInputs {
        controls.withLock { current in
            let taken = current
            current.upshiftPending = false
            current.downshiftPending = false
            current.calibrateRequested = false
            return taken
        }
    }

    func peekControls() -> ControlInputs {
        controls.withLock { $0 }
    }

    func resetControls() {
        controls.withLock { $0 = ControlInputs() }
    }
}
