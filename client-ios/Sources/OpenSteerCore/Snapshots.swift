import Foundation

/// Everything that crosses a queue boundary is a value type in this file.
///
/// The motion loop runs on a background queue at 120 Hz, the UI runs on the main
/// actor, and haptics run on a third queue. Passing a reference between them
/// would mean either a lock on every field access or a data race. Instead each
/// side copies a whole struct under one lock acquisition and then works on its
/// own copy.

/// What the steering loop produced, for the UI to draw.
public struct MotionSnapshot: Sendable, Equatable {
    /// Continuous twist, unbounded, after unwrapping. This is what the wheel
    /// graphic rotates by.
    public var thetaDegrees: Double = 0
    public var steerNormalized: Double = 0
    public var steerI16: Int16 = 0
    public var sequence: UInt16 = 0
    /// Measured sensor rate, for the HUD. A phone that quietly caps at 100 Hz is
    /// acceptable but the driver should be able to see it.
    public var motionHz: Double = 0
    public var isCalibrated: Bool = false

    public init() {}
}

/// What the last downlink frame said, for the UI and the haptics engine.
public struct TelemetrySnapshot: Sendable, Equatable {
    public var frame: TelemetryFrame = .zero
    /// `DispatchTime.now().uptimeNanoseconds` when it landed. Zero means none yet.
    public var receivedAtNs: UInt64 = 0
    public var framesReceived: UInt64 = 0

    public init() {}

    public var hasEverReceived: Bool { framesReceived > 0 }
}

/// What the screen is actually managing, as opposed to what it was asked for.
///
/// The HUD shows `frameIntervalMs`: about 8.3 ms on a ProMotion panel, about
/// 16.7 ms on a 60 Hz one. A phone showing 16.7 has silently ignored the frame
/// rate range, which almost always means the Info.plist key is missing.
public struct DisplaySnapshot: Sendable, Equatable {
    public var frameIntervalMs: Double = 0
    public var frames: UInt64 = 0

    public init() {}
}

/// What the driver's thumbs are doing. Written by the main actor, read and
/// cleared by the I/O queue.
public struct ControlInputs: Sendable, Equatable {
    public var throttle: UInt16 = 0
    public var brake: UInt16 = 0
    public var clutch: UInt16 = 0

    /// Normalised copies, kept so the haptics policy can find the brake lockup
    /// edge without dividing by 65535 on every tick.
    public var throttleNormalized: Double = 0
    public var brakeNormalized: Double = 0

    public var handbrake: Bool = false

    /// One-shot flags. The I/O queue reads and clears these in the same lock
    /// acquisition it reads the pedals in, so a tap can never be seen twice or
    /// dropped between two acquisitions.
    public var upshiftPending: Bool = false
    public var downshiftPending: Bool = false
    public var calibrateRequested: Bool = false

    public init() {}
}
