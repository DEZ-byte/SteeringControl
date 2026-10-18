# OpenSteer iOS client

The phone half of OpenSteer. It reads the gyroscope, turns the twist of the device
into a steering axis, adds two thumb pedals and two paddles, and streams the result
to the Windows daemon at 120 Hz. Telemetry comes back on the same connection and is
played as haptics.

**Status:** the core library and the app build and pass their tests in CI on a macOS
runner (`swift test`, and `xcodebuild test` on an iOS simulator). The app has not yet
been run on a physical iPhone.

The design is described in [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): the twist
math, the wire format, the queues, the link state machine and the haptics policy.

## Layout

```
Package.swift                 SwiftPM: OpenSteerCore + OpenSteerCoreTests
Sources/OpenSteerCore/        the math and the wire format, Foundation only
Tests/OpenSteerCoreTests/     XCTest, pinned to tools/golden_vectors.json
App/project.yml               XcodeGen spec; the .xcodeproj is generated, not committed
App/OpenSteer/                the app: engine, UI, settings
App/OpenSteerTests/           app-target tests
```

`OpenSteerCore` imports only Foundation: no CoreMotion, no Network, no UIKit. The
steering math and the packet format can be tested with `swift test` on any machine
with a Swift toolchain, before Xcode is involved.

## Requirements

- A Mac with Xcode 15 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- An iPhone running iOS 17 or newer to drive. The simulator runs the tests but has
  no gyroscope and no Taptic Engine, so it will not steer or vibrate.

## Building and testing

### 1. The core library

```bash
swift test --package-path client-ios
```

This compiles and tests `OpenSteerCore` with no Xcode project, no signing and no
device: the wire format against the golden hex, the checksum against the published
vectors, every twist vector, both mappers, the link state table and the haptics
policy. It is the fastest loop, so fix failures here first.

If the tests cannot find their fixture, check that
`Tests/OpenSteerCoreTests/Fixtures/golden_vectors.json` exists. It is a byte-for-byte
copy of `tools/golden_vectors.json`, loaded through `Bundle.module`.

### 2. Generate the Xcode project

```bash
brew install xcodegen
```

```bash
cd client-ios/App && xcodegen generate
```

`OpenSteer.xcodeproj` is generated and git-ignored. Edit `project.yml`, not the
project. Regenerating resets your signing team, so regenerate only when
`project.yml` changes.

### 3. Simulator tests

```bash
xcodebuild test -project client-ios/App/OpenSteer.xcodeproj -scheme OpenSteer -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

Use any iOS 17 or newer simulator from `xcrun simctl list devices available`. The
scheme runs the app tests (including the check that the motion engine refuses the
main queue) and the core package tests together. The simulator needs no signing team.

### 4. Signing and running on an iPhone

`project.yml` sets automatic signing and leaves the team empty, so each developer
picks their own. A free Personal Team is enough for your own phone.

1. Open `OpenSteer.xcodeproj`.
2. Select the **OpenSteer** target, then **Signing & Capabilities**.
3. Pick your team from the **Team** dropdown.

Or from the command line:

```bash
xcodebuild -project client-ios/App/OpenSteer.xcodeproj -scheme OpenSteer -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOURTEAMID build
```

If signing fails with **failed to register bundle identifier**, someone else owns
`com.opensteer.OpenSteer`. Bundle identifiers are unique across all Apple accounts.
In `project.yml`, change `bundleIdPrefix` and the two `PRODUCT_BUNDLE_IDENTIFIER`
values (app and tests) to a prefix of your own, then regenerate.

First run on the phone:

1. Connect the phone and trust the Mac.
2. Turn on **Settings > Privacy & Security > Developer Mode** and restart the phone.
   iOS 16 and later will not run a development build without it.
3. Build and run. The first launch fails with an untrusted developer alert.
4. In **Settings > General > VPN & Device Management**, select your developer
   certificate and tap **Trust**.
5. Launch again.

A Personal Team's provisioning expires after seven days. The app then stops
launching from the home screen; building to the phone again fixes it.

## Running it

1. Start the daemon on the PC. On any network you do not own, start it with
   `--allow <phone-ip>` so only the phone can drive. The phone's address is under
   **Settings > Wi-Fi**, behind the info button next to the network.

   ```powershell
   .\server-windows\OpenSteer.Server\bin\Release\net8.0-windows\win-x64\publish\OpenSteer.Server.exe --allow <phone-ip>
   ```

2. Allow UDP port 9999 inbound on the PC, on the Private profile only and from the
   local subnet only:

   ```powershell
   New-NetFirewallRule -DisplayName 'OpenSteer UDP 9999' -Direction Inbound -Protocol UDP -LocalPort 9999 -RemoteAddress LocalSubnet -Action Allow -Profile Private
   ```

3. Find the PC's address:

   ```powershell
   Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" }
   ```

4. Open the app, type the PC's address, and press **Drive**.
5. Allow local network access when iOS asks. If you refuse, nothing connects and the
   app stays in "Waiting". The setting is in **Settings > Privacy & Security > Local
   Network**.
6. Hold the phone like a wheel and press **CENTER**. Straight ahead is wherever the
   phone points at that moment.

The rotation setting is how far you turn the phone for full lock, not the car's
steering lock. The default, 180, means full lock at 90 degrees each way, about as far
as most people can turn without regripping. The options run from 120 to 360.

The left quarter of the screen is the brake and the right quarter is the throttle. A
pedal starts at zero wherever your thumb lands and applies as you slide down, so
there is no on-screen target to find while the phone is moving. The top corners are
the paddles.

## Checking performance on a device

Turn on **Show diagnostics** on the connect screen. The diagnostics line shows:

| Field | Measures | Expected |
|---|---|---|
| `Hz`, `ia` | motion delivery rate and the interval between sends | p50 within 4% of 1/R, p99 ≤ 10 ms, max ≤ 20 ms, where R is 120 Hz or the phone's maximum |
| `disp` | display link frame interval | 8.0 to 8.7 ms on a 120 Hz ProMotion screen |

Packet rate, loss and jitter as seen by the PC are in the daemon's `--stats-json 1`
output: expect R ± 2 packets per second, under 0.1% drops and an inter-arrival p99
under 12 ms. Display hitches are measured with Instruments (Animation Hitches): under
5 ms per second, and no hang over 250 ms.

A phone that delivers device motion at 100 Hz instead of 120 Hz is acceptable; the
diagnostics line shows which one you have.

## Troubleshooting

- **`disp` reads about 16.7 ms on a ProMotion phone.** The built Info.plist is missing
  `CADisableMinimumFrameDurationOnPhone`. The app needs both that key and its
  explicit frame rate range; either one alone gives 60 Hz.
- **Stuck on "Waiting".** Local network access was refused. Turn it on in
  **Settings > Privacy & Security > Local Network**.
- **The app connects but the car does not move.** Check the PC side first: the
  daemon's `STATS` line shows whether packets arrive (`acc`) or are rejected
  (`other_src` usually means `--allow` names a different address).
- **The app stopped launching from the home screen.** The Personal Team provisioning
  expired. Build to the phone again.

## Design rules

**The sensor loop never runs on the main thread.** CoreMotion delivers to a serial
background queue, and the whole chain from attitude to sent packet runs there. The
design budget is under two microseconds up to the finished packet; it has not been
measured on a phone yet. SwiftUI shares the main queue with layout and gestures, so
one slow frame there would delay a steering packet. The motion engine's initializer
throws if it is given the main queue.

**The screen reads the steering; the steering never pushes to the screen.** The wheel
graphic reads the latest snapshot from its own display link and sets one layer
transform. Nothing at 120 Hz goes through an observable object. Text readouts update
at 15 Hz.

**Shaping happens once, on the phone.** Degrees of rotation, deadband and gamma are
applied here. The daemon has no shaper, so the game receives exactly what the phone
sends.

**Losing telemetry costs haptics only.** After half a second without a downlink the
link is marked degraded: rumble mutes and the status line says so, but steering keeps
streaming.

## Not done yet

- The app has not been run on a physical iPhone, so the on-device checks above have
  not been done.
- There is no discovery. The PC's address is typed once and remembered.
- The optional sub-bass audio effect is not implemented.
