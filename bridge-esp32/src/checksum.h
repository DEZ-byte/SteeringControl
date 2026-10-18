#pragma once

// XXH32 over exactly 28 bytes, with the OpenSteer seed.
//
// Host-compilable because this is the one function that has to agree with three
// other implementations, and that is checked by running it against
// tools/golden_vectors.json rather than by reading it.

#include <stddef.h>
#include <stdint.h>

namespace osteer {

constexpr uint32_t kXxhP1 = 0x9E3779B1u;
constexpr uint32_t kXxhP2 = 0x85EBCA77u;
constexpr uint32_t kXxhP3 = 0xC2B2AE3Du;
constexpr uint32_t kXxhP4 = 0x27D4EB2Fu;
constexpr uint32_t kXxhP5 = 0x165667B1u;

// "OST" plus protocol version 1. A nonzero seed means a 32-byte datagram from
// some other protocol cannot collide into ours by coincidence.
constexpr uint32_t kChecksumSeed = 0x4F535401u;
constexpr size_t kChecksumCovered = 28;

/// The protocol checksum: XXH32 over bytes [0, 28) of a frame.
///
/// Fixed length, so there is exactly one 16-byte stripe, three 4-byte lanes and no
/// single-byte tail. No loop over a variable length and no branch on size.
uint32_t xxh32_28(const uint8_t* data);

/// Full XXH32 for any length. Test-only; nothing on the packet path calls it.
uint32_t xxh32(const uint8_t* data, size_t length, uint32_t seed);

}  // namespace osteer
