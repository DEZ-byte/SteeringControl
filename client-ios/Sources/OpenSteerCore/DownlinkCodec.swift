import Foundation

/// One frame of game telemetry, as received.
public struct TelemetryFrame: Sendable, Equatable {
    public var rpm: UInt16
    public var absActive: Bool
    public var tcActive: Bool
    public var slip: Float
    /// Zero in production. With the daemon's `--echo-rtt` debug flag this carries
    /// the low 32 bits of the timestamp from the last accepted uplink, which lets
    /// the phone measure a true round trip against its own clock alone.
    public var reserved: UInt32

    public init(rpm: UInt16 = 0,
                absActive: Bool = false,
                tcActive: Bool = false,
                slip: Float = 0,
                reserved: UInt32 = 0) {
        self.rpm = rpm
        self.absActive = absActive
        self.tcActive = tcActive
        self.slip = slip
        self.reserved = reserved
    }

    public static let zero = TelemetryFrame()
}

public enum DownlinkCodec {
    public static let size = 16

    /// Wire bytes `31 42 46 46`.
    public static let magic: UInt32 = 0x4646_4231

    public enum Offset {
        public static let magic = 0
        public static let rpm = 4
        public static let absActive = 6
        public static let tcActive = 7
        public static let slip = 8
        public static let reserved = 12
    }

    /// Returns nil for anything that is not one of our frames. A wrong length or a
    /// wrong magic is silently dropped: on a shared network we will see stray
    /// datagrams, and they are not worth a state change.
    public static func decode(_ source: UnsafeRawBufferPointer) -> TelemetryFrame? {
        guard source.count == size, let base = source.baseAddress else { return nil }

        let m = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: Offset.magic,
                                                        as: UInt32.self))
        guard m == magic else { return nil }

        let rpm = UInt16(littleEndian: base.loadUnaligned(fromByteOffset: Offset.rpm,
                                                          as: UInt16.self))
        let absByte = base.loadUnaligned(fromByteOffset: Offset.absActive, as: UInt8.self)
        let tcByte = base.loadUnaligned(fromByteOffset: Offset.tcActive, as: UInt8.self)
        let bits = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: Offset.slip,
                                                           as: UInt32.self))
        let reserved = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: Offset.reserved,
                                                               as: UInt32.self))

        return TelemetryFrame(rpm: rpm,
                              absActive: absByte != 0,
                              tcActive: tcByte != 0,
                              slip: sanitize(Float(bitPattern: bits)),
                              reserved: reserved)
    }

    public static func decode(_ bytes: [UInt8]) -> TelemetryFrame? {
        bytes.withUnsafeBytes { decode($0) }
    }

    public static func decode(_ data: Data) -> TelemetryFrame? {
        data.withUnsafeBytes { decode($0) }
    }

    /// Test-only. The phone never sends a downlink frame.
    public static func encode(_ frame: TelemetryFrame) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: magic.littleEndian,
                            toByteOffset: Offset.magic, as: UInt32.self)
            base.storeBytes(of: frame.rpm.littleEndian,
                            toByteOffset: Offset.rpm, as: UInt16.self)
            base.storeBytes(of: UInt8(frame.absActive ? 1 : 0),
                            toByteOffset: Offset.absActive, as: UInt8.self)
            base.storeBytes(of: UInt8(frame.tcActive ? 1 : 0),
                            toByteOffset: Offset.tcActive, as: UInt8.self)
            base.storeBytes(of: frame.slip.bitPattern.littleEndian,
                            toByteOffset: Offset.slip, as: UInt32.self)
            base.storeBytes(of: frame.reserved.littleEndian,
                            toByteOffset: Offset.reserved, as: UInt32.self)
        }
        return bytes
    }

    /// NaN and infinity become 0; everything else is clamped to 0...1.
    ///
    /// Written to match `DownlinkPacket.Sanitize` in the C# core branch for
    /// branch, including the fact that negative zero is passed through unchanged
    /// rather than normalized. A NaN reaching the haptics engine would make the
    /// rumble intensity NaN and silence the motor with no error anywhere.
    public static func sanitize(_ slip: Float) -> Float {
        if slip.isNaN || slip.isInfinite { return 0 }
        return slip < 0 ? 0 : (slip > 1 ? 1 : slip)
    }
}
