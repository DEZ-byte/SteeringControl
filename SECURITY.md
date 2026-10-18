# Security policy

## Reporting a vulnerability

Report security issues privately: open the repository's **Security** tab and choose
**Report a vulnerability**. Please do not open a public issue for anything that
could be used against someone's machine. Expect a reply within a week.

## Threat model and network scope

The 32-byte UDP uplink carries an XXH32 checksum with a public seed. It detects
corruption; it does not authenticate the sender. Anyone who can reach UDP port 9999
on the PC can move the virtual controller and receive the current car's telemetry.
Frames are fixed-size and parsed in managed code, so a sender cannot reach anything
beyond the controller.

The daemon is meant for a network you trust, such as a home LAN, an iPhone hotspot,
or the ESP32 bridge's own access point:

- Allow the port on the **Private** firewall profile only, from `LocalSubnet` only:
  `New-NetFirewallRule -DisplayName 'OpenSteer UDP 9999' -Direction Inbound -Protocol UDP -LocalPort 9999 -RemoteAddress LocalSubnet -Action Allow -Profile Private`
- On any network you do not own, start the daemon with `--allow <phone-ip>`. Only
  that IPv4 address can then drive or receive telemetry. This is a source filter,
  not authentication: a host on the same segment can still forge the address.
- Use `--bind <pc-ip>` to listen on one interface. Without `--allow`, the daemon
  warns at startup whenever it listens on anything other than loopback.

## Native binary and firmware hygiene

- `ViGEmClient.dll` is committed, and its SHA-256 is checked at build and publish
  time against [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The daemon loads it
  only from beside its own executable (`SafeDirectories`, no `PATH` or current
  directory fallback) and runs without administrator rights.
- The ESP32 bridge has no shared default Wi-Fi passphrase. Each build takes its own
  WPA2 passphrase from the git-ignored `bridge-esp32/src/ap_secret.h`, and the build
  stops until it is set.
