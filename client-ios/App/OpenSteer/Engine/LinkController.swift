import Foundation
import Network
import UIKit
import OpenSteerCore

/// Owns the connection, the motion loop and the haptics, and runs the state
/// machine that decides what happens next.
///
/// Everything in this class runs on one serial queue. The motion handler, the
/// send completions, the receive loop and the Network.framework state callbacks
/// all land there, which is what Network.framework guarantees and why this class
/// needs no locks.
final class LinkController: @unchecked Sendable {
    struct Status: Sendable, Equatable {
        var state: LinkState = .idle
        var message: String = "Not connected"
        var packetsSent: UInt64 = 0
        var framesReceived: UInt64 = 0
        var sendErrors = 0
        var droppedForBackpressure: UInt64 = 0
        var isPathExpensive = false
        var hapticsAvailable = true
        /// Send interval percentiles, measured on the phone because nothing else
        /// can see the interval between sends.
        var sendIntervalP50Ms: Double = 0
        var sendIntervalP99Ms: Double = 0
    }

    /// `.userInteractive` is the highest quality of service a non-realtime thread
    /// can ask for. The whole latency budget lives on this queue.
    private let ioQueue = DispatchQueue(label: "com.opensteer.io", qos: .userInteractive)
    private let motionOperationQueue: OperationQueue

    private let store: SnapshotStore
    private let haptics = HapticsEngine()
    private let sender = UplinkSender()
    private let receiver = DownlinkReceiver()

    private var machine = LinkStateMachine()
    private var policy = HapticPolicy()
    private var motion: MotionEngine?
    /// Set when the sensor refused to start, and the reason Streaming is blocked.
    private var motionFailure: String?
    private var connection: NWConnection?

    private var host = ""
    private var port: UInt16 = 9999
    private var mapper = SteerMapper()

    private var lastDownlinkNs: UInt64 = 0
    private var connectStartedNs: UInt64 = 0
    private var viabilityLostNs: UInt64 = 0
    private var backoffMs = LinkStateMachine.backoffStartMs
    private var supervisor: DispatchSourceTimer?
    private var backoffTimer: DispatchSourceTimer?
    private var status = Status()

    /// Delivered on the main queue, for SwiftUI.
    private let onStatus: @Sendable (Status) -> Void

    init(store: SnapshotStore, onStatus: @escaping @Sendable (Status) -> Void) {
        self.store = store
        self.onStatus = onStatus

        let queue = OperationQueue()
        queue.name = "com.opensteer.motion"
        // Serial. CoreMotion samples must be processed in order, and the
        // extractor and unwrapper have no locks because there is only ever one.
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        queue.underlyingQueue = ioQueue
        motionOperationQueue = queue

        status.hapticsAvailable = haptics.isSupported
    }

    // MARK: - public, callable from the main actor

    func start(host: String, port: UInt16, mapper: SteerMapper) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.host = host
            self.port = port
            self.mapper = mapper
            self.backoffMs = LinkStateMachine.backoffStartMs
            self.store.clearTelemetry()
            self.apply(self.machine.handle(.start))
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.apply(self.machine.handle(.stop))
        }
    }

    func enterBackground() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.apply(self.machine.handle(.enteredBackground))
        }
    }

    func recalibrate() {
        ioQueue.async { [weak self] in
            self?.motion?.requestRecalibration()
        }
    }

    func update(mapper: SteerMapper) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.mapper = mapper
            self.motion?.apply(mapper: mapper)
        }
    }

    func update(absTicks: Bool, tcTicks: Bool, rumble: Bool) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.policy.absTicksEnabled = absTicks
            self.policy.tcTicksEnabled = tcTicks
            self.policy.rumbleEnabled = rumble
        }
    }

    // MARK: - effects

    private func apply(_ effects: [LinkEffect]) {
        for effect in effects {
            switch effect {
            case .createConnection: openConnection()
            case .cancelConnection: closeConnection()
            case .startMotion: startMotion()
            case .stopMotion: stopMotion()
            case .armReceiveLoop: armReceive()
            case .startHaptics: haptics.start()
            case .stopHaptics: haptics.stop()
            case .muteHaptics: haptics.apply(Self.silence)
            case .unmuteHaptics: break
            case .scheduleBackoff: scheduleBackoff()
            case .setIdleTimerDisabled(let disabled): setIdleTimer(disabled: disabled)
            case .showDisconnectedReason: break
            }
        }
        publishStatus()
    }

    // MARK: - connection

    private func openConnection() {
        closeConnection()

        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            status.message = "Port \(port) is not valid"
            return
        }

        let parameters = NWParameters.udp
        // Marks the packets Expedited Forwarding, which maps to the Wi-Fi voice
        // queue. That queue skips the buffering a router applies to bulk traffic,
        // and it is the single largest latency win available over Wi-Fi.
        parameters.serviceClass = .interactiveVoice
        // Cellular is barred because the daemon is on the local network and a
        // cellular path cannot reach it.
        parameters.prohibitedInterfaceTypes = [.cellular]
        // `prohibitExpensivePaths` is not set: a personal hotspot is marked
        // expensive, and a hotspot is one of the two recommended ways to run this.

        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: portValue, using: parameters)
        self.connection = connection
        connectStartedNs = DispatchTime.now().uptimeNanoseconds
        viabilityLostNs = 0

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }

        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self else { return }
            self.viabilityLostNs = viable ? 0 : DispatchTime.now().uptimeNanoseconds
        }

        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.status.isPathExpensive = path.isExpensive
        }

        sender.attach(to: connection)
        sender.onErrorLimitReached = { [weak self] in
            guard let self else { return }
            self.apply(self.machine.handle(.sendErrorLimitReached))
        }

        connection.start(queue: ioQueue)
        startSupervisor()
        status.message = "Connecting to \(host):\(port)"
    }

    private func closeConnection() {
        receiver.stop()
        sender.detach()
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.pathUpdateHandler = nil
        connection?.cancel()
        connection = nil
        stopSupervisor()
        // A pending reconnect belongs to the connection it was scheduled for.
        // Left armed, it outlives an explicit stop by up to the backoff cap.
        backoffTimer?.cancel()
        backoffTimer = nil
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if let motionFailure {
                status.message = motionFailure
                publishStatus()
                return
            }
            backoffMs = LinkStateMachine.backoffStartMs
            status.message = "Streaming to \(host):\(port)"
            apply(machine.handle(.ready))

        case .waiting(let error):
            // Almost always the Local Network permission prompt going unanswered,
            // so the message names it rather than printing an error number.
            status.message = "Waiting: \(Self.describe(error))"
            publishStatus()

        // Only `.waiting` gets the 3 s dwell before Disconnected, via the
        // supervisor's connect timeout. `.failed` is a terminal NWConnection
        // state, so a dwell would only delay the backoff. See the link state
        // table in docs/ARCHITECTURE.md.
        case .failed(let error):
            status.message = "Failed: \(Self.describe(error))"
            apply(machine.handle(.failed))

        case .cancelled:
            publishStatus()

        default:
            publishStatus()
        }
    }

    private func armReceive() {
        guard let connection = self.connection else { return }

        // The silence clock starts now. Left at its old value it would measure
        // the whole outage that has just ended, and the first supervisor tick
        // after every reconnect would degrade a link a tenth of a second old.
        lastDownlinkNs = DispatchTime.now().uptimeNanoseconds

        receiver.onFrame = { [weak self] frame in
            self?.handleTelemetry(frame)
        }
        receiver.onFailure = { [weak self] _ in
            guard let self else { return }
            self.apply(self.machine.handle(.failed))
        }
        receiver.start(on: connection)
    }

    // MARK: - data flow

    private func startMotion() {
        guard motion == nil else { return }
        motionFailure = nil

        var configuration = MotionEngine.Configuration()
        configuration.mapper = mapper

        do {
            let engine = try MotionEngine(queue: motionOperationQueue,
                                          store: store,
                                          configuration: configuration) { [weak self] state, inputs in
                self?.handleSample(state, inputs)
            }
            try engine.start()
            motion = engine
        } catch {
            // A dead sensor is hard to diagnose from the driver's seat: the link
            // looks healthy and the wheel never moves. The state machine is held
            // in Connecting and the reason stays on the HUD instead.
            let reason = "Motion unavailable: \(error)"
            motionFailure = reason
            status.message = reason
            publishStatus()
        }
    }

    private func stopMotion() {
        motion?.stop()
        motion = nil
        // Otherwise a pedal that was held when the app went to the background is
        // still held when it comes back.
        store.resetControls()
    }

    /// One motion sample: send it, then let the haptics policy see the brake.
    private func handleSample(_ state: UplinkState, _ inputs: ControlInputs) {
        sender.send(state)

        var hapticInputs = HapticInputs()
        hapticInputs.brakeNormalized = inputs.brakeNormalized
        hapticInputs.shiftPressed = inputs.upshiftPending || inputs.downshiftPending
        hapticInputs.recenterRequested = inputs.calibrateRequested
        hapticInputs.muted = machine.state != .streaming

        let telemetry = store.readTelemetry()
        let output = policy.step(now: state.timestampNs,
                                 telemetry: telemetry.frame,
                                 inputs: hapticInputs)
        haptics.apply(output)
    }

    private func handleTelemetry(_ frame: TelemetryFrame) {
        let now = DispatchTime.now().uptimeNanoseconds
        lastDownlinkNs = now
        store.publishTelemetry(frame, at: now)

        let wasDegraded = machine.state == .degraded

        // Fed to the machine on every frame, not only on recovery. This event is
        // also what records that telemetry has ever arrived, and that record is
        // what gates the degrade, so skipping it while everything is healthy
        // would mean the link could never notice telemetry stopping.
        let effects = machine.handle(.downlinkReceived)

        if wasDegraded {
            status.message = "Streaming to \(host):\(port)"
        }

        // At 60 Hz, an empty effect list is the normal case. Running the publish
        // path anyway would rebuild the status strings sixty times a second for
        // nothing.
        if !effects.isEmpty {
            apply(effects)
        }
    }

    // MARK: - supervision

    /// One 100 ms timer covers every deadline in the state table.
    ///
    /// Three separate timers would each have to be canceled on every path out of
    /// a state; missing one lets a reconnect loop race itself.
    private func startSupervisor() {
        stopSupervisor()

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(100),
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.supervise() }
        supervisor = timer
        timer.resume()
    }

    private func stopSupervisor() {
        supervisor?.cancel()
        supervisor = nil
    }

    private func supervise() {
        let now = DispatchTime.now().uptimeNanoseconds

        switch machine.state {
        case .connecting:
            if elapsedMs(now, connectStartedNs) > LinkStateMachine.connectTimeoutMs {
                apply(machine.handle(.connectTimedOut))
            }

        case .streaming:
            // The machine itself gates this on having seen telemetry at least
            // once, so an ESP32 bridge that never sends any is not reported as a
            // fault for the whole session. The message follows the machine: on
            // the bridge this fires every tick and the state never moves, and
            // the status line has to keep saying Streaming.
            if elapsedMs(now, lastDownlinkNs) > LinkStateMachine.degradeAfterMs {
                let effects = machine.handle(.downlinkSilent)
                if machine.state == .degraded {
                    status.message = "Telemetry lost, steering still live"
                }
                apply(effects)
            }
            checkViability(now)

        case .degraded:
            checkViability(now)

        default:
            break
        }

        publishStatus()
    }

    private func checkViability(_ now: UInt64) {
        guard viabilityLostNs != 0 else { return }
        if elapsedMs(now, viabilityLostNs) > LinkStateMachine.viabilityGraceMs {
            status.message = "Network path went away"
            apply(machine.handle(.viabilityLostTooLong))
        }
    }

    private func scheduleBackoff() {
        backoffTimer?.cancel()

        // Jittered, so a phone and a bridge coming back at the same moment do not
        // retry in lockstep forever.
        let jitter = Double.random(in: 0.8...1.2)
        let delay = min(LinkStateMachine.backoffCapMs, backoffMs) * jitter
        backoffMs = min(LinkStateMachine.backoffCapMs, backoffMs * 2)

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delay)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.machine.handle(.backoffElapsed))
        }
        backoffTimer = timer
        timer.resume()
    }

    private func setIdleTimer(disabled: Bool) {
        // UIApplication is main-actor only, so this is the one effect that has to
        // leave the I/O queue.
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    private func publishStatus() {
        status.state = machine.state
        status.packetsSent = sender.sent
        status.framesReceived = receiver.received
        status.sendErrors = sender.consecutiveErrors
        status.droppedForBackpressure = sender.droppedForBackpressure
        status.sendIntervalP50Ms = sender.sendIntervalP50Ms
        status.sendIntervalP99Ms = sender.sendIntervalP99Ms

        if machine.state == .idle {
            status.message = "Not connected"
        }

        let snapshot = status
        onStatus(snapshot)
    }

    private func elapsedMs(_ now: UInt64, _ then: UInt64) -> Double {
        guard then != 0, now >= then else { return 0 }
        return Double(now - then) / 1_000_000.0
    }

    /// Publishing silence once is not the same as simply stopping: it leaves the
    /// motor quiet instead of holding whatever it was last told.
    private static let silence: HapticOutput = {
        var output = HapticOutput()
        output.rumble = .silent
        return output
    }()

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return "nothing is listening on that port"
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return "that address cannot be reached"
        case .posix(.EPERM):
            return "local network access was refused"
        default:
            return "\(error)"
        }
    }
}
