import XCTest
import OpenSteerCore
@testable import OpenSteer

/// The sensor handler must never run on the main queue. A steering loop that
/// shares a queue with layout and text rendering still mostly works, and the
/// driver cannot tell a bad connection from a busy main thread, so the engine
/// refuses to start instead.
final class MotionEngineTests: XCTestCase {
    /// `OperationQueue.underlyingQueue` is `unowned(unsafe)` and does not keep
    /// the dispatch queue alive. XCTest makes a new instance for each test, so
    /// this property holds the queue for as long as the test runs.
    private let ioQueue = DispatchQueue(label: "test.io", qos: .userInteractive)

    private func makeQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        queue.underlyingQueue = ioQueue
        return queue
    }

    func testMainOperationQueueIsRefused() {
        XCTAssertThrowsError(
            try MotionEngine(queue: .main, store: SnapshotStore()) { _, _ in }
        ) { error in
            XCTAssertEqual(error as? MotionEngine.PipelineError, .mainQueueForbidden)
        }
    }

    // There is no test here for a queue whose `underlyingQueue` is the main
    // dispatch queue. Foundation forbids that assignment outright and raises an
    // NSInvalidArgumentException, which Swift cannot catch, so the test would not
    // fail on its own: it would abort the whole bundle and take every other test
    // in it down. `OperationQueue.main.underlyingQueue` is nil, so there is no
    // supported way to build the state either. The test above covers the queue a
    // caller can actually pass.

    func testSerialBackgroundQueueIsAccepted() {
        XCTAssertNoThrow(
            try MotionEngine(queue: makeQueue(), store: SnapshotStore()) { _, _ in }
        )
    }

    /// A fresh engine has not started, so nothing is running and no sensor has
    /// been touched. This is what makes the initializer safe to call in a test
    /// on a simulator with no gyroscope.
    func testEngineDoesNotStartOnInit() throws {
        let engine = try MotionEngine(queue: makeQueue(),
                                      store: SnapshotStore()) { _, _ in }
        XCTAssertFalse(engine.isRunning)
    }
}

/// The touch-to-wire path, without a phone.
final class ControlInputsTests: XCTestCase {
    /// The store hands out the one-shot flags and clears them in the same
    /// acquisition. Splitting that into a read and a separate clear could count a
    /// paddle tap twice, or lose it between the two calls.
    func testOneShotFlagsAreTakenExactlyOnce() {
        let store = SnapshotStore()
        store.updateControls {
            $0.upshiftPending = true
            $0.calibrateRequested = true
            $0.throttle = 40000
        }

        let first = store.takeControls()
        XCTAssertTrue(first.upshiftPending)
        XCTAssertTrue(first.calibrateRequested)
        XCTAssertEqual(first.throttle, 40000)

        let second = store.takeControls()
        XCTAssertFalse(second.upshiftPending)
        XCTAssertFalse(second.calibrateRequested)
        XCTAssertEqual(second.throttle, 40000, "pedals are level, not one-shot")
    }

    func testResetClearsEverything() {
        let store = SnapshotStore()
        store.updateControls {
            $0.throttle = 65535
            $0.brake = 65535
            $0.handbrake = true
        }
        store.resetControls()

        let inputs = store.peekControls()
        XCTAssertEqual(inputs, ControlInputs())
    }

    /// Concurrent writers and readers must never tear a struct in half. A HUD
    /// showing a wheel angle from one sample beside a sequence number from the
    /// next is the visible symptom of reading field by field.
    func testSnapshotsSurviveConcurrentAccess() {
        let store = SnapshotStore()
        let finished = expectation(description: "hammered")
        finished.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<20_000 {
                var snapshot = MotionSnapshot()
                snapshot.sequence = UInt16(truncatingIfNeeded: i)
                snapshot.steerI16 = Int16(truncatingIfNeeded: i)
                store.publishMotion(snapshot)
            }
            finished.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<20_000 {
                let snapshot = store.readMotion()
                XCTAssertEqual(snapshot.sequence,
                               UInt16(truncatingIfNeeded: Int(snapshot.steerI16)))
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 30)
    }
}
