#include "uplink_udp.h"

#include <atomic>

#include "esp_timer.h"
#include "lwip/ip_addr.h"
#include "lwip/pbuf.h"
#include "lwip/tcpip.h"
#include "lwip/udp.h"

#include "checksum.h"
#include "config.h"
#include "hid_task.h"
#include "wire_protocol.h"

namespace osteer {
namespace {

// Relaxed: these are counters for a human reading a console, not values anything
// branches on. Ordering them would put a barrier on the packet path to make a
// diagnostic line marginally more truthful.
std::atomic<uint32_t> gAccepted{0};
std::atomic<uint32_t> gBadLength{0};
std::atomic<uint32_t> gBadMagic{0};
std::atomic<uint32_t> gBadChecksum{0};
std::atomic<uint32_t> gBadPadding{0};
std::atomic<uint32_t> gDuplicate{0};
std::atomic<uint32_t> gStale{0};
std::atomic<uint32_t> gDropped{0};
std::atomic<uint32_t> gReseeds{0};

inline void bump(std::atomic<uint32_t>& counter) {
    counter.fetch_add(1, std::memory_order_relaxed);
}

/// Sequence tracking, private to the tcpip task.
///
/// Not shared, not atomic, not locked: exactly one thread ever touches it, which
/// is lwIP's own. The moment a second reader appears this has to change.
struct LinkState {
    uint16_t lastSeq = 0;
    int64_t lastRxUs = 0;
    bool first = true;
};

LinkState gLink;
udp_pcb* gPcb = nullptr;

// Scratch for the copy out of the pbuf. One buffer, reused, owned by the tcpip
// task for the same reason LinkState is.
uint8_t gFrame[kUplinkSize];

/// Runs on the tcpip task for every datagram that reaches port 9999.
///
/// Validation order matches the host exactly, and exactly one counter moves per
/// datagram: a frame that is both short and wrong-magic is counted once, as short,
/// because that is the first thing checked. Counting it twice would make the
/// totals stop adding up to the number of packets received.
void onUplinkRaw(void* /*arg*/, udp_pcb* /*pcb*/, pbuf* p,
                 const ip_addr_t* /*addr*/, u16_t /*port*/) {
    if (p == nullptr) {
        return;
    }

    if (p->tot_len != kUplinkSize) {
        bump(gBadLength);
        pbuf_free(p);
        return;
    }

    // pbuf_copy_partial rather than reading p->payload directly. A datagram can
    // arrive split across a chain of buffers, and on the day that happens a direct
    // read silently sees only the first fragment.
    if (pbuf_copy_partial(p, gFrame, kUplinkSize, 0) != kUplinkSize) {
        bump(gBadLength);
        pbuf_free(p);
        return;
    }

    pbuf_free(p);

    UplinkPacket pkt;
    readUplink(gFrame, pkt);

    if (pkt.magic != kUplinkMagic) {
        bump(gBadMagic);
        return;
    }

    if (xxh32_28(gFrame) != pkt.checksum) {
        bump(gBadChecksum);
        return;
    }

    if (pkt.padding != 0) {
        bump(gBadPadding);
        return;
    }

    const int64_t now = esp_timer_get_time();

    // The gate reopens in the thread that owns it. After a quarter second of
    // silence the link is being rebuilt from scratch, so the next sequence number
    // is whatever the phone feels like and must not be judged against the old one.
    if (!gLink.first && (now - gLink.lastRxUs) > static_cast<int64_t>(cfg::kHardMs * 1000.0)) {
        gLink.first = true;
    }

    if (gLink.first) {
        gLink.first = false;
        gLink.lastSeq = pkt.sequence;
        bump(gReseeds);
    } else {
        const int delta = seqDelta(pkt.sequence, gLink.lastSeq);
        if (delta == 0) {
            bump(gDuplicate);
            return;
        }
        if (delta < 0) {
            bump(gStale);
            return;
        }
        if (delta > 1) {
            gDropped.fetch_add(static_cast<uint32_t>(delta - 1), std::memory_order_relaxed);
        }
        gLink.lastSeq = pkt.sequence;
    }

    gLink.lastRxUs = now;
    bump(gAccepted);

    MailMsg msg;
    msg.kind = MsgKind::Packet;
    msg.packet = pkt;
    postMail(msg);
}

/// Runs on the tcpip task, which is the only place lwIP's raw API may be touched.
void bindOnTcpipTask(void* arg) {
    bool* ok = static_cast<bool*>(arg);

    gPcb = udp_new();
    if (gPcb == nullptr) {
        *ok = false;
        return;
    }

    // Any address, not the access point's own: the interface has not finished
    // coming up when this runs, and binding to an address that does not exist yet
    // fails.
    if (udp_bind(gPcb, IP_ADDR_ANY, cfg::kUdpPort) != ERR_OK) {
        udp_remove(gPcb);
        gPcb = nullptr;
        *ok = false;
        return;
    }

    udp_recv(gPcb, onUplinkRaw, nullptr);
    *ok = true;
}

}  // namespace

bool startUplinkReceiver() {
    bool ok = false;
    // Blocking form. It runs the callback on the tcpip task and waits, so the
    // result is known before setup() moves on to say the bridge is ready.
    if (tcpip_callback(bindOnTcpipTask, &ok) != ERR_OK) {
        return false;
    }
    return ok;
}

UplinkStats readUplinkStats() {
    UplinkStats s;
    s.accepted = gAccepted.load(std::memory_order_relaxed);
    s.badLength = gBadLength.load(std::memory_order_relaxed);
    s.badMagic = gBadMagic.load(std::memory_order_relaxed);
    s.badChecksum = gBadChecksum.load(std::memory_order_relaxed);
    s.badPadding = gBadPadding.load(std::memory_order_relaxed);
    s.duplicate = gDuplicate.load(std::memory_order_relaxed);
    s.stale = gStale.load(std::memory_order_relaxed);
    s.dropped = gDropped.load(std::memory_order_relaxed);
    s.reseeds = gReseeds.load(std::memory_order_relaxed);
    return s;
}

void resetUplinkStats() {
    gAccepted.store(0, std::memory_order_relaxed);
    gBadLength.store(0, std::memory_order_relaxed);
    gBadMagic.store(0, std::memory_order_relaxed);
    gBadChecksum.store(0, std::memory_order_relaxed);
    gBadPadding.store(0, std::memory_order_relaxed);
    gDuplicate.store(0, std::memory_order_relaxed);
    gStale.store(0, std::memory_order_relaxed);
    gDropped.store(0, std::memory_order_relaxed);
    gReseeds.store(0, std::memory_order_relaxed);
}

}  // namespace osteer
