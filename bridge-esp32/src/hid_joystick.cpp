#include "hid_joystick.h"

#include <string.h>

namespace osteer {

// 61 bytes. Counted, not estimated: a descriptor whose declared length does not
// match its contents is accepted by the host and then produces an axis that reads
// as a button, or a device that enumerates and reports nothing at all.
//
// No Report ID item. Only one HID device is registered on this interface, so the
// reports go out unprefixed and the 12-byte struct is the whole payload. Adding a
// second HID device later means adding an ID here and to every send.
const uint8_t kJoystickReportDescriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x04,        // Usage (Joystick)
    0xA1, 0x01,        // Collection (Application)

    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)

    // Steering. Signed, and the minimum is -32767 rather than -32768: invariant
    // I10 keeps the axis symmetric so full left and full right are the same size.
    0x09, 0x30,        //     Usage (X)
    0x16, 0x01, 0x80,  //     Logical Minimum (-32767)
    0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
    0x75, 0x10,        //     Report Size (16)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x02,        //     Input (Data, Variable, Absolute)

    // Throttle, brake, clutch. Unsigned full range.
    //
    // The maximum needs the four-byte form: as a two-byte item 0xFFFF would be
    // read as signed -1, the host would decide the axis has an empty range, and
    // every pedal would sit dead at one end.
    0x09, 0x31,                    //     Usage (Y)
    0x09, 0x32,                    //     Usage (Z)
    0x09, 0x33,                    //     Usage (Rx)
    0x15, 0x00,                    //     Logical Minimum (0)
    0x27, 0xFF, 0xFF, 0x00, 0x00,  //     Logical Maximum (65535)
    0x75, 0x10,                    //     Report Size (16)
    0x95, 0x03,                    //     Report Count (3)
    0x81, 0x02,                    //     Input (Data, Variable, Absolute)

    0xC0,              //   End Collection (Physical)

    // ButtonMask bit i drives Button i+1, so bit 0 is the upshift paddle.
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (Button 1)
    0x29, 0x20,        //   Usage Maximum (Button 32)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x20,        //   Report Count (32)
    0x81, 0x02,        //   Input (Data, Variable, Absolute)

    0xC0,              // End Collection (Application)
};

static_assert(sizeof(kJoystickReportDescriptor) == kJoystickReportDescriptorSize,
              "the descriptor length and the declared size have diverged");

OpenSteerJoystick::OpenSteerJoystick() {
    static bool registered = false;
    if (!registered) {
        registered = true;
        USBHID::addDevice(this, sizeof(kJoystickReportDescriptor));
    }
}

uint16_t OpenSteerJoystick::_onGetDescriptor(uint8_t* buffer) {
    memcpy(buffer, kJoystickReportDescriptor, sizeof(kJoystickReportDescriptor));
    return sizeof(kJoystickReportDescriptor);
}

void OpenSteerJoystick::begin() {
    hid_.begin();
}

void OpenSteerJoystick::end() {
    hid_.end();
}

bool OpenSteerJoystick::ready() const {
    // Static on USBHID, called through the member for readability. It reports
    // whether the host has opened the interface, not merely whether USB is up.
    return USBHID::ready();
}

bool OpenSteerJoystick::send(const JoyReport& report, uint32_t timeoutMs) {
    if (!USBHID::ready()) {
        return false;
    }
    // Report id 0: there is no Report ID item in the descriptor, so TinyUSB sends
    // the payload with no prefix byte.
    return USBHID::SendReport(0, &report, sizeof(report), timeoutMs);
}

}  // namespace osteer
