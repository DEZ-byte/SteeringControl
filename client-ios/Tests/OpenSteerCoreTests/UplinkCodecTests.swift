import XCTest
@testable import OpenSteerCore

/// Uplink encoding against the golden hex vectors, byte for byte.
final class UplinkCodecTests: XCTestCase {
    private let golden = GoldenVectors.shared

    /// Byte-exact equality against the fixture. There is no
    /// `MemoryLayout<UplinkState>.size == 32` assertion anywhere: Swift pads the
    /// `UInt64` field to an 8-byte boundary and makes the struct 36 bytes. The
    /// hex below is the layout proof, not the type.
    func testEncodeMatchesGoldenHex() {
        XCTAssertEqual(golden.sizes.uplink, UplinkCodec.size)

        for vector in golden.uplink {
            let state = UplinkState(sequence: vector.fields.seq,
                                    steer: vector.fields.steer,
                                    throttle: vector.fields.throttle,
                                    brake: vector.fields.brake,
                                    clutch: vector.fields.clutch,
                                    buttons: vector.fields.buttons,
                                    timestampNs: vector.fields.tsNs)

            let encoded = UplinkCodec.encode(state)
            let expected = goldenHex(vector.hex)

            XCTAssertEqual(encoded.count, UplinkCodec.size, vector.name)
            XCTAssertEqual(hexString(encoded), hexString(expected), vector.name)
        }
    }

    func testChecksumFieldMatchesTheFixture() {
        for vector in golden.uplink {
            let state = UplinkState(sequence: vector.fields.seq,
                                    steer: vector.fields.steer,
                                    throttle: vector.fields.throttle,
                                    brake: vector.fields.brake,
                                    clutch: vector.fields.clutch,
                                    buttons: vector.fields.buttons,
                                    timestampNs: vector.fields.tsNs)

            let encoded = UplinkCodec.encode(state)
            let stored = UInt32(encoded[28])
                | (UInt32(encoded[29]) << 8)
                | (UInt32(encoded[30]) << 16)
                | (UInt32(encoded[31]) << 24)

            XCTAssertEqual(stored, goldenU32(vector.checksum), vector.name)
            XCTAssertEqual(stored, XXHash32.hash28(encoded), vector.name)
        }
    }

    /// The magic is stored little-endian, so it reads "RTSO" on the wire. Getting
    /// this backwards gives a link that looks connected and drops every packet.
    func testMagicWireOrder() {
        let encoded = UplinkCodec.encode(UplinkState())
        XCTAssertEqual(Array(encoded[0..<4]), [0x52, 0x54, 0x53, 0x4F])
    }

    func testPaddingIsAlwaysZero() {
        let state = UplinkState(sequence: .max, steer: 32767, throttle: .max,
                                brake: .max, clutch: .max, buttons: .max,
                                timestampNs: .max)
        let encoded = UplinkCodec.encode(state)
        XCTAssertEqual(encoded[14], 0)
        XCTAssertEqual(encoded[15], 0)
    }

    /// Invariant I10. −32768 is the one Int16 with no positive twin.
    func testMinimumInt16IsSaturated() {
        XCTAssertEqual(UplinkCodec.saturate(-32768), -32767)
        XCTAssertEqual(UplinkCodec.saturate(-32767), -32767)
        XCTAssertEqual(UplinkCodec.saturate(0), 0)
        XCTAssertEqual(UplinkCodec.saturate(32767), 32767)

        let encoded = UplinkCodec.encode(UplinkState(steer: -32768))
        XCTAssertEqual(Array(encoded[6..<8]), [0x01, 0x80], "expected −32767 on the wire")
    }

    func testSteerKnownAnswers() {
        XCTAssertEqual(Array(UplinkCodec.encode(UplinkState(steer: -32767))[6..<8]),
                       [0x01, 0x80])
        XCTAssertEqual(Array(UplinkCodec.encode(UplinkState(steer: 0))[6..<8]),
                       [0x00, 0x00])
        XCTAssertEqual(Array(UplinkCodec.encode(UplinkState(steer: 32767))[6..<8]),
                       [0xFF, 0x7F])
    }

    /// Encoding into a slot of a shared region must not spill into its neighbors.
    func testEncodeStaysInsideItsSlot() {
        var region = [UInt8](repeating: 0xAA, count: UplinkCodec.size * 3)
        let state = UplinkState(sequence: 7, steer: -1234, throttle: 65535,
                                brake: 1, clutch: 2, buttons: 0xFFFF_FFFF,
                                timestampNs: .max)

        region.withUnsafeMutableBytes { raw in
            let slot = UnsafeMutableRawBufferPointer(
                rebasing: raw[UplinkCodec.size..<(UplinkCodec.size * 2)])
            UplinkCodec.encode(state, into: slot)
        }

        XCTAssertTrue(region[0..<UplinkCodec.size].allSatisfy { $0 == 0xAA },
                      "wrote before the slot")
        XCTAssertTrue(region[(UplinkCodec.size * 2)...].allSatisfy { $0 == 0xAA },
                      "wrote past the slot")
        XCTAssertEqual(Array(region[UplinkCodec.size..<(UplinkCodec.size * 2)]),
                       UplinkCodec.encode(state))
    }
}
