// OpenSteer ESP32-S3 bridge.
//
// A four-dollar board that turns a phone into a USB joystick with no driver, no
// installer and no software running on the PC at all. It makes its own Wi-Fi
// network, listens for the same 32-byte packets the Windows daemon does, and
// presents itself over USB as a plain HID game controller.
//
// Build and flash instructions are in README.md. Nothing here has been compiled:
// there is no ESP32 toolchain on the machine this was written on, by the same
// decision that removed the Visual Studio C++ tools from the project.

#include <Arduino.h>
#include <USB.h>

#include "src/config.h"
#include "src/hid_joystick.h"
#include "src/hid_task.h"
#include "src/status_led.h"
#include "src/uplink_udp.h"
#include "src/wifi_ap.h"

// The USB mode defines come from the board platform, not from this sketch. If
// they are missing, the build has been given `build.extra_flags` by hand and has
// wiped the whole group: `--build-property` replaces that key's value rather than
// adding to it. Pass extra defines in `compiler.cpp.extra_flags` instead.
#ifndef ARDUINO_USB_MODE
#error "platform USB defines missing: never override build.extra_flags, use compiler.cpp.extra_flags"
#endif

// Mode 1 is the hardware CDC bridge, where the USB peripheral is wired to the
// serial console and cannot be a HID device. The whole bridge depends on OTG
// mode, so this is a build failure rather than a runtime surprise.
#if ARDUINO_USB_MODE == 1
#error "USBMode must be OTG (ARDUINO_USB_MODE=0); set USBMode=default on the FQBN"
#endif

#if OSTEER_DEV_CDC
// Development build only. The release build has no serial console at all, which
// is what makes it a single-function HID device rather than a composite one.
USBCDC USBSerial;
static void serviceConsole();
#endif

static uint32_t gLastLedMs = 0;

void setup() {
    osteer::ledBegin();

    // Identity before anything is registered. The descriptors are assembled when
    // USB.begin() runs, so a VID set afterwards is simply not in them.
    USB.VID(osteer::cfg::kUsbVendorId);
#if OSTEER_DEV_CDC
    USB.PID(osteer::cfg::kUsbProductIdDev);
#else
    USB.PID(osteer::cfg::kUsbProductIdRelease);
#endif
    USB.firmwareVersion(osteer::cfg::kUsbFirmwareVersion);
    USB.productName(osteer::cfg::kProductName);
    USB.manufacturerName(osteer::cfg::kManufacturer);

    // Every interface registers itself before the stack starts. Registering after
    // USB.begin() gives a device that enumerates without the interface, which
    // looks to Windows like a broken descriptor rather than a late one.
    osteer::joystick().begin();
#if OSTEER_DEV_CDC
    USBSerial.begin();
#endif

    if (!USB.begin()) {
        osteer::setLedFault();
        return;
    }

    if (!osteer::startAccessPoint()) {
        osteer::setLedFault();
        return;
    }

    // The task and its mailbox come up before the receiver binds, so a packet can
    // never arrive to find there is nowhere to put it.
    if (!osteer::startHidTask()) {
        osteer::setLedFault();
        return;
    }

    if (!osteer::startUplinkReceiver()) {
        osteer::setLedFault();
        return;
    }

    osteer::setLedWaitingForStation();
}

void loop() {
    // Everything that matters runs on the HID task and the tcpip task. This loop
    // exists for the console and the LED, so it sleeps almost all of the time and
    // leaves core 0 to the radio.
    delay(100);

#if OSTEER_DEV_CDC
    serviceConsole();
#endif

    const uint32_t now = millis();
    if (now - gLastLedMs >= 200) {
        gLastLedMs = now;
        if (!osteer::hasStation()) {
            osteer::setLedWaitingForStation();
        } else {
            osteer::setLedForState(osteer::readHidStats().state);
        }
    }
}

#if OSTEER_DEV_CDC

// A deliberately tiny console. One line, one command, no arguments parser worth
// the name. It exists to read counters during hardware testing and to set the
// two things that cannot be guessed: which GPIO the LED is on, and the access
// point password.
static void printStats() {
    const osteer::UplinkStats u = osteer::readUplinkStats();
    const osteer::HidStats h = osteer::readHidStats();

    USBSerial.printf(
        "STATS acc=%u bad_len=%u bad_magic=%u bad_csum=%u bad_pad=%u dup=%u "
        "stale=%u drop=%u reseeds=%u tx=%u tx_fail=%u jitter_p99_us=%u "
        "failsafes=%u state=%u heap=%u sta=%u\n",
        u.accepted, u.badLength, u.badMagic, u.badChecksum, u.badPadding,
        u.duplicate, u.stale, u.dropped, u.reseeds, h.reportsSent,
        h.reportsFailed, h.jitterP99Us, h.failsafeCount, h.state,
        esp_get_free_heap_size(), osteer::hasStation() ? 1u : 0u);
}

static void serviceConsole() {
    static char line[80];
    static size_t used = 0;

    while (USBSerial.available()) {
        const int c = USBSerial.read();
        if (c < 0) {
            break;
        }

        if (c == '\r') {
            continue;
        }

        if (c != '\n') {
            if (used + 1 < sizeof(line)) {
                line[used++] = static_cast<char>(c);
            }
            continue;
        }

        line[used] = '\0';
        used = 0;

        if (strcmp(line, "stats") == 0) {
            printStats();
        } else if (strcmp(line, "reset") == 0) {
            osteer::resetUplinkStats();
            USBSerial.println("OK counters cleared");
        } else if (strncmp(line, "led ", 4) == 0) {
            osteer::setLedGpio(static_cast<uint8_t>(atoi(line + 4)));
            USBSerial.printf("OK led_gpio=%u\n", osteer::ledGpio());
        } else if (strncmp(line, "pw ", 3) == 0) {
            USBSerial.println(osteer::setApPassword(line + 3)
                                  ? "OK reboot to apply"
                                  : "ERR password must be 8 to 63 characters");
        } else if (strncmp(line, "ch ", 3) == 0) {
            USBSerial.println(osteer::setApChannel(static_cast<uint8_t>(atoi(line + 3)))
                                  ? "OK reboot to apply"
                                  : "ERR channel must be 1, 6 or 11");
        } else if (strcmp(line, "info") == 0) {
            USBSerial.printf("ssid=%s channel=%u led_gpio=%u ip=%u.%u.%u.%u port=%u\n",
                             osteer::cfg::kApSsid, osteer::apChannel(),
                             osteer::ledGpio(), osteer::cfg::kApIp[0],
                             osteer::cfg::kApIp[1], osteer::cfg::kApIp[2],
                             osteer::cfg::kApIp[3], osteer::cfg::kUdpPort);
        } else if (line[0] != '\0') {
            USBSerial.println("commands: stats reset info led <gpio> pw <password> ch <1|6|11>");
        }
    }
}

#endif  // OSTEER_DEV_CDC
