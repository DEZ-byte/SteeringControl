#pragma once

// The access point the phone joins.
//
// The bridge makes its own network rather than joining an existing one. That is
// the whole point of this pathway: no router, no DHCP lease to chase, no address
// to type, and one radio hop instead of two.

#include <stdint.h>

namespace osteer {

/// Brings up the SoftAP on 192.168.4.1 and registers the station events.
bool startAccessPoint();

/// True while a phone is associated.
bool hasStation();

/// Runtime-overridable settings, all persisted in non-volatile storage.
const char* apPassword();
bool setApPassword(const char* password);
uint8_t apChannel();
bool setApChannel(uint8_t channel);

}  // namespace osteer
