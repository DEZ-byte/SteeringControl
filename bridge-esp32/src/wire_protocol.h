#pragma once

// The OpenSteer wire format, byte for byte.
//
// Deliberately free of Arduino, ESP-IDF and lwIP headers so it compiles for a
// host test as readily as for the chip. The static assertions below are the whole
// point: they turn a silent layout change into a build failure rather than into a
// wheel that steers sideways on one platform only.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace osteer {

// 0x4F535452 stored little-endian appears on the wire as 52 54 53 4F, which is
// ASCII "RTSO". "OSTR" is only what the number spells when printed most
// significant byte first, and is not what is transmitted.
constexpr uint32_t kUplinkMagic = 0x4F535452u;
constexpr uint32_t kDownlinkMagic = 0x46464231u;

constexpr size_t kUplinkSize = 32;
constexpr size_t kDownlinkSize = 16;

constexpr uint8_t kUplinkMagicBytes[4] = {0x52, 0x54, 0x53, 0x4F};

// Button bits. Level-triggered on the wire; edge detection is the receiver's job.
constexpr uint32_t kBtnUpshift = 1u << 0;
constexpr uint32_t kBtnDownshift = 1u << 1;
constexpr uint32_t kBtnHandbrake = 1u << 2;

#pragma pack(push, 1)
struct UplinkPacket {
    uint32_t magic;        // 0
    uint16_t sequence;     // 4
    int16_t steer;         // 6   never -32768 from a sender
    uint16_t throttle;     // 8
    uint16_t brake;        // 10
    uint16_t clutch;       // 12
    uint16_t padding;      // 14  sender writes 0, receiver rejects anything else
    uint32_t buttons;      // 16
    uint64_t timestampNs;  // 20  four-byte aligned only
    uint32_t checksum;     // 28  XXH32 over bytes [0, 28)
};

struct DownlinkPacket {
    uint32_t magic;     // 0
    uint16_t rpm;       // 4
    uint8_t absActive;  // 6
    uint8_t tcActive;   // 7
    float tireSlip;     // 8
    uint32_t reserved;  // 12
};
#pragma pack(pop)

static_assert(sizeof(UplinkPacket) == kUplinkSize, "uplink must be exactly 32 bytes");
static_assert(sizeof(DownlinkPacket) == kDownlinkSize, "downlink must be exactly 16 bytes");
static_assert(offsetof(UplinkPacket, sequence) == 4, "sequence moved");
static_assert(offsetof(UplinkPacket, steer) == 6, "steer moved");
static_assert(offsetof(UplinkPacket, throttle) == 8, "throttle moved");
static_assert(offsetof(UplinkPacket, brake) == 10, "brake moved");
static_assert(offsetof(UplinkPacket, clutch) == 12, "clutch moved");
static_assert(offsetof(UplinkPacket, padding) == 14, "padding moved");
static_assert(offsetof(UplinkPacket, buttons) == 16, "buttons moved");
static_assert(offsetof(UplinkPacket, timestampNs) == 20, "timestamp moved");
static_assert(offsetof(UplinkPacket, checksum) == 28, "checksum moved");

// The format is little-endian on the wire and every field is read by plain
// struct access, so a big-endian build would decode garbage with no complaint.
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
              "OpenSteer packets are little-endian");
#endif

/// Copies 32 bytes into a packet.
///
/// `memcpy` rather than a cast. Taking the address of a member of a packed struct
/// is undefined behaviour, and a pointer cast onto an arbitrary receive buffer is
/// the same mistake wearing a different hat. Xtensa LX7 handles unaligned loads in
/// hardware, so this costs nothing here, but the header also has to be correct on
/// a host where that is not true.
inline void readUplink(const uint8_t* src, UplinkPacket& out) {
    memcpy(&out, src, kUplinkSize);
}

/// Invariant I10: senders never emit -32768; receivers saturate it.
///
/// It is the one 16-bit value with no positive twin, so a game mirroring the axis
/// would be asked for a number it cannot represent.
inline int16_t saturateSteer(int16_t steer) {
    return steer < -32767 ? static_cast<int16_t>(-32767) : steer;
}

/// Signed 16-bit wrap-around distance between two sequence numbers.
///
/// Positive means newer, zero a duplicate, negative stale. Written as an explicit
/// unsigned subtraction and a cast so it stays defined across the 65535 to 0 wrap
/// instead of relying on signed overflow.
inline int seqDelta(uint16_t seq, uint16_t lastSeq) {
    return static_cast<int16_t>(static_cast<uint16_t>(seq - lastSeq));
}

}  // namespace osteer
