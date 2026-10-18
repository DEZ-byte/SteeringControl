#pragma once

// Every tunable in one place. The timings are not free choices: they mirror
// OpenSteer.Core/Watchdog.cs exactly, because a bridge that coasts on a different
// schedule from the Windows daemon would feel like a different wheel.

#include <stdint.h>

namespace osteer {
namespace cfg {

// ---------------------------------------------------------------- identity

// 0x303A is Espressif's vendor id. Espressif allocates product ids under it on
// request (https://github.com/espressif/usb-pids). 0x8100 and 0x8101 are
// PLACEHOLDERS that have NOT been allocated to this project: fine on your own
// desk, but replace them with an allocated pair, and link the allocation here,
// before distributing a build.
//
// The two product ids keep the development build (composite: HID plus a serial
// console) and the release build (HID alone) as distinct devices, so Windows does
// not reuse a cached driver binding from one for the other.
constexpr uint16_t kUsbVendorId = 0x303A;
constexpr uint16_t kUsbProductIdDev = 0x8100;
constexpr uint16_t kUsbProductIdRelease = 0x8101;
constexpr uint16_t kUsbFirmwareVersion = 0x0100;

constexpr const char* kProductName = "OpenSteer Wheel";
constexpr const char* kManufacturer = "OpenSteer";

// ------------------------------------------------------------------- Wi-Fi

constexpr const char* kApSsid = "OpenSteer-AP";

// There is deliberately no password in this file. A default printed in a public
// repository is one everyone in radio range already knows, and the bridge has a
// single station slot for them to take. Each build supplies its own in
// src/ap_secret.h, which is git-ignored (copy src/ap_secret.example.h), and
// wifi_ap.cpp, the only consumer, refuses to compile without it. Kept out of this
// header so the chip-free host test, which includes config.h, still builds.
// The development console can still replace it in non-volatile storage.

// Channel 6 is the middle of the three non-overlapping 2.4 GHz channels. 1 and 11
// are the alternatives, and the console can select them.
constexpr uint8_t kApChannelDefault = 6;

// WPA2-PSK limits. Shorter is refused by the radio, which would leave the access
// point down or, on some stacks, open.
constexpr unsigned kApPasswordMin = 8;
constexpr unsigned kApPasswordMax = 63;

constexpr bool isValidApChannel(uint8_t channel) {
    return channel == 1 || channel == 6 || channel == 11;
}

// One station. The bridge serves exactly one phone, and refusing a second is
// simpler and safer than arbitrating between two sources of steering.
constexpr uint8_t kApMaxConnections = 1;

constexpr bool kApHiddenDefault = false;

// 192.168.4.1 is what esp-idf's SoftAP uses by default. It is kept because the
// phone setup in README.md and tools/feed_joycpl.py both use that address.
constexpr uint8_t kApIp[4] = {192, 168, 4, 1};
constexpr uint8_t kApNetmask[4] = {255, 255, 255, 0};

constexpr uint16_t kUdpPort = 9999;

// ---------------------------------------------------------------- watchdog

// Milliseconds. Identical to OpenSteer.Core/Watchdog.cs and to the reference
// curves in tools/golden_vectors.json, which both this and the daemon are
// checked against.
constexpr double kSoftMs = 100.0;
constexpr double kHardMs = 250.0;
constexpr double kTauMs = 30.0;
constexpr double kSteerSlewMs = 300.0;
constexpr double kPedalSlewMs = 100.0;

// Below this the decay snaps to zero. It is under one least-significant bit of an
// 8-bit trigger, so holding the value would be invisible anyway.
constexpr int kDecayFloor = 257;

// A packet returning this close to the angle we were holding snaps straight back
// to live instead of slewing. A short radio hiccup should not cost 300 ms.
constexpr int kSnapThreshold = 4096;

// ------------------------------------------------------------------- tasks

// Core 1. Core 0 runs the Wi-Fi and lwIP stacks, and sharing a core with them is
// what puts multi-millisecond gaps into a 120 Hz report stream.
constexpr int kHidTaskCore = 1;
constexpr uint32_t kHidTaskStackBytes = 4096;

// How long a HID send may block before it is abandoned. A frame that cannot go
// out in 2 ms is already stale; the next one is 8 ms away.
constexpr uint32_t kHidSendTimeoutMs = 2;

// Tick budget while degraded. Short enough that the decay curve is smooth at a
// glance, long enough that the task is asleep almost all of the time.
constexpr uint32_t kDegradedTickMs = 10;

// ------------------------------------------------------------------- other

// DevKitC-1 revision 1.0 wires the addressable LED to GPIO 48, revision 1.1 to
// GPIO 38. Which one you have is not readable at runtime, so the console can
// override it and the value persists.
constexpr uint8_t kLedGpioDefault = 48;

// The only two LED pins this firmware will drive. Anything else may be a
// strapping pin, a flash or PSRAM line, or GPIO 19/20, the USB D-/D+ pair the
// joystick itself depends on.
constexpr bool isValidLedGpio(uint8_t gpio) {
    return gpio == 38 || gpio == 48;
}

// Non-volatile storage namespace for the handful of overridable settings.
constexpr const char* kNvsNamespace = "osteer";

constexpr uint32_t kConsoleBaud = 115200;

}  // namespace cfg
}  // namespace osteer
