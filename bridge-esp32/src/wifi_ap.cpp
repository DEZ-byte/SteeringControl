#include "wifi_ap.h"

#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <string.h>

#include "esp_wifi.h"

#include "config.h"
#include "hid_task.h"
#include "status_led.h"

namespace osteer {
namespace {

char gPassword[64] = {0};
uint8_t gChannel = cfg::kApChannelDefault;
volatile bool gHasStation = false;

void onWiFiEvent(WiFiEvent_t event) {
    switch (event) {
        case ARDUINO_EVENT_WIFI_AP_STACONNECTED:
            gHasStation = true;
            break;

        case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED: {
            gHasStation = false;
            // Better evidence than silence, and it arrives sooner. Waiting out the
            // 250 ms timeout after the radio has already said the phone left would
            // leave the last steering angle applied for a quarter of a second.
            //
            // Posted to the same one-deep mailbox as a packet rather than sent as
            // a task notification: one path in means one place where the ordering
            // between a link-down and a late packet is decided.
            MailMsg msg;
            msg.kind = MsgKind::LinkDown;
            postMail(msg);
            setLedWaitingForStation();
            break;
        }

        default:
            break;
    }
}

}  // namespace

bool startAccessPoint() {
    Preferences prefs;
    if (prefs.begin(cfg::kNvsNamespace, true)) {
        String stored = prefs.getString("ap_pw", cfg::kApPasswordDefault);
        stored.toCharArray(gPassword, sizeof(gPassword));
        gChannel = prefs.getUChar("ap_ch", cfg::kApChannelDefault);
        prefs.end();
    } else {
        strncpy(gPassword, cfg::kApPasswordDefault, sizeof(gPassword) - 1);
    }

    WiFi.onEvent(onWiFiEvent);
    WiFi.mode(WIFI_AP);

    IPAddress ip(cfg::kApIp[0], cfg::kApIp[1], cfg::kApIp[2], cfg::kApIp[3]);
    IPAddress mask(cfg::kApNetmask[0], cfg::kApNetmask[1],
                   cfg::kApNetmask[2], cfg::kApNetmask[3]);
    if (!WiFi.softAPConfig(ip, ip, mask)) {
        return false;
    }

    // One station only. The bridge serves exactly one phone, and refusing a
    // second is simpler and far safer than arbitrating between two sources of
    // steering input.
    if (!WiFi.softAP(cfg::kApSsid, gPassword, gChannel, cfg::kApHiddenDefault,
                     cfg::kApMaxConnections)) {
        return false;
    }

    // Power saving parks the radio between beacons, which on a 120 Hz stream
    // shows up as tens of milliseconds of steering arriving in a clump. This is
    // the single most important line in the file.
    WiFi.setSleep(false);

    // HT20. The wider channel buys throughput this link will never use, and costs
    // more airtime lost to interference from every neighbouring network.
    esp_wifi_set_bandwidth(WIFI_IF_AP, WIFI_BW_HT20);

    return true;
}

bool hasStation() {
    return gHasStation;
}

const char* apPassword() {
    return gPassword;
}

bool setApPassword(const char* password) {
    // WPA2 will not accept anything shorter. Rejecting it here is better than
    // letting the access point silently fall back to open.
    if (password == nullptr || strlen(password) < 8 || strlen(password) > 63) {
        return false;
    }

    Preferences prefs;
    if (!prefs.begin(cfg::kNvsNamespace, false)) {
        return false;
    }
    prefs.putString("ap_pw", password);
    prefs.end();

    strncpy(gPassword, password, sizeof(gPassword) - 1);
    gPassword[sizeof(gPassword) - 1] = '\0';
    return true;
}

uint8_t apChannel() {
    return gChannel;
}

bool setApChannel(uint8_t channel) {
    // 1, 6 and 11 are the only three 2.4 GHz channels that do not overlap each
    // other. Anything else guarantees interference with a neighbour.
    if (channel != 1 && channel != 6 && channel != 11) {
        return false;
    }

    Preferences prefs;
    if (!prefs.begin(cfg::kNvsNamespace, false)) {
        return false;
    }
    prefs.putUChar("ap_ch", channel);
    prefs.end();

    gChannel = channel;
    return true;
}

}  // namespace osteer
