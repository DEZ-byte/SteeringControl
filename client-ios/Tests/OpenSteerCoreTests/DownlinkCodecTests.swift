import XCTest
@testable import OpenSteerCore

final class DownlinkCodecTests: XCTestCase {
    private let golden = GoldenVectors.shared

    func testDecodeMatchesGoldenFields() {
        XCTAssertEqual(golden.sizes.downlink, DownlinkCodec.size)

        for vector in golden.downlink {
            let bytes = goldenHex(vector.hex)
            XCTAssertEqual(bytes.count, DownlinkCodec.size, vector.name)

            guard let frame = DownlinkCodec.decode(bytes) else {
                XCTFail("\(vector.name) failed to decode")
                continue
            }

            XCTAssertEqual(frame.rpm, vector.fields.rpm, vector.name)
            XCTAssertEqual(frame.absActive, vector.fields.absActive != 0, vector.name)
            XCTAssertEqual(frame.tcActive, vector.fields.tcActive != 0, vector.name)
            XCTAssertEqual(frame.slip, Float(vector.fields.slip), vector.name)
            XCTAssertEqual(frame.reserved, 0, vector.name)
        }
    }

    func testEncodeRoundTripsToGoldenHex() {
        for vector in golden.downlink {
            let frame = TelemetryFrame(rpm: vector.fields.rpm,
                                       absActive: vector.fields.absActive != 0,
                                       tcActive: vector.fields.tcActive != 0,
                                       slip: Float(vector.fields.slip))
            XCTAssertEqual(hexString(DownlinkCodec.encode(frame)),
                           hexString(goldenHex(vector.hex)), vector.name)
        }
    }

    /// D2 carries −0.0. It compares equal to 0.0, which is what the haptics path
    /// needs, and the daemon leaves the sign bit alone, so the wire bytes still
    /// say `00 00 00 80`.
    func testNegativeZeroSlip() {
        let bytes = goldenHex("31 42 46 46 40 1f 00 00 00 00 00 80 00 00 00 00")
        guard let frame = DownlinkCodec.decode(bytes) else {
            return XCTFail("D2 failed to decode")
        }
        XCTAssertEqual(frame.slip, 0.0)
        XCTAssertTrue(frame.slip.sign == .minus, "the daemon does not normalise −0.0")
        XCTAssertEqual(frame.rpm, 8000)
    }

    func testWrongSizeIsRejected() {
        let good = DownlinkCodec.encode(TelemetryFrame(rpm: 1000))
        XCTAssertNil(DownlinkCodec.decode(Array(good.dropLast())))
        XCTAssertNil(DownlinkCodec.decode(good + [0]))
        XCTAssertNil(DownlinkCodec.decode([UInt8]()))
    }

    func testWrongMagicIsRejected() {
        var bytes = DownlinkCodec.encode(TelemetryFrame(rpm: 1000))
        bytes[0] ^= 0xFF
        XCTAssertNil(DownlinkCodec.decode(bytes))
    }

    /// The uplink magic must never be mistaken for a downlink frame. If the phone
    /// ever hears its own traffic reflected back, it has to ignore it.
    func testUplinkMagicIsNotAccepted() {
        var bytes = [UInt8](repeating: 0, count: DownlinkCodec.size)
        bytes[0] = 0x52; bytes[1] = 0x54; bytes[2] = 0x53; bytes[3] = 0x4F
        XCTAssertNil(DownlinkCodec.decode(bytes))
    }

    /// A NaN reaching the rumble maths would make the intensity NaN and silence
    /// the motor with no error reported anywhere.
    func testSanitize() {
        XCTAssertEqual(DownlinkCodec.sanitize(.nan), 0)
        XCTAssertEqual(DownlinkCodec.sanitize(.infinity), 0)
        XCTAssertEqual(DownlinkCodec.sanitize(-.infinity), 0)
        XCTAssertEqual(DownlinkCodec.sanitize(-5), 0)
        XCTAssertEqual(DownlinkCodec.sanitize(5), 1)
        XCTAssertEqual(DownlinkCodec.sanitize(0.25), 0.25)
        XCTAssertEqual(DownlinkCodec.sanitize(1), 1)
    }

    func testNaNOnTheWireDecodesToZero() {
        var frame = DownlinkCodec.encode(TelemetryFrame(rpm: 3000))
        let nanBits = Float.nan.bitPattern.littleEndian
        withUnsafeBytes(of: nanBits) { source in
            for i in 0..<4 { frame[DownlinkCodec.Offset.slip + i] = source[i] }
        }
        XCTAssertEqual(DownlinkCodec.decode(frame)?.slip, 0)
    }

    /// `--echo-rtt` puts the low 32 bits of the last accepted uplink timestamp
    /// here. Production leaves it zero and the phone ignores it either way.
    func testReservedIsCarriedThrough() {
        let frame = TelemetryFrame(rpm: 1, absActive: true, tcActive: true,
                                   slip: 0.5, reserved: 0xDEAD_BEEF)
        XCTAssertEqual(DownlinkCodec.decode(DownlinkCodec.encode(frame))?.reserved,
                       0xDEAD_BEEF)
    }

    /// The daemon writes 0 or 1, but the contract says any nonzero means true.
    func testNonZeroFlagsAreTrue() {
        var bytes = DownlinkCodec.encode(TelemetryFrame(rpm: 1))
        bytes[DownlinkCodec.Offset.absActive] = 0x7F
        bytes[DownlinkCodec.Offset.tcActive] = 0xFF
        let frame = DownlinkCodec.decode(bytes)
        XCTAssertEqual(frame?.absActive, true)
        XCTAssertEqual(frame?.tcActive, true)
    }
}
