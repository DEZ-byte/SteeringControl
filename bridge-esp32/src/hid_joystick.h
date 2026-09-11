#pragma once

// The USB side: a plain HID joystick with 16-bit axes.
//
// No driver, no installer, no signed kernel component. Windows, Linux, macOS and
// a PlayStation all bind a generic HID joystick out of the box, which is the
// entire reason this bridge exists.

#include <stdint.h>

#include "USBHID.h"

namespace osteer {

#pragma pack(push, 1)
/// Exactly what goes out on the wire to the host, 12 bytes.
///
/// Axis ranges are deliberately not the same: X is signed because a steering
/// wheel has a centre, and the pedals are unsigned because they have a rest
/// position at one end. Squeezing pedals into a signed axis is how you end up
/// with a throttle that idles at half.
struct JoyReport {
    int16_t x;         // steering, -32767..32767
    uint16_t y;        // throttle, 0..65535
    uint16_t z;        // brake, 0..65535
    uint16_t rx;       // clutch, 0..65535
    uint32_t buttons;  // bit i drives Button i+1
};
#pragma pack(pop)

static_assert(sizeof(JoyReport) == 12, "HID report must be exactly 12 bytes");

class OpenSteerJoystick : public USBHIDDevice {
public:
    OpenSteerJoystick();

    void begin();
    void end();

    /// Returns false when the host is not ready or the send timed out.
    ///
    /// A report that cannot leave in a couple of milliseconds is already stale and
    /// the next one is 8 ms behind it, so a failure here is dropped rather than
    /// queued. Queuing stale steering is how input latency turns into input lag.
    bool send(const JoyReport& report, uint32_t timeoutMs);

    bool ready() const;

    // USBHIDDevice
    uint16_t _onGetDescriptor(uint8_t* buffer) override;

private:
    USBHID hid_;
};

/// The report descriptor, exposed so a test can assert its length and shape.
extern const uint8_t kJoystickReportDescriptor[];
constexpr uint16_t kJoystickReportDescriptorSize = 61;

}  // namespace osteer
