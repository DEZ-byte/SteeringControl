#pragma once

// The receive path: raw lwIP, no sockets, no heap.
//
// A BSD socket on this chip means a second task, a copy out of the pbuf into a
// user buffer, and a blocking recvfrom that has to be woken. Registering a
// callback straight on the UDP control block skips all three: the packet is
// validated on the tcpip task that already owns it, and what reaches the HID task
// is a 32-byte struct in a mailbox that was allocated at start-up.
//
// Invariant I14: nothing on this path allocates. The bridge's by-hand heap check
// confirms it by watching the free heap across a ten-minute soak.

#include <stdint.h>

namespace osteer {

/// Binds port 9999 and registers the callback, from inside `tcpip_callback`.
///
/// lwIP is not thread-safe and its raw API must only be touched from the tcpip
/// task. Calling `udp_bind` from `setup()` directly would work most of the time
/// and fail intermittently, which is hard to diagnose.
bool startUplinkReceiver();

/// Counters for the serial console. Written with relaxed atomics from the tcpip
/// task and read from the main loop, so they are approximate: the cost of making
/// them exact is a lock on the packet path.
struct UplinkStats {
    uint32_t accepted;
    uint32_t badLength;
    uint32_t badMagic;
    uint32_t badChecksum;
    uint32_t badPadding;
    uint32_t duplicate;
    uint32_t stale;
    uint32_t dropped;
    uint32_t reseeds;
};

UplinkStats readUplinkStats();
void resetUplinkStats();

}  // namespace osteer
