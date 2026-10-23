# OpenSteer iOS App: Use Your iPhone as a PC Steering Wheel

The phone half of OpenSteer. It reads the gyroscope, turns the twist of the device
into a steering axis, adds two thumb pedals and two paddles, and streams the result
to the Windows daemon at 100 Hz. Telemetry comes back on the same connection and is
played as haptics.

**Status:** the core library and the app build and pass their tests in CI on a macOS
runner (`swift test`, and `xcodebuild test` on an iOS simulator). CI also builds the
app for a real iPhone as `OpenSteer-unsigned.ipa`. The
[latest release](https://github.com/DEZ-byte/SteeringControl/releases/latest) has it
as a download, and you can sideload it from Windows without a Mac (see
[Installing on an iPhone Without a Mac](#installing-on-an-iphone-without-a-mac-sideloading-ipa-on-windows)).
The app has been verified end-to-end on a physical iPhone (iOS 27.0.1), driving
Assetto Corsa over Wi-Fi with the 60 Hz haptic downlink coming back
([measurements](../README.md#measured-on-track)). That copy was the unsigned `.ipa`,
sideloaded with a free Apple ID.

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

- To build from source: a Mac with Xcode 15 or newer, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- To install without building: a Windows PC and the CI-built `.ipa` (see
  [Installing on an iPhone Without a Mac](#installing-on-an-iphone-without-a-mac-sideloading-ipa-on-windows)).
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

## Installing on an iPhone Without a Mac (Sideloading `.ipa` on Windows)

On Android, an app from outside the store comes as an `.apk` file. The iPhone's
equivalent is an **`.ipa`**: a zip archive with the app bundle inside it, at
`Payload/OpenSteer.app`. iOS installs an `.ipa` only after it is signed for your
phone. A free Apple ID can sign apps for your own devices, and a Windows tool can do
the signing and the install, so you need neither a Mac nor a paid Apple Developer
account.

**Status:** CI builds the `.ipa` and checks that it contains an arm64 iPhone
executable. I sideloaded it with a free Apple ID onto an iPhone running iOS 27.0.1
and drove Assetto Corsa with it. Reports from other iPhone models and iOS versions
are welcome in [GitHub Issues](https://github.com/DEZ-byte/SteeringControl/issues).

### 1. Download the `.ipa`

1. Open the [latest release](https://github.com/DEZ-byte/SteeringControl/releases/latest).
   You do not need to sign in to GitHub.
2. Under **Assets**, download **`OpenSteer-unsigned.ipa`**. It downloads as the
   `.ipa` itself, not as a zip.

The direct link is
[`OpenSteer-unsigned.ipa`](https://github.com/DEZ-byte/SteeringControl/releases/latest/download/OpenSteer-unsigned.ipa).

The file on the release comes from a CI run on `main` that passed every job. It is
the `OpenSteer` app in the Release configuration, built for a real iPhone (`arm64`)
with code signing turned off. Files on a release do not expire. CI also builds the
same file on every run, but those run artifacts need a GitHub sign-in and GitHub
deletes them after 90 days.

### 2. What a free Apple ID allows

These limits are Apple's, not OpenSteer's:

- A free Apple ID's signature lasts **7 days**. After that the app stops opening
  until it is signed and installed again.
- At most **3** sideloaded apps can be active on a phone at once. AltStore and
  SideStore each count as one of the three.
- At most **10** App IDs can be registered in 7 days.

### 3. Option A: Sideloadly

[Sideloadly](https://sideloadly.io/) is a free Windows app that signs an `.ipa` with
your Apple ID and installs it.

1. Install iTunes and iCloud from Apple's website, not from the Microsoft Store.
   Sideloadly needs these web versions; uninstall the Store versions first. The links
   are on [sideloadly.io](https://sideloadly.io/).
2. Install Sideloadly from [sideloadly.io](https://sideloadly.io/).
3. Connect the iPhone by USB, unlock it, and tap **Trust** when it asks.
4. Drag `OpenSteer-unsigned.ipa` onto the Sideloadly window, enter your Apple ID,
   and start the sideload.
5. Do the iPhone steps in [section 5](#5-on-the-iphone).

**Wi-Fi and automatic refresh.** After the first install over USB, Sideloadly can
install and refresh over Wi-Fi while the PC and the phone are on the same network.
On Windows, first turn on **Sync with this iPhone over Wi-Fi** in iTunes, on the
phone's **Summary** page under **Options**. The Sideloadly Daemon, which runs in the
background on the PC, then re-signs the app before the 7 days run out. Automatic
refresh is on by default. It works only while the PC is on and the daemon is
running, and the phone is connected by USB or is on the same Wi-Fi with its screen
on.

### 4. Option B: AltStore Classic or SideStore

Both put a small store app on the phone, and you install the `.ipa` from inside it.

- **AltStore Classic**
  ([Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)).
  Install AltServer for Windows (Windows 10 or later, with iTunes and iCloud from
  Apple's website) and use it to put AltStore on the phone. Then tap **+** in
  AltStore's **My Apps** and pick `OpenSteer-unsigned.ipa` in the Files app.
  AltStore refreshes its apps over Wi-Fi while AltServer runs on a PC on the same
  network. AltStore Classic 2.3 needs iOS 17.4 or later.
- **SideStore** ([install guide](https://docs.sidestore.io/docs/installation/install)).
  Install it once from Windows with iloader. After that it signs and refreshes apps
  on the phone itself, through the LocalDevVPN app, without a PC. Install the `.ipa`
  with **+** in **My Apps**. SideStore changes often, so follow its current guide
  and release notes.

AltStore PAL is a different product: an official alternative app marketplace in the
EU, Japan and Brazil. It installs only notarized apps, so it cannot install this
`.ipa`.

### 5. On the iPhone

1. Turn on **Settings > Privacy & Security > Developer Mode**, then restart the
   phone. iOS 16 and later will not open an app signed with a free Apple ID without
   it. The switch may appear only after the first sideloaded install.
2. If iOS reports an untrusted developer, open **Settings > General > VPN & Device
   Management**, select your Apple ID under **Developer App**, and tap **Trust**.
3. Open OpenSteer and allow local network access when iOS asks. Then follow
   [Running it](#running-it).

## Running it

1. Start the daemon on the PC. On any network you do not own, start it with
   `--allow <phone-ip>` so only the phone can drive. The phone's address is under
   **Settings > Wi-Fi**, behind the info button next to the network.

   ```powershell
   .\server-windows\OpenSteer.Server\bin\Release\net8.0-windows\win-x64\publish\OpenSteer.Server.exe --allow <phone-ip>
   ```

   That is the path of your own `dotnet publish`. With the prebuilt
   `OpenSteer-Server-win-x64.zip` from the
   [latest release](https://github.com/DEZ-byte/SteeringControl/releases/latest), run
   `.\OpenSteer.Server.exe` from the unzipped folder instead.

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
pedal starts at zero wherever your thumb lands and applies as you slide up, so there
is no on-screen target to find while the phone is moving. Slide back down to ease off,
or lift your thumb to release at once. Start each press a little above the bottom
edge: on a Face ID iPhone, two quick swipes up from right on that edge can leave the
app. The paddles sit at the top of the middle half,
either side of the RPM bar: downshift on the left, upshift on the right. They stay
out of the pedal zones, so a thumb that ends a full press near the top of the screen
cannot hit a paddle by mistake.

## Checking performance on a device

Turn on **Show diagnostics** on the connect screen. The diagnostics line shows:

| Field | Measures | Expected |
|---|---|---|
| `Hz`, `ia` | motion delivery rate and the interval between sends | p50 within 4% of 1/R, p99 within 2 ms of 1/R, max ≤ 20 ms, where R is the rate the phone delivers (100 Hz on the iPhone tested) |
| `disp` | display link frame interval | 8.0 to 8.7 ms on a 120 Hz ProMotion screen |

Packet rate, loss and jitter as seen by the PC are in the daemon's `--stats-json 1`
output: expect R ± 2 packets per second, under 0.1% drops and an inter-arrival p99
under 12 ms. Display hitches are measured with Instruments (Animation Hitches): under
5 ms per second, and no hang over 250 ms.

On both real drives, the median rate of 100 packets per second and the loss (0.045%
and 0.072%) met these figures, although 28 of 399 and 71 of 1045 full one-second
windows fell outside R ± 2 during Wi-Fi gaps. The inter-arrival p99 did not meet its
figure. It was about 24 ms and 20 ms in a typical second, because Wi-Fi delivered the
packets in bunches; the
daemon's burst drain uses the newest packet of each bunch.

The app asks Core Motion for an update every 1/120 s
(`deviceMotionUpdateInterval = 1.0 / configuration.updateHz`, with `updateHz` set to
120). That is a request, not a promise: when
it is faster than the hardware allows, iOS delivers at the hardware's maximum
instead. On the iPhone tested that was 100 Hz, one sample every 10 ms, so the phone
sends 100 packets a second. The diagnostics line shows the rate your phone delivers.

## Troubleshooting

- **`disp` reads about 16.7 ms on a ProMotion phone.** The built Info.plist is missing
  `CADisableMinimumFrameDurationOnPhone`. The app needs both that key and its
  explicit frame rate range; either one alone gives 60 Hz.
- **Stuck on "Waiting".** Local network access was refused. Turn it on in
  **Settings > Privacy & Security > Local Network**.
- **The app connects but the car does not move.** Check the PC side first: the
  daemon's `STATS` line shows whether packets arrive (`acc`) or are rejected
  (`other_src` usually means `--allow` names a different address).
- **The app stopped launching from the home screen.** The free Apple ID's 7-day
  signature expired. Build to the phone again, or re-sign it with your sideloading
  tool.

## Design rules

**The sensor loop never runs on the main thread.** CoreMotion delivers to a serial
background queue, and the whole chain from attitude to sent packet runs there. The
design budget is under two microseconds up to the finished packet; it has not been
measured on a phone yet. SwiftUI shares the main queue with layout and gestures, so
one slow frame there would delay a steering packet. The motion engine's initializer
throws if it is given the main queue.

**The screen reads the steering; the steering never pushes to the screen.** The wheel
graphic reads the latest snapshot from its own display link and sets one layer
transform. Nothing at sensor or display rate goes through an observable object. Text
readouts update at 15 Hz.

**Shaping happens once, on the phone.** Degrees of rotation, deadband and gamma are
applied here. The daemon has no shaper, so the game receives exactly what the phone
sends.

**Losing telemetry costs haptics only.** Once telemetry has arrived, half a second
without a downlink marks the link degraded: the rumble and the ABS, TC, shift and
lockup effects stop and the status line says so, but steering keeps streaming. A
session that never receives a downlink, such as the ESP32 bridge, stays streaming,
and its status line keeps reading "Streaming to".

## Not done yet

- Only the PC side of the two real drives was logged. The on-phone checks above,
  the diagnostics line and the Instruments hitch check, have not been recorded yet.
- There is no discovery. The PC's address is typed once and remembered.
- The optional sub-bass audio effect is not implemented.
