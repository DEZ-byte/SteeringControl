import Foundation

/// What the phone sends, as a value type.
///
/// This is not the wire layout. Swift pads a `UInt64` field to an 8-byte
/// boundary, so a struct with these members in this order is 36 bytes, not 32.
/// Rather than fight the layout with attributes that Swift does not have,
/// every field is written to an explicit byte offset and the golden hex vectors
/// check the result. There is no `MemoryLayout` assertion, because it would
/// check the in-memory layout rather than the wire layout.
public struct UplinkState: Sendable, Equatable {
    public var sequence: UInt16
    public var steer: Int16
    public var throttle: UInt16
    public var brake: UInt16
    public var clutch: UInt16
    public var buttons: UInt32
    public var timestampNs: UInt64

    public init(sequence: UInt16 = 0,
                steer: Int16 = 0,
                throttle: UInt16 = 0,
                brake: UInt16 = 0,
                clutch: UInt16 = 0,
                buttons: UInt32 = 0,
                timestampNs: UInt64 = 0) {
        self.sequence = sequence
        self.steer = steer
        self.throttle = throttle
        self.brake = brake
        self.clutch = clutch
        self.buttons = buttons
        self.timestampNs = timestampNs
    }
}

public enum UplinkCodec {
    public static let size = 32

    /// Stored little-endian, so the wire bytes read `52 54 53 4F`, which is ASCII
    /// "RTSO". "OSTR" is what the number spells when printed most-significant
    /// byte first, and is not what goes out.
    public static let magic: UInt32 = 0x4F53_5452

    public enum Offset {
        public static let magic = 0
        public static let sequence = 4
        public static let steer = 6
        public static let throttle = 8
        public static let brake = 10
        public static let clutch = 12
        public static let padding = 14
        public static let buttons = 16
        public static let timestampNs = 20
        public static let checksum = 28
    }

    /// Writes a complete 32-byte frame, checksum included.
    ///
    /// `destination` must have at least 32 bytes. Offset 20 is only 4-aligned, not
    /// 8, which `storeBytes` has allowed since Swift 5.7 (SE-0349); nothing here
    /// casts a pointer to `UInt64`.
    public static func encode(_ state: UplinkState,
                              into destination: UnsafeMutableRawBufferPointer) {
        precondition(destination.count >= size,
                     "uplink needs \(size) bytes, got \(destination.count)")

        guard let base = destination.baseAddress else { return }

        base.storeBytes(of: magic.littleEndian,
                        toByteOffset: Offset.magic, as: UInt32.self)
        base.storeBytes(of: state.sequence.littleEndian,
                        toByteOffset: Offset.sequence, as: UInt16.self)
        base.storeBytes(of: saturate(state.steer).littleEndian,
                        toByteOffset: Offset.steer, as: Int16.self)
        base.storeBytes(of: state.throttle.littleEndian,
                        toByteOffset: Offset.throttle, as: UInt16.self)
        base.storeBytes(of: state.brake.littleEndian,
                        toByteOffset: Offset.brake, as: UInt16.self)
        base.storeBytes(of: state.clutch.littleEndian,
                        toByteOffset: Offset.clutch, as: UInt16.self)

        // The host rejects a nonzero pad as bad_pad. It is a cheap tripwire for a
        // sender that has drifted out of sync with this layout.
        base.storeBytes(of: UInt16(0).littleEndian,
                        toByteOffset: Offset.padding, as: UInt16.self)

        base.storeBytes(of: state.buttons.littleEndian,
                        toByteOffset: Offset.buttons, as: UInt32.self)
        base.storeBytes(of: state.timestampNs.littleEndian,
                        toByteOffset: Offset.timestampNs, as: UInt64.self)

        let checksum = XXHash32.hash28(UnsafeRawBufferPointer(start: base, count: size))
        base.storeBytes(of: checksum.littleEndian,
                        toByteOffset: Offset.checksum, as: UInt32.self)
    }

    /// Convenience for tests and one-off sends. Allocates, so not for the 120 Hz path.
    public static func encode(_ state: UplinkState) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { encode(state, into: $0) }
        return bytes
    }

    /// Invariant I10. −32768 is the one Int16 with no positive twin, so senders
    /// never emit it and receivers saturate it if they see it anyway.
    public static func saturate(_ steer: Int16) -> Int16 {
        steer < -32767 ? -32767 : steer
    }
}
