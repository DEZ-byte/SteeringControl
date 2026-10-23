import Foundation
import Network
import OpenSteerCore

/// Reads 16-byte telemetry frames off the same connection the uplink sends on.
///
/// One connected UDP flow carries both directions. The daemon replies from the
/// port it was sent to, so the phone needs no listener, no second socket and no
/// inbound firewall rule.
///
/// Confined to `ioQueue`.
final class DownlinkReceiver: @unchecked Sendable {
    private var connection: NWConnection?
    private var running = false
    /// Stamps each receive with the session that armed it. After a stop and a
    /// new start, a late completion from the old connection would otherwise see
    /// `running` true again and fail or feed the new session.
    private var epoch: UInt64 = 0

    private(set) var received: UInt64 = 0
    private(set) var rejected: UInt64 = 0

    /// Called on `ioQueue` for every valid frame.
    var onFrame: ((TelemetryFrame) -> Void)?
    /// Called on `ioQueue` when the connection reports a receive error that ends
    /// the flow.
    var onFailure: ((NWError) -> Void)?

    func start(on connection: NWConnection) {
        epoch &+= 1
        self.connection = connection
        running = true
        received = 0
        rejected = 0
        arm()
    }

    func stop() {
        epoch &+= 1
        running = false
        connection = nil
    }

    /// Re-arms itself from its own completion rather than from a timer.
    ///
    /// `receiveMessage` delivers exactly one datagram and then stops listening,
    /// so the only way to keep hearing is to ask again the moment one arrives.
    /// Miss a re-arm and the link goes quiet with no error anywhere.
    private func arm() {
        guard running, let connection else { return }

        let armedEpoch = epoch
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, self.running, self.epoch == armedEpoch else { return }

            if let content {
                if let frame = DownlinkCodec.decode(content) {
                    self.received &+= 1
                    self.onFrame?(frame)
                } else {
                    // Wrong size or wrong magic. On a shared network stray
                    // datagrams are normal and are not worth a state change.
                    self.rejected &+= 1
                }
            }

            if let error {
                self.running = false
                self.onFailure?(error)
                return
            }

            self.arm()
        }
    }
}
