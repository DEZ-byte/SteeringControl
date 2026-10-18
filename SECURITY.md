# Security

## Reporting a problem

Please report security issues privately through GitHub: open the repository's
**Security** tab and choose **Report a vulnerability**. Do not open a public issue
for anything that could be used against someone's machine.

This is a personal project maintained in spare time. Expect an acknowledgement
within a week.

## Security model

SteeringControl (OpenSteer) is a game controller for a network you trust: your own
home Wi-Fi, an iPhone hotspot, or the ESP32 bridge's own access point. It is not
designed to be exposed to networks you do not control. Here is what that means in
practice.

### The uplink is checksummed, not authenticated

Every 32-byte uplink frame carries an XXH32 checksum with a public seed. That
catches corruption. It does not prove who sent the frame: anyone who can reach UDP
port 9999 on the PC can build a frame that passes every check.

What such a sender can do is bounded. It can move the virtual Xbox 360 pad's
steering, pedals and four buttons (RB, LB, B, A), and it receives the 16-byte
force-feedback telemetry for the current car. It cannot run code, read or write
files, or reach anything beyond the controller. The daemon parses fixed-size frames
in managed code and drops everything else.

### Who may drive

- **Default.** The daemon listens on every interface, and the first valid sender
  takes the wheel. A second sender is refused while the first one is live. After
  250 ms of silence the wheel coasts to neutral and the next valid sender may take
  over. The daemon prints a warning at start-up in this mode whenever it listens
  on anything other than loopback.
- **`--allow <phone-ip>`.** Only that IPv4 address may drive. Everything else is
  counted as `other_src` and dropped, so it can never hold the wheel or become the
  telemetry target. Use this on any network you do not own. The address must be
  four plain decimal numbers; shorthand such as `10.1`, hex, leading zeros,
  multicast and broadcast are refused at start-up, so a typo cannot silently lock
  the phone out.
- **`--bind <ip>`.** Listen on one interface only.

`--allow` is a source filter, not authentication: a host on the same network
segment can still forge the phone's address. Closing that gap needs a keyed MAC in
the protocol, which is not implemented.

### Firewall

Allow the port on the **Private** profile only, from the local subnet only:

```powershell
New-NetFirewallRule -DisplayName 'OpenSteer UDP 9999' -Direction Inbound -Protocol UDP -LocalPort 9999 -RemoteAddress LocalSubnet -Action Allow -Profile Private
```

Never add the Public profile. On a cafe, hotel or campus network, either do not run
the daemon or start it with `--allow`.

### The downlink

Force-feedback telemetry goes only to the address that holds the wheel, at 60 Hz,
16 bytes a frame. With `--allow`, only the allowed phone can hold the wheel, so
spoofed traffic cannot point the downlink at another machine.

### The ESP32 bridge

The bridge runs its own WPA2 access point with room for one station. There is no
shared default passphrase: each build takes its own from `bridge-esp32/src/ap_secret.h`,
which is git-ignored, and the build stops until it is set. The release firmware has
no serial console. Its USB interface is a joystick only, with no keyboard, so the
bridge cannot type on the PC.

### The Windows daemon

- It runs without administrator rights.
- It loads `ViGEmClient.dll` only from beside its own executable, and never
  searches the current directory or `PATH`. The build checks the DLL's SHA-256
  against the value in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- It changes only its own process settings (timer resolution, priority, power
  throttling), not system-wide ones.
- Release builds map source paths to `/_/`, so binaries do not contain the build
  machine's user name.

### Test tools

The Python tools under `tools/` are for a developer's own machine. They send to
`127.0.0.1` unless told otherwise. `feed_joycpl.py` and the probes run for a
bounded time; `drive_keys.py` runs until Esc unless given `--duration`.
`feed_joycpl.py` and `drive_keys.py` release every control on exit, Ctrl+C
included. `verify_controller.py` ends each run centred with the pedals released and
never presses a button; if it is interrupted mid-run, the daemon's 250 ms watchdog
releases the controls. `feed_joycpl.py` presses buttons only when asked
(`--buttons-hz`, or `--hold btn=...`), and only after a 5-second delay.
