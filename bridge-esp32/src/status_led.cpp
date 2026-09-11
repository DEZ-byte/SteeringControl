#include "status_led.h"

#include <Arduino.h>
#include <Preferences.h>

#include "config.h"

namespace osteer {
namespace {

uint8_t gLedGpio = cfg::kLedGpioDefault;
bool gReady = false;

void write(uint8_t r, uint8_t g, uint8_t b) {
    if (!gReady) {
        return;
    }
    // Brightness is deliberately low. This board sits on a desk next to a screen
    // in a dark room, and a full-brightness addressable LED is genuinely painful.
    rgbLedWrite(gLedGpio, r, g, b);
}

}  // namespace

void ledBegin() {
    Preferences prefs;
    if (prefs.begin(cfg::kNvsNamespace, true)) {
        gLedGpio = prefs.getUChar("led_gpio", cfg::kLedGpioDefault);
        prefs.end();
    }

    gReady = true;
    setLedWaitingForStation();
}

uint8_t ledGpio() {
    return gLedGpio;
}

void setLedGpio(uint8_t gpio) {
    Preferences prefs;
    if (prefs.begin(cfg::kNvsNamespace, false)) {
        prefs.putUChar("led_gpio", gpio);
        prefs.end();
    }
    gLedGpio = gpio;
    setLedWaitingForStation();
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
    write(16, 0, 12);
}

}  // namespace osteer
