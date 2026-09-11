#include "checksum.h"

namespace osteer {
namespace {

inline uint32_t rotl(uint32_t x, unsigned r) {
    return (x << r) | (x >> (32 - r));
}

/// Little-endian 32-bit load, assembled by OR-ing bytes.
///
/// Never a pointer cast. Offsets 20 and 24 sit four-byte aligned inside the packet
/// but the receive buffer itself carries no alignment promise, and a cast there is
/// undefined behaviour on paper even where the hardware would have coped.
inline uint32_t u32(const uint8_t* b, size_t i) {
    return static_cast<uint32_t>(b[i]) |
           (static_cast<uint32_t>(b[i + 1]) << 8) |
           (static_cast<uint32_t>(b[i + 2]) << 16) |
           (static_cast<uint32_t>(b[i + 3]) << 24);
}

inline uint32_t round32(uint32_t acc, uint32_t lane) {
    return rotl(acc + lane * kXxhP2, 13) * kXxhP1;
}

inline uint32_t avalanche(uint32_t h) {
    h ^= h >> 15;
    h *= kXxhP2;
    h ^= h >> 13;
    h *= kXxhP3;
    h ^= h >> 16;
    return h;
}

}  // namespace

uint32_t xxh32_28(const uint8_t* data) {
    uint32_t v1 = kChecksumSeed + kXxhP1 + kXxhP2;
    uint32_t v2 = kChecksumSeed + kXxhP2;
    uint32_t v3 = kChecksumSeed;
    uint32_t v4 = kChecksumSeed - kXxhP1;

    v1 = round32(v1, u32(data, 0));
    v2 = round32(v2, u32(data, 4));
    v3 = round32(v3, u32(data, 8));
    v4 = round32(v4, u32(data, 12));

    uint32_t h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
    h += static_cast<uint32_t>(kChecksumCovered);

    h = rotl(h + u32(data, 16) * kXxhP3, 17) * kXxhP4;
    h = rotl(h + u32(data, 20) * kXxhP3, 17) * kXxhP4;
    h = rotl(h + u32(data, 24) * kXxhP3, 17) * kXxhP4;

    return avalanche(h);
}

uint32_t xxh32(const uint8_t* data, size_t length, uint32_t seed) {
    size_t i = 0;
    uint32_t h;

    if (length >= 16) {
        uint32_t v1 = seed + kXxhP1 + kXxhP2;
        uint32_t v2 = seed + kXxhP2;
        uint32_t v3 = seed;
        uint32_t v4 = seed - kXxhP1;

        while (i + 16 <= length) {
            v1 = round32(v1, u32(data, i));
            v2 = round32(v2, u32(data, i + 4));
            v3 = round32(v3, u32(data, i + 8));
            v4 = round32(v4, u32(data, i + 12));
            i += 16;
        }

        h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
    } else {
        h = seed + kXxhP5;
    }

    h += static_cast<uint32_t>(length);

    while (i + 4 <= length) {
        h = rotl(h + u32(data, i) * kXxhP3, 17) * kXxhP4;
        i += 4;
    }

    while (i < length) {
        h = rotl(h + static_cast<uint32_t>(data[i]) * kXxhP5, 11) * kXxhP1;
        i += 1;
    }

    return avalanche(h);
}

}  // namespace osteer
