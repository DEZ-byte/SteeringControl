import Combine
import Foundation
import SwiftUI
import OpenSteerCore

/// What SwiftUI watches.
///
/// Republishes at about 15 Hz, not at the sensor rate. The numbers here are text
/// a human reads; nobody can follow an engine speed updating 120 times a second,
/// and every republish re-evaluates the view tree. The one thing that does need
/// to move at full rate, the wheel graphic, bypasses this object entirely and
/// reads the snapshot store from its own display link.
@MainActor
final class SessionViewModel: ObservableObject {
    /// Slow enough to be cheap, fast enough that the heads-up display does not
    /// look frozen.
    static let hudHz: Double = 15

    @Published private(set) var status = LinkController.Status()
    @Published private(set) var motion = MotionSnapshot()
    @Published private(set) var telemetry = TelemetrySnapshot()
    @Published private(set) var display = DisplaySnapshot()
    @Published private(set) var throttle: Double = 0
    @Published private(set) var brake: Double = 0
    @Published private(set) var isHandbrakeHeld = false

    let store = SnapshotStore()

    private var controller: LinkController?
    private var hudTimer: Timer?

    var isRunning: Bool { status.state != .idle }

    var isLive: Bool { status.state == .streaming || status.state == .degraded }

    func makeController() -> LinkController {
        if let controller { return controller }

        // Weak on purpose. The view model owns the controller, and the controller
        // holds this closure, so a strong capture here would be a cycle that
        // keeps a live connection alive for the life of the process.
        let created = LinkController(store: store) { [weak self] status in
            // Hops from the I/O queue to the main actor. The controller never
            // touches SwiftUI itself.
            Task { @MainActor in
                self?.status = status
            }
        }
        controller = created
        return created
    }

    // MARK: - session

    func start(settings: AppSettings) {
        let controller = makeController()
        controller.update(absTicks: settings.absTicksEnabled,
                          tcTicks: settings.tcTicksEnabled,
                          rumble: settings.rumbleEnabled)
        controller.start(host: settings.host.trimmingCharacters(in: .whitespaces),
                         port: settings.portValue,
                         mapper: settings.mapper)
        startHudTimer()
    }

    func stop() {
        controller?.stop()
        stopHudTimer()
        throttle = 0
        brake = 0
        isHandbrakeHeld = false
        store.resetControls()
    }

    func enterBackground() {
        controller?.enterBackground()
        stopHudTimer()
    }

    func recalibrate() {
        store.updateControls { $0.calibrateRequested = true }
        controller?.recalibrate()
    }

    func apply(settings: AppSettings) {
        controller?.update(mapper: settings.mapper)
        controller?.update(absTicks: settings.absTicksEnabled,
                           tcTicks: settings.tcTicksEnabled,
                           rumble: settings.rumbleEnabled)
    }

    // MARK: - inputs from the touch surface

    func updatePedals(throttle: Double, brake: Double) {
        self.throttle = throttle
        self.brake = brake

        store.updateControls { inputs in
            inputs.throttleNormalized = throttle
            inputs.brakeNormalized = brake
            inputs.throttle = UInt16((throttle * 65535).rounded(.toNearestOrAwayFromZero))
            inputs.brake = UInt16((brake * 65535).rounded(.toNearestOrAwayFromZero))
        }
    }

    func paddle(_ mask: ButtonMask) {
        store.updateControls { inputs in
            if mask.contains(.upshift) { inputs.upshiftPending = true }
            if mask.contains(.downshift) { inputs.downshiftPending = true }
        }
    }

    /// Held, not toggled. A handbrake that latches on is a handbrake you find out
    /// about halfway down the next straight.
    func setHandbrake(_ held: Bool) {
        isHandbrakeHeld = held
        store.updateControls { $0.handbrake = held }
    }

    // MARK: - heads-up display

    private func startHudTimer() {
        stopHudTimer()
        // Built unscheduled and added in `.common` mode only. `scheduledTimer`
        // would register it in `.default` as well, and it would then fire twice
        // per interval. `.common` is what keeps it running while a thumb is on
        // the screen; a default-mode timer stops dead during touch tracking.
        let timer = Timer(timeInterval: 1.0 / Self.hudHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullSnapshots() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    private func stopHudTimer() {
        hudTimer?.invalidate()
        hudTimer = nil
    }

    private func pullSnapshots() {
        motion = store.readMotion()
        telemetry = store.readTelemetry()
        display = store.readDisplay()
    }
}
