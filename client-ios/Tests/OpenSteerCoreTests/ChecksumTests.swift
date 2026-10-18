import XCTest
@testable import OpenSteerCore

/// The checksum against the published XXH32 vectors and the three protocol
/// known-answer tests.
final class ChecksumTests: XCTestCase {
    private let golden = GoldenVectors.shared

    /// The four published XXH32 reference vectors. Without them, Swift agreeing
    /// with C# would not rule out both being wrong in the same way.
    func testGenericAgainstPublishedReferenceVectors() {
        XCTAssertEqual(golden.xxh32Generic.count, 4,
                       "expected the four published reference vectors")

        for vector in golden.xxh32Generic {
            let data = goldenHex(vector.dataHex)
            let seed = goldenU32(vector.seed)
            let expected = goldenU32(vector.expect)
            XCTAssertEqual(XXHash32.generic(data, seed: seed), expected,
                           "XXH32 of \(data.count) bytes with seed \(vector.seed)")
        }
    }

    func testFixedSizeKnownAnswers() {
        for vector in golden.xxh3228 {
            let data = goldenHex(vector.dataHex)
            XCTAssertEqual(data.count, XXHash32.coveredBytes, vector.name)
            XCTAssertEqual(XXHash32.hash28(data), goldenU32(vector.expect), vector.name)
        }
    }

    /// The fixed-size path takes a different code route from the generic one. If
    /// they ever disagree, the protocol quietly stops interoperating.
    func testFixedAgreesWithGenericOnTheSameInput() {
        for vector in golden.xxh3228 {
            let data = goldenHex(vector.dataHex)
            XCTAssertEqual(XXHash32.hash28(data),
                           XXHash32.generic(data, seed: XXHash32.seed),
                           vector.name)
        }
    }

    func testSeedAndCoverageMatchTheFixture() {
        XCTAssertEqual(golden.checksum.algorithm, "XXH32")
        XCTAssertEqual(goldenU32(golden.checksum.seed), XXHash32.seed)
        XCTAssertEqual(golden.checksum.coveredBytes, XXHash32.coveredBytes)
        XCTAssertEqual(golden.checksum.storedAtOffset, UplinkCodec.Offset.checksum)
    }

    /// A single flipped bit anywhere in the covered range has to change the
    /// output, or the checksum is not doing its job.
    func testEveryCoveredBitChangesTheResult() {
        var frame = [UInt8](repeating: 0, count: UplinkCodec.size)
        for i in 0..<UplinkCodec.size { frame[i] = UInt8(i &* 7 & 0xFF) }
        let baseline = XXHash32.hash28(frame)

        for byte in 0..<XXHash32.coveredBytes {
            for bit in 0..<8 {
                var mutated = frame
                mutated[byte] ^= UInt8(1 << bit)
                XCTAssertNotEqual(XXHash32.hash28(mutated), baseline,
                                  "flipping byte \(byte) bit \(bit) did not change the checksum")
            }
        }
    }

    /// Bytes 28 to 31 hold the checksum itself and must not feed into it.
    func testBytesPastTheCoveredRangeAreIgnored() {
        var frame = [UInt8](repeating: 0, count: UplinkCodec.size)
        let baseline = XXHash32.hash28(frame)
        for i in XXHash32.coveredBytes..<UplinkCodec.size { frame[i] = 0xFF }
        XCTAssertEqual(XXHash32.hash28(frame), baseline)
    }
}
