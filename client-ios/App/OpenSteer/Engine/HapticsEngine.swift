import CoreHaptics
import Foundation
import OpenSteerCore

/// Turns the policy's decisions into motor output.
///
/// All decisions live in `HapticPolicy`, which is pure and unit-tested. This
/// class only owns the CoreHaptics objects and plays what it is told, so the
/// interesting logic is testable without a phone.
///
/// Runs on its own queue. CoreHaptics calls are not instant, and putting them on
/// the I/O queue would delay steering packets behind a buzz.
final class HapticsEngine: @unchecked Sendable {
    /// Every pattern is built once at start-up and replayed. Building a
    /// `CHHapticPattern` per event allocates and parses a dictionary, which is
    /// far too much work to do sixty times a second.
    private struct Players {
        var transients: [HapticTransient: CHHapticPatternPlayer]
        var rumble: CHHapticAdvancedPatternPlayer?
    }

    private let queue = DispatchQueue(label: "com.opensteer.haptics", qos: .userInitiated)
    private var engine: CHHapticEngine?
    private var players = Players(transients: [:], rumble: nil)
    private var rumbleRunning = false
    private var restarting = false

    /// False on hardware with no Taptic Engine, and on every simulator. The app
    /// still runs; it just has no haptics, and the HUD says so.
    let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private(set) var lastError: String?

    // MARK: - lifecycle

    func start() {
        guard isSupported else { return }
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    /// The main entry point, called from `ioQueue` on every motion sample and
    /// when the link mutes haptics. It hops to the haptics queue and returns
    /// immediately.
    func apply(_ output: HapticOutput) {
        guard isSupported else { return }
        guard !output.transients.isEmpty || output.rumble != nil else { return }

        queue.async { [weak self] in
            guard let self else { return }
            for transient in output.transients { self.fire(transient) }
            if let rumble = output.rumble { self.setRumble(rumble) }
        }
    }

    // MARK: - on the haptics queue

    private func startOnQueue() {
        guard engine == nil else { return }

        do {
            let engine = try CHHapticEngine()
            // Haptics only. Asking for audio too would take an audio session the
            // app does not need and can lose to the game's own sound.
            engine.playsHapticsOnly = true
            // Auto shutdown would stop the engine during a quiet straight and
            // cost a restart at the exact moment the first ABS tick is due.
            engine.isAutoShutdownEnabled = false

            engine.resetHandler = { [weak self] in
                // The server reset underneath us. Every player is now invalid.
                // CoreHaptics calls this back on a thread of its own, so the
                // rebuild has to hop to the queue that owns `engine`, `players`
                // and `rumbleRunning` before it touches any of them.
                guard let self else { return }
                self.queue.async { self.rebuildAfterReset() }
            }

            engine.stoppedHandler = { [weak self] reason in
                guard let self else { return }
                switch reason {
                case .applicationSuspended, .engineDestroyed:
                    // Expected. Backgrounding stops the engine.
                    break
                default:
                    self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.restartAfterStop()
                    }
                }
            }

            try engine.start()
            self.engine = engine
            try buildPlayers(on: engine)
            lastError = nil
        } catch {
            lastError = "\(error)"
            // The engine may already have started before the throw, and the
            // players built from it are dead the moment it is dropped. Leaving
            // them in place would report haptics as available and then silently
            // fail every event against an engine that is gone.
            engine?.stop()
            engine = nil
            players = Players(transients: [:], rumble: nil)
        }
    }

    private func stopOnQueue() {
        rumbleRunning = false
        try? players.rumble?.stop(atTime: CHHapticTimeImmediate)
        players = Players(transients: [:], rumble: nil)
        engine?.stop()
        engine = nil
    }

    private func rebuildAfterReset() {
        guard let engine else { return }
        do {
            try engine.start()
            try buildPlayers(on: engine)
        } catch {
            lastError = "\(error)"
        }
    }

    private func restartAfterStop() {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }

        engine = nil
        players = Players(transients: [:], rumble: nil)
        rumbleRunning = false
        startOnQueue()
    }

    private func buildPlayers(on engine: CHHapticEngine) throws {
        var built: [HapticTransient: CHHapticPatternPlayer] = [:]

        // Intensity is how hard, sharpness is how crisp. A lockup is a heavy dull
        // thud; an ABS tick is light and sharp, like the real pedal chattering.
        built[.abs] = try engine.makePlayer(with: Self.transientPattern(
            intensity: 0.6, sharpness: 0.9))
        built[.tc] = try engine.makePlayer(with: Self.transientPattern(
            intensity: 0.4, sharpness: 0.9))
        built[.shift] = try engine.makePlayer(with: Self.transientPattern(
            intensity: 0.9, sharpness: 0.5))
        built[.lockup] = try engine.makePlayer(with: Self.transientPattern(
            intensity: 1.0, sharpness: 0.3))
        built[.recenter] = try engine.makePlayer(with: Self.doubleTapPattern())

        players.transients = built

        // One continuous player, left running and steered by parameter updates.
        // Starting and stopping it per frame would click audibly at both ends.
        let rumble = try engine.makeAdvancedPlayer(with: Self.rumblePattern())
        rumble.loopEnabled = true
        players.rumble = rumble
        rumbleRunning = false
    }

    private func fire(_ transient: HapticTransient) {
        guard let player = players.transients[transient] else { return }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            lastError = "\(error)"
        }
    }

    private func setRumble(_ parameters: RumbleParameters) {
        guard let rumble = players.rumble else { return }

        do {
            if parameters.intensity <= 0.001 {
                if rumbleRunning {
                    try rumble.stop(atTime: CHHapticTimeImmediate)
                    rumbleRunning = false
                }
                return
            }

            if !rumbleRunning {
                try rumble.start(atTime: CHHapticTimeImmediate)
                rumbleRunning = true
            }

            try rumble.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                         value: Float(parameters.intensity),
                                         relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                         value: Float(parameters.sharpness),
                                         relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - patterns

    private static func transientPattern(intensity: Float,
                                         sharpness: Float) throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
        ], parameters: [])
    }

    /// Two taps 60 ms apart. Distinct from every single-tap event, so the driver
    /// can tell a recenter from a gear change without looking.
    private static func doubleTapPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ], relativeTime: 0.06),
        ], parameters: [])
    }

    /// A one-second continuous event, looped. Its intensity and sharpness are
    /// overridden live, so the starting values here barely matter.
    private static func rumblePattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0, duration: 1.0)
        ], parameters: [])
    }
}
