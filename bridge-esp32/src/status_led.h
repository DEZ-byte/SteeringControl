#pragma once

// The on-board addressable LED, used as the only display this device has.
//
// There is no screen and, in the release build, no serial console either. The
// colour is how a driver finds out whether the bridge is waiting for a phone,
// streaming, coasting, or has given up.

#include <stdint.h>

namespace osteer {

/// Reads the GPIO override out of non-volatile storage and lights the LED.
///
/// DevKitC-1 revision 1.0 wires the LED to GPIO 48 and revision 1.1 to GPIO 38.
/// The revision is not readable at runtime, so a wrong guess leaves the board
/// apparently dead. The console can set it and the value persists.
void ledBegin();

/// Colour by watchdog state, using the numeric value of `WdState` so this file
/// does not have to include the watchdog.
void setLedForState(uint8_t state);

/// Distinct from every driving state: the access point is up but nothing has ever
/// connected to it.
void setLedWaitingForStation();

void setLedFault();

uint8_t ledGpio();
void setLedGpio(uint8_t gpio);

}  // namespace osteer
