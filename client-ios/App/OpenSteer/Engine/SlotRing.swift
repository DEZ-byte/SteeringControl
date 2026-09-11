import Foundation
import OpenSteerCore

/// Sixteen 32-byte send slots in one allocation, each pre-wrapped in a `Data`
/// that points straight at it.
///
/// Network.framework holds on to the `Data` you hand `send` until the send
/// completes, which is some microseconds later and not on this call stack. Write
/// into a slot before that completion arrives and you transmit a half-updated
/// packet. Sixteen slots at 120 Hz is 133 ms of headroom, far more than any send
/// takes.
///
/// Each slot is tracked individually rather than by a count of outstanding sends,
/// because completions are not promised to arrive in the order the sends were
/// made. A count would let a late completion free somebody else's slot.
///
/// `Data(bytesNoCopy:deallocator:.none)` is what keeps the payload copy count at
/// zero: the memory is ours, allocated once at start-up, and never freed by Data.
///
/// Confined to `ioQueue`. Nothing here is thread-safe on its own.
final class SlotRing {
    static let slotCount = 16

    private let region: UnsafeMutableRawPointer
    private let slots: [Data]
    private var busy: [Bool]
    private var nextIndex = 0

    private(set) var inFlight = 0
    /// How many samples were dropped because every slot was still out. Nonzero
    /// means the network stack has stopped draining, which the HUD should say.
    private(set) var droppedForBackpressure: UInt64 = 0

    init() {
        let byteCount = SlotRing.slotCount * UplinkCodec.size
        region = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        region.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        var wrapped: [Data] = []
        wrapped.reserveCapacity(SlotRing.slotCount)
        for i in 0..<SlotRing.slotCount {
            let start = region.advanced(by: i * UplinkCodec.size)
            wrapped.append(Data(bytesNoCopy: start,
                                count: UplinkCodec.size,
                                deallocator: .none))
        }
        slots = wrapped
        busy = [Bool](repeating: false, count: SlotRing.slotCount)
    }

    deinit {
        region.deallocate()
    }

    /// Encodes into a free slot and returns the `Data` to hand to `send`, plus the
    /// token to pass back to `release` from the send completion.
    ///
    /// Returns nil when every slot is still out. Dropping the newest sample is
    /// right here: the next one is 8 ms away and is a better answer than a queue
    /// of stale steering angles arriving late.
    func encode(_ state: UplinkState) -> (payload: Data, token: Int)? {
        guard let index = claimSlot() else {
            droppedForBackpressure &+= 1
            return nil
        }

        let start = region.advanced(by: index * UplinkCodec.size)
        UplinkCodec.encode(state,
                           into: UnsafeMutableRawBufferPointer(start: start,
                                                               count: UplinkCodec.size))
        return (slots[index], index)
    }

    /// Call from the send completion, on `ioQueue`.
    func release(_ token: Int) {
        guard slots.indices.contains(token), busy[token] else { return }
        busy[token] = false
        inFlight -= 1
    }

    /// Cancelling a connection abandons every outstanding completion, so the
    /// slots have to be taken back by hand or the ring stays permanently full.
    func releaseAll() {
        for i in busy.indices { busy[i] = false }
        inFlight = 0
    }

    private func claimSlot() -> Int? {
        for offset in 0..<SlotRing.slotCount {
            let index = (nextIndex + offset) % SlotRing.slotCount
            if !busy[index] {
                busy[index] = true
                inFlight += 1
                nextIndex = (index + 1) % SlotRing.slotCount
                return index
            }
        }
        return nil
    }
}
