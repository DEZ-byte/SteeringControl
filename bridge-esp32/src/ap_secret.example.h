#pragma once

// The bridge's Wi-Fi passphrase.
//
// Copy this file to ap_secret.h in the same folder and put your own passphrase
// between the quotes: 8 to 63 characters, and not one you use anywhere else.
// ap_secret.h is git-ignored, so it never reaches the repository. One way to
// make a good one:
//
//   python -c "import secrets; print(secrets.token_urlsafe(18))"
//
// The value here is left empty on purpose. A verbatim copy fails the build (the
// static_assert in wifi_ap.cpp), so no two bridges ever share a published default.
#define OSTEER_AP_PASSWORD ""
