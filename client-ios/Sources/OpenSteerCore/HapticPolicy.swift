import Foundation

/// Which motor pattern to fire. The engine owns the players; this type only
/// decides what should happen and when.
public enum HapticTransient: String, Sendable, Equatable, CaseIterable {
    case lockup
    case shift
    case abs
    case tc
    case recenter

    /// A dense index, so the per-player gap table can be a fixed array instead of
    /// a dictionary that hashes a string on every 60 Hz tick.
    public var slot: Int {
        switch self {
        case .lockup: return 0
        case .shift: return 1
        case .abs: return 2
        case .tc: return 3
        case .recenter: return 4
        }
    }
}

/// Continuous rumble settings, 0...1 each.
public struct RumbleParameters: Sendable, Equatable {
    public var intensity: Double
    public var sharpness: Double

    public init(intensity: Double, sharpness: Double) {
        self.intensity = intensity
        self.sharpness = sharpness
    }

    public static let silent = RumbleParameters(intensity: 0, sharpness: 0)
}

/// What the driver's hands are doing, as far as haptics cares.
public struct HapticInputs: Sendable, Equatable {
    public var brakeNormalized: Double = 0
    public var shiftPressed: Bool = false
    public var recenterRequested: Bool = false
    /// Set while the link is Degraded or Disconnected. Rumble goes to zero and
    /// transients stop, because a buzz that no longer tracks the car is worse than
    /// no buzz at all.
    public var muted: Bool = false

    public init() {}
}

public struct HapticOutput: Sendable, Equatable {
    /// In fire order, already filtered by priority and the global rate cap.
    public var transients: [HapticTransient] = []
    /// Non-nil only when the parameters moved enough to be worth an update.
    public var rumble: RumbleParameters?

    public init() {}
}

/// All the edge detection, hysteresis and rate limiting, with no frameworks
/// attached so it can be tested against a synthetic clock.
public struct HapticPolicy: Sendable {
    // Cadences while a flag stays high. ABS chatters faster than TC because that
    // is what the real thing feels like through a pedal.
    public static let absIntervalMs: Double = 70
    public static let tcIntervalMs: Double = 90

    /// No single player may fire faster than this. Two pulses closer together
    /// than about 40 ms blur into one anyway, so the extra ones are wasted power.
    public static let perPlayerMinimumGapMs: Double = 40

    /// The Taptic Engine physically cannot keep up past roughly this rate, and
    /// pushing it turns distinct events into mush.
    public static let globalTransientsPerSecond = 25

    public static let lockupThreshold = 0.80
    /// Hysteresis. Without the lower rearm point a brake hovering at the
    /// threshold would machine-gun the lockup thud.
    public static let lockupRearm = 0.70

    public static let rumbleMinimumRpm: UInt16 = 300
    public static let defaultRedlineRpm: Double = 8000
    public static let rumbleMaxUpdateHz: Double = 30
    public static let rumbleIntensityEpsilon = 0.02
    public static let rumbleSharpnessEpsilon = 0.03

    public var redlineRpm: Double
    public var absTicksEnabled: Bool
    public var tcTicksEnabled: Bool
    /// Off means the continuous motor stays still. Some drivers find a constant
    /// buzz masks the transients they actually need to feel.
    public var rumbleEnabled: Bool

    private var previousAbs = false
    private var previousTc = false
    private var brakeArmed = true

    private var lastAbsNs: UInt64 = 0
    private var lastTcNs: UInt64 = 0
    private var lastPerPlayerNs = [UInt64](repeating: 0,
                                        count: HapticTransient.allCases.count)

    private var recentTransientNs: [UInt64]
    private var recentWriteIndex = 0
    private var recentCount = 0

    private var lastRumble: RumbleParameters?
    private var lastRumbleNs: UInt64 = 0

    public init(redlineRpm: Double = HapticPolicy.defaultRedlineRpm,
                absTicksEnabled: Bool = true,
                tcTicksEnabled: Bool = true,
                rumbleEnabled: Bool = true) {
        self.redlineRpm = max(1000, redlineRpm)
        self.absTicksEnabled = absTicksEnabled
        self.tcTicksEnabled = tcTicksEnabled
        self.rumbleEnabled = rumbleEnabled
        self.recentTransientNs = [UInt64](repeating: 0,
                                          count: HapticPolicy.globalTransientsPerSecond)
    }

    /// One decision pass. Call it on every downlink frame and on every UI tick
    /// that changes the brake, using a monotonic nanosecond clock.
    public mutating func step(now: UInt64,
                              telemetry: TelemetryFrame,
                              inputs: HapticInputs) -> HapticOutput {
        var output = HapticOutput()

        // Recentre is a direct answer to a button the driver just pressed, so it
        // is confirmed even while muted and it ignores the rate cap.
        if inputs.recenterRequested {
            output.transients.append(.recenter)
        }

        guard !inputs.muted else {
            previousAbs = telemetry.absActive
            previousTc = telemetry.tcActive
            output.rumble = publishRumble(.silent, now: now, force: true)
            return output
        }

        // Collected in priority order: lockup first, so when the cap bites it is
        // the tyre-chatter noise that gets dropped and never the one event that
        // tells the driver the front wheels have stopped turning.
        var candidates: [HapticTransient] = []

        if inputs.brakeNormalized >= Self.lockupThreshold, brakeArmed {
            brakeArmed = false
            candidates.append(.lockup)
        } else if inputs.brakeNormalized < Self.lockupRearm {
            brakeArmed = true
        }

        if inputs.shiftPressed {
            candidates.append(.shift)
        }

        if absTicksEnabled, telemetry.absActive {
            let rising = !previousAbs
            if rising || elapsedMs(now, lastAbsNs) >= Self.absIntervalMs {
                candidates.append(.abs)
                lastAbsNs = now
            }
        }

        if tcTicksEnabled, telemetry.tcActive {
            let rising = !previousTc
            if rising || elapsedMs(now, lastTcNs) >= Self.tcIntervalMs {
                candidates.append(.tc)
                lastTcNs = now
            }
        }

        previousAbs = telemetry.absActive
        previousTc = telemetry.tcActive

        for candidate in candidates where admit(candidate, now: now) {
            output.transients.append(candidate)
        }

        if Double(telemetry.rpm) > redlineRpm {
            // A modded car can rev past the assumed redline. Raising the ceiling
            // keeps the rumble from pinning flat at the top of every gear.
            redlineRpm = Double(telemetry.rpm)
        }

        let target = rumbleEnabled
            ? Self.rumble(rpm: telemetry.rpm,
                          slip: Double(telemetry.slip),
                          redlineRpm: redlineRpm)
            : .silent
        output.rumble = publishRumble(target, now: now, force: false)
        return output
    }

    /// `I = rpm < 300 ? 0 : 0.10 + 0.55·r²`, `S = 0.20 + 0.60·r + 0.2·min(slip/0.3, 1)`.
    ///
    /// Intensity is squared so idle does not feel like redline. The slip term
    /// rides on sharpness rather than intensity, which is what makes a slide feel
    /// gritty instead of merely louder.
    public static func rumble(rpm: UInt16, slip: Double, redlineRpm: Double) -> RumbleParameters {
        let r = min(1.0, max(0.0, Double(rpm) / redlineRpm))
        let intensity = rpm < rumbleMinimumRpm ? 0.0 : 0.10 + 0.55 * r * r
        let slipTerm = 0.2 * min(1.0, max(0.0, slip / 0.3))
        let sharpness = min(1.0, 0.20 + 0.60 * r + slipTerm)
        return RumbleParameters(intensity: min(1.0, intensity), sharpness: sharpness)
    }

    // MARK: - internals

    private func elapsedMs(_ now: UInt64, _ then: UInt64) -> Double {
        // `then == 0` means "never", which must read as infinitely long ago.
        guard then != 0 else { return .greatestFiniteMagnitude }
        guard now >= then else { return 0 }
        return Double(now - then) / 1_000_000.0
    }

    private mutating func admit(_ transient: HapticTransient, now: UInt64) -> Bool {
        let slot = transient.slot

        if elapsedMs(now, lastPerPlayerNs[slot]) < Self.perPlayerMinimumGapMs {
            return false
        }

        // Sliding window: the slot we are about to overwrite holds the 25th most
        // recent firing. If that is still inside the last second we are at the cap.
        if recentCount >= Self.globalTransientsPerSecond {
            let oldest = recentTransientNs[recentWriteIndex]
            if elapsedMs(now, oldest) < 1000 {
                return false
            }
        }

        lastPerPlayerNs[slot] = now
        recentTransientNs[recentWriteIndex] = now
        recentWriteIndex = (recentWriteIndex + 1) % Self.globalTransientsPerSecond
        recentCount = min(recentCount + 1, Self.globalTransientsPerSecond)
        return true
    }

    private mutating func publishRumble(_ next: RumbleParameters,
                                        now: UInt64,
                                        force: Bool) -> RumbleParameters? {
        guard !force else {
            lastRumble = next
            lastRumbleNs = now
            return next
        }

        if let last = lastRumble {
            let minGapMs = 1000.0 / Self.rumbleMaxUpdateHz
            guard elapsedMs(now, lastRumbleNs) >= minGapMs else { return nil }

            let movedEnough = abs(next.intensity - last.intensity) > Self.rumbleIntensityEpsilon
                || abs(next.sharpness - last.sharpness) > Self.rumbleSharpnessEpsilon
            guard movedEnough else { return nil }
        }

        lastRumble = next
        lastRumbleNs = now
        return next
    }
}
