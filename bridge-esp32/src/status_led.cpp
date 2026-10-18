#include "status_led.h"

#include <Arduino.h>
#include <Preferences.h>

#include "config.h"

namespace osteer {
namespace {

uint8_t gLedGpio = cfg::kLedGpioDefault;
bool gReady = false;

// Latched by setLedFault() and cleared only by a reset. setup() returns early on
// a fault, but loop() keeps repainting every 200 ms and the Wi-Fi event handler
// asks for blue whenever a phone leaves. Without the latch a bridge that failed
// to start looks exactly like one waiting for a phone.
volatile bool gFaultLatched = false;

void write(uint8_t r, uint8_t g, uint8_t b) {
    if (!gReady) {
        return;
    }
    if (gFaultLatched) {
        r = 16;
        g = 0;
        b = 12;
    }
    // Brightness is deliberately low. This board sits on a desk next to a screen
    // in a dark room, and a full-brightness addressable LED is genuinely painful.
    rgbLedWrite(gLedGpio, r, g, b);
}

}  // namespace

void ledBegin() {
    Preferences prefs;
    if (prefs.begin(cfg::kNvsNamespace, true)) {
        // Flash may hold anything an older build or a manual write left there.
        // Driving the wrong pin before USB.begin() could hold a USB data line.
        const uint8_t stored = prefs.getUChar("led_gpio", cfg::kLedGpioDefault);
        gLedGpio = cfg::isValidLedGpio(stored) ? stored : cfg::kLedGpioDefault;
        prefs.end();
    }

    gReady = true;
    setLedWaitingForStation();
}

uint8_t ledGpio() {
    return gLedGpio;
}

bool setLedGpio(uint8_t gpio) {
    if (!cfg::isValidLedGpio(gpio)) {
        return false;
    }

    Preferences prefs;
    if (prefs.begin(cfg::kNvsNamespace, false)) {
        prefs.putUChar("led_gpio", gpio);
        prefs.end();
    }
    gLedGpio = gpio;
    setLedWaitingForStation();
    return true;
}

void setLedForState(uint8_t state) {
    // Matches the numeric order of WdState: Idle, Live, Decaying, FailSafe,
    // Recovering.
    switch (state) {
        case 0:  // Idle, nothing has ever arrived
            write(0, 0, 8);
            break;
        case 1:  // Live
            write(0, 10, 0);
            break;
        case 2:  // Decaying, the link has gone quiet
            write(12, 8, 0);
            break;
        case 3:  // FailSafe, coasting
            write(14, 0, 0);
            break;
        case 4:  // Recovering, slewing back
            write(10, 4, 10);
            break;
        default:
            write(4, 4, 4);
            break;
    }
}

void setLedWaitingForStation() {
    write(0, 0, 10);
}

void setLedFault() {
    gFaultLatched = true;
    write(16, 0, 12);
}

}  // namespace osteer
