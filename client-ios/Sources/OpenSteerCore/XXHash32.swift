import Foundation

/// XXH32, in the one shape the protocol needs plus a generic form for the tests.
///
/// The generic version exists only so the unit tests can check this code against
/// the four published XXH32 reference vectors, so the fixed-size version below is
/// checked against an outside source rather than only against the other three
/// OpenSteer implementations.
public enum XXHash32 {
    public static let p1: UInt32 = 0x9E37_79B1
    public static let p2: UInt32 = 0x85EB_CA77
    public static let p3: UInt32 = 0xC2B2_AE3D
    public static let p4: UInt32 = 0x27D4_EB2F
    public static let p5: UInt32 = 0x1656_67B1

    /// "OST" plus protocol version 1. A nonzero seed means a packet from some
    /// other protocol that happens to be 32 bytes cannot collide into ours.
    public static let seed: UInt32 = 0x4F53_5401

    /// Bytes [0, 28): everything before the checksum field itself.
    public static let coveredBytes = 28

    @inline(__always)
    private static func rotl(_ x: UInt32, _ r: UInt32) -> UInt32 {
        (x << r) | (x >> (32 - r))
    }

    /// Little-endian 32-bit load, built by OR-ing bytes.
    ///
    /// Never a pointer cast. Offsets 20 and 24 are not 4-aligned inside the
    /// packet, and a cast there is undefined behavior on paper even where it
    /// happens to work on ARM.
    @inline(__always)
    private static func u32(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
        UInt32(b[i])
            | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
    }

    @inline(__always)
    private static func round(_ acc: UInt32, _ lane: UInt32) -> UInt32 {
        rotl(acc &+ (lane &* p2), 13) &* p1
    }

    /// The protocol checksum. Exactly 28 bytes in, so there is one 16-byte stripe,
    /// three 4-byte lanes and no 1-byte tail. No loops over variable length, no
    /// branches on size.
    public static func hash28(_ b: UnsafeRawBufferPointer) -> UInt32 {
        precondition(b.count >= coveredBytes,
                     "hash28 needs at least \(coveredBytes) bytes, got \(b.count)")

        var v1 = seed &+ p1 &+ p2
        var v2 = seed &+ p2
        var v3 = seed
        var v4 = seed &- p1

        v1 = round(v1, u32(b, 0))
        v2 = round(v2, u32(b, 4))
        v3 = round(v3, u32(b, 8))
        v4 = round(v4, u32(b, 12))

        var h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
        h = h &+ UInt32(coveredBytes)

        h = rotl(h &+ (u32(b, 16) &* p3), 17) &* p4
        h = rotl(h &+ (u32(b, 20) &* p3), 17) &* p4
        h = rotl(h &+ (u32(b, 24) &* p3), 17) &* p4

        h ^= h >> 15
        h = h &* p2
        h ^= h >> 13
        h = h &* p3
        h ^= h >> 16
        return h
    }

    public static func hash28(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { hash28($0) }
    }

    /// Full XXH32 for any length. Test-only; the hot path never calls it.
    public static func generic(_ b: UnsafeRawBufferPointer, seed: UInt32 = 0) -> UInt32 {
        let n = b.count
        var i = 0
        var h: UInt32

        if n >= 16 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1

            while i + 16 <= n {
                v1 = round(v1, u32(b, i))
                v2 = round(v2, u32(b, i + 4))
                v3 = round(v3, u32(b, i + 8))
                v4 = round(v4, u32(b, i + 12))
                i += 16
            }

            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
        } else {
            h = seed &+ p5
        }

        h = h &+ UInt32(truncatingIfNeeded: n)

        while i + 4 <= n {
            h = rotl(h &+ (u32(b, i) &* p3), 17) &* p4
            i += 4
        }

        while i < n {
            h = rotl(h &+ (UInt32(b[i]) &* p5), 11) &* p1
            i += 1
        }

        h ^= h >> 15
        h = h &* p2
        h ^= h >> 13
        h = h &* p3
        h ^= h >> 16
        return h
    }

    public static func generic(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBytes { generic($0, seed: seed) }
    }
}
