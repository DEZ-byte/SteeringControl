#pragma once

// The one-deep mailbox and the task that drains it.
//
// Everything between the radio and the USB cable passes through this: the lwIP
// callback overwrites a single slot, and the HID task reads it. There is no queue
// and no backlog: if two packets arrive while the task is busy, the older one is
// out of date, and delivering it would put the wheel where the driver's hands
// were rather than where they are.

#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "hid_joystick.h"
#include "watchdog.h"
#include "wire_protocol.h"

namespace osteer {

enum class MsgKind : uint8_t {
    Packet = 0,
    /// The access point told us the station left. Better evidence than silence,
    /// and it arrives sooner.
    LinkDown,
};

struct MailMsg {
    MsgKind kind;
    UplinkPacket packet;
};

/// The one joystick instance.
///
/// A function-local static rather than a global, so it is constructed the first
/// time it is asked for. Its constructor registers a USB descriptor, and a global
/// would run that during static initialization, before `USB.VID()` has been
/// called and in an order the language does not pin down.
OpenSteerJoystick& joystick();

/// Created before the receiver binds, so a packet can never arrive before there
/// is somewhere to put it.
bool startHidTask();

/// Posts to the one-deep mailbox, replacing whatever was there.
///
/// Safe from the tcpip task and from a Wi-Fi event handler. `xQueueOverwrite`
/// never blocks, which is what keeps the lwIP callback free of any wait.
void postMail(const MailMsg& msg);

/// Snapshot of the counters, for the serial console.
struct HidStats {
    uint32_t reportsSent;
    uint32_t reportsFailed;
    uint32_t jitterP99Us;
    uint32_t failsafeCount;
    uint8_t state;
};

HidStats readHidStats();

}  // namespace osteer
