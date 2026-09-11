import Foundation
import Network
import OpenSteerCore

/// Puts 32-byte frames on the wire, one per motion sample.
///
/// Confined to `ioQueue`. The connection is started on that queue, so every
/// Network.framework callback lands there too, which is the only placement the
/// framework actually promises.
final class UplinkSender: @unchecked Sendable {
    /// Enough consecutive failures to mean the network really is gone rather than
    /// briefly unhappy. At 120 Hz this is 200 ms of solid errors.
    static let sendErrorLimit = LinkStateMachine.sendErrorLimit

    private let ring = SlotRing()
    private var connection: NWConnection?
    private var completion: NWConnection.SendCompletion?
    private var epoch: UInt64 = 0

    private(set) var sent: UInt64 = 0
    private(set) var consecutiveErrors = 0
    private(set) var lastError: NWError?

    /// Nothing else on the phone can see the interval between sends, so it is
    /// measured here and shown in the diagnostics line.
    private var intervals = IntervalTracker()
    private var lastSendNs: UInt64 = 0

    var sendIntervalP50Ms: Double { intervals.percentileMs(0.50) }
    var sendIntervalP99Ms: Double { intervals.percentileMs(0.99) }

    /// Fired when the error run passes the limit, so the controller can drop the
    /// connection and start backing off.
    var onErrorLimitReached: (() -> Void)?

    var droppedForBackpressure: UInt64 { ring.droppedForBackpressure }
    var inFlight: Int { ring.inFlight }

    /// The completion closure is built once, here, and reused for every send.
    ///
    /// Building it per packet would allocate 120 closures a second on the hot
    /// path for no reason. Network.framework retains whatever it is given, so a
    /// fresh one each time is pure garbage.
    func attach(to connection: NWConnection) {
        self.connection = connection
        ring.releaseAll()
        tokenHead = 0
        tokenTail = 0
        consecutiveErrors = 0
        lastError = nil
        lastSendNs = 0

        // `cancel()` completes whatever was still outstanding with ECANCELED, and
        // those callbacks arrive after the next connection has already been
        // attached. Stamping the closure is what keeps them from dequeuing the new
        // connection's tokens and freeing slots that are still on the wire.
        epoch &+= 1
        let attachedEpoch = epoch
        completion = .contentProcessed { [weak self] error in
            guard let self, self.epoch == attachedEpoch else { return }
            self.finish(error)
        }
    }

    func detach() {
        epoch &+= 1
        connection = nil
        completion = nil
        // The outstanding completions are stale from here on and are ignored, so
        // the slots have to be taken back by hand or the ring stays full.
        ring.releaseAll()
        tokenHead = 0
        tokenTail = 0
    }

    /// Encodes and sends. Returns false when the frame was dropped rather than
    /// sent, which the HUD counts but which is not itself an error.
    @discardableResult
    func send(_ state: UplinkState) -> Bool {
        guard let connection, let completion else { return false }
        guard let slot = ring.encode(state) else { return false }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastSendNs != 0, now > lastSendNs {
            intervals.record(now - lastSendNs)
        }
        lastSendNs = now

        enqueue(slot.token)
        connection.send(content: slot.payload,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: completion)
        sent &+= 1
        return true
    }

    // The completion closure is shared, so it cannot carry its own slot token.
    // Sends are issued and completed on the same serial queue, and
    // Network.framework delivers completions for one connection in the order the
    // sends were made, so a first-in-first-out queue of tokens pairs each
    // completion with the slot it belongs to.
    //
    // Fixed size, no allocation, no O(n) shift: the ring can never have more
    // outstanding sends than it has slots. One spare entry, because head == tail
    // has to mean empty, and without the spare a completely full queue would look
    // empty instead.
    private static let tokenCapacity = SlotRing.slotCount + 1
    private var tokenQueue = [Int](repeating: -1, count: UplinkSender.tokenCapacity)
    private var tokenHead = 0
    private var tokenTail = 0

    private func enqueue(_ token: Int) {
        tokenQueue[tokenTail] = token
        tokenTail = (tokenTail + 1) % Self.tokenCapacity
    }

    private func dequeue() -> Int? {
        guard tokenHead != tokenTail else { return nil }
        let token = tokenQueue[tokenHead]
        tokenHead = (tokenHead + 1) % Self.tokenCapacity
        return token
    }

    private func finish(_ error: NWError?) {
        if let token = dequeue() {
            ring.release(token)
        }

        guard let error else {
            consecutiveErrors = 0
            return
        }

        lastError = error

        // Only the three errors that mean the path itself is gone count toward
        // tearing the link down. Everything else is transient: ENOBUFS in
        // particular is the send buffer filling under congestion, which is the
        // one moment you least want to drop a connection that is still working.
        guard Self.meansPathIsGone(error) else { return }

        consecutiveErrors += 1

        if consecutiveErrors >= Self.sendErrorLimit {
            onErrorLimitReached?()
        }
    }

    private static func meansPathIsGone(_ error: NWError) -> Bool {
        switch error {
        case .posix(.ENETDOWN), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return true
        default:
            return false
        }
    }
}

/// A fixed-size ring of recent intervals, for percentiles on the device.
///
/// Nothing here allocates after construction and nothing sorts until something
/// asks for a number, which happens at most fifteen times a second in the
/// diagnostics line rather than on the send path.
private struct IntervalTracker {
    static let capacity = 4096

    private var samples = [UInt64](repeating: 0, count: IntervalTracker.capacity)
    private var writeIndex = 0
    private var count = 0

    mutating func record(_ nanoseconds: UInt64) {
        samples[writeIndex] = nanoseconds
        writeIndex = (writeIndex + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    func percentileMs(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let sorted = samples[0..<count].sorted()
        // Nearest rank, the same rule the Windows daemon's histogram uses, so the
        // two ends of the link report percentiles that can be compared.
        let rank = max(0, min(count - 1, Int((fraction * Double(count)).rounded(.up)) - 1))
        return Double(sorted[rank]) / 1_000_000.0
    }
}
