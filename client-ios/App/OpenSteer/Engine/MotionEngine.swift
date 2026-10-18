import CoreMotion
import Foundation
import OpenSteerCore

/// The 120 Hz steering loop.
///
/// Every `CMDeviceMotion` sample runs the whole chain on `ioQueue` and never
/// touches the main thread: attitude to relative twist, unwrap, shape, encode,
/// send. The main actor only ever reads a finished snapshot.
///
/// Motion never goes through the main queue. SwiftUI shares that queue with
/// layout, text rendering and gesture recognition, so a single busy frame would
/// delay the steering packet behind it. The budget for the whole chain is under
/// two microseconds; a main-thread hop can cost thousands.
final class MotionEngine: @unchecked Sendable {
    enum PipelineError: Error, Equatable {
        /// The caller tried to run the sensor handler on the main queue.
        case mainQueueForbidden
        /// The device has no device-motion support, which means no usable gyro.
        case motionUnavailable
        /// The requested attitude reference frame is not offered by this device.
        case referenceFrameUnavailable
    }

    struct Configuration {
        var updateHz: Double = 120
        var mapper = SteerMapper()
        /// `.xArbitraryZVertical` needs no magnetometer and no calibration dance.
        /// The corrected variant trades a slower settle for less yaw drift and is
        /// worth it only when the phone is held flat.
        var referenceFrame: CMAttitudeReferenceFrame = .xArbitraryZVertical
    }

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue
    private let store: SnapshotStore
    private let onSample: @Sendable (UplinkState, ControlInputs) -> Void

    // Everything below is touched only from `queue`, which is serial. That
    // confinement is the synchronization; there is no lock because there is no
    // second writer.
    private var configuration: Configuration
    private var extractor = TwistExtractor()
    private var unwrapper = AngleUnwrapper()
    private var upshift = PulseLatch()
    private var downshift = PulseLatch()
    private var reference: Quat?
    private var sequence: UInt16 = 0
    private var lastSampleTimestamp: TimeInterval = 0
    private var smoothedHz: Double = 0

    private(set) var isRunning = false

    /// Throws rather than silently degrading: a sensor loop on the main queue
    /// still mostly works, so the added latency would go unnoticed.
    init(queue: OperationQueue,
         store: SnapshotStore,
         configuration: Configuration = Configuration(),
         onSample: @escaping @Sendable (UplinkState, ControlInputs) -> Void) throws {
        guard queue !== OperationQueue.main,
              queue.underlyingQueue !== DispatchQueue.main else {
            throw PipelineError.mainQueueForbidden
        }

        self.queue = queue
        self.store = store
        self.configuration = configuration
        self.onSample = onSample
    }

    // MARK: - lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard motionManager.isDeviceMotionAvailable else {
            throw PipelineError.motionUnavailable
        }
        guard CMMotionManager.availableAttitudeReferenceFrames()
            .contains(configuration.referenceFrame) else {
            throw PipelineError.referenceFrameUnavailable
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / configuration.updateHz
        motionManager.showsDeviceMovementDisplay = false
        isRunning = true

        motionManager.startDeviceMotionUpdates(using: configuration.referenceFrame,
                                               to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            #if DEBUG
            // If this fires, the handler has been rerouted to the main queue and
            // the latency budget no longer holds.
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            self.handle(motion)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
    }

    /// Re-reads the reference attitude on the next sample. The wheel becomes
    /// straight wherever the phone is being held right now.
    func requestRecalibration() {
        queue.addOperation { [weak self] in
            self?.reference = nil
        }
    }

    func apply(mapper: SteerMapper) {
        queue.addOperation { [weak self] in
            self?.configuration.mapper = mapper
        }
    }

    // MARK: - the loop

    private func handle(_ motion: CMDeviceMotion) {
        // CMQuaternion is (x, y, z, w); Quat is (w, x, y, z). This is the one
        // place the two orders meet.
        let attitude = motion.attitude.quaternion
        let current = Quat(w: attitude.w, x: attitude.x, y: attitude.y, z: attitude.z)

        // Pedals and the one-shot flags come out in a single acquisition.
        let inputs = store.takeControls()

        if inputs.calibrateRequested || reference == nil {
            reference = current
            extractor.reset()
            unwrapper.reset()
        }
        guard let reference = self.reference else { return }

        // Twist about the screen normal, then unwrapped so a 900 degree
        // wheel can travel past half a turn.
        let theta = extractor.step(reference: reference, current: current)
        let continuous = unwrapper.step(theta)

        // Shaped exactly once, here. The host has no shaper at all.
        let normalized = configuration.mapper.normalized(continuousDegrees: continuous)
        let steer = SteerMapper.int16(fromNormalized: normalized)

        // Paddle taps are latched so a press shorter than one 8 ms tick still
        // reaches the host in at least three packets.
        if inputs.upshiftPending { upshift.press(); upshift.release() }
        if inputs.downshiftPending { downshift.press(); downshift.release() }

        var buttons = ButtonMask()
        if upshift.tick() { buttons.insert(.upshift) }
        if downshift.tick() { buttons.insert(.downshift) }
        if inputs.handbrake { buttons.insert(.handbrake) }

        // Sequence and timestamp; `onSample` encodes and sends.
        sequence &+= 1
        let state = UplinkState(sequence: sequence,
                                steer: steer,
                                throttle: inputs.throttle,
                                brake: inputs.brake,
                                clutch: inputs.clutch,
                                buttons: buttons.rawValue,
                                timestampNs: DispatchTime.now().uptimeNanoseconds)

        // `calibrateRequested` is left set because the haptics engine uses it to
        // confirm the recenter with a double tap the driver can feel.
        onSample(state, inputs)

        // The UI reads this whenever it draws; it never waits for it.
        updateRate(with: motion.timestamp)

        var snapshot = MotionSnapshot()
        snapshot.thetaDegrees = continuous
        snapshot.steerNormalized = normalized
        snapshot.steerI16 = steer
        snapshot.sequence = sequence
        snapshot.motionHz = smoothedHz
        snapshot.isCalibrated = true
        store.publishMotion(snapshot)
    }

    /// A slow exponential average of the real sensor rate.
    ///
    /// A phone that quietly caps device motion at 100 Hz is acceptable, but the
    /// driver should be able to see that is what happened rather than wonder why
    /// the wheel feels slightly soft.
    private func updateRate(with timestamp: TimeInterval) {
        defer { lastSampleTimestamp = timestamp }
        guard lastSampleTimestamp > 0 else { return }

        let delta = timestamp - lastSampleTimestamp
        guard delta > 0.0001, delta < 1 else { return }

        let instant = 1.0 / delta
        smoothedHz = smoothedHz == 0 ? instant : smoothedHz * 0.95 + instant * 0.05
    }
}
