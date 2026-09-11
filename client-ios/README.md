# OpenSteer iOS client

The phone half of OpenSteer. It reads the gyroscope, turns the twist of the device
into a steering axis, adds two thumb pedals and two paddles, and streams the result
to the Windows daemon at 120 Hz. Telemetry comes back on the same connection and is
played as haptics.

The source is written on Windows and built on a Mac. There is no Swift toolchain on
the Windows side: the swift.org Windows build needs the Visual Studio C++ build
tools, and avoiding those was a deliberate decision for this project.

## Layout

```
Package.swift                 SwiftPM: OpenSteerCore + OpenSteerCoreTests
Sources/OpenSteerCore/        the maths and the wire format, Foundation only
Tests/OpenSteerCoreTests/     XCTest, pinned to tools/golden_vectors.json
App/project.yml               XcodeGen spec; the .xcodeproj is generated, not committed
App/OpenSteer/                the app: engine, UI, settings
App/OpenSteerTests/           app-target tests
```

`OpenSteerCore` imports nothing but Foundation. No CoreMotion, no Network, no UIKit.
That is what lets the steering maths and the packet format be tested anywhere,
including on a machine with no Apple frameworks, and it keeps the one piece that
must agree byte for byte with the Windows daemon free of anything that could drift.

## Building

You need a Mac with Xcode 15 or newer, and an iPhone running iOS 17 or newer. The
simulator will run the tests but cannot give you a gyroscope or haptics.

```bash
brew install xcodegen
```

```bash
cd client-ios/App && xcodegen generate
```

No team identifier is needed to generate, and none is written into the spec.
Signing is set to automatic with the team left empty, so Xcode shows an empty
**Team** dropdown under Signing & Capabilities and you pick your own the first time
you open the project. A free Personal Team is enough to run on your own phone.

Two things to know about that choice. It is stored in `OpenSteer.xcodeproj`, which
is generated and not tracked, so running `xcodegen generate` again resets it and
you re-pick. And a Personal Team's provisioning expires after seven days, so the
app stops launching from the home screen until you build to the phone again.

If signing fails with **failed to register bundle identifier**, somebody else
already owns `com.opensteer.OpenSteer`. Change `bundleIdPrefix` in `project.yml` to
a prefix of your own and regenerate. That is the only edit needed.

Run every test. The simulator needs no team at all, so this works before you have
picked one:

```bash
xcodebuild -project client-ios/App/OpenSteer.xcodeproj -scheme OpenSteer -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```

Substitute any iOS 17 simulator from `xcrun simctl list devices available`.

The library alone, without Xcode:

```bash
cd client-ios && swift test
```

## Running it

1. Start the daemon on the PC. Note the address it prints.
2. Allow UDP port 9999 inbound through the Windows firewall, on the private profile.
3. Open the app, type the address, press **Drive**.
4. iOS asks for local network permission the first time. Refuse it and nothing will
   ever connect, with no error beyond a stuck "Waiting" state.
5. Hold the phone like a wheel and press **CENTRE**. Straight ahead is wherever the
   phone is pointing at that moment.

The rotation setting is how far you turn **the phone**, not the car's steering
lock. The default of 180 means full lock at 90 degrees each way, which is about as
far as hands go before the arms cross. Setting it to a wheel-sized number like 900
means a 90 degree turn can only ever ask for a fifth of the car's lock.

The left quarter of the screen is the brake, the right quarter is the throttle. A
pedal starts at zero wherever your thumb lands and applies as you slide down, so
there is no on-screen target to miss while the phone is moving. The top corners are
the paddles.

## Why the steering is a quaternion twist

The obvious way to read a phone's rotation is `atan2(gravity.y, gravity.x)`. It is
one line, and on a desk it looks perfect.

It fails in a chair. With the phone reclined 85 degrees, a real 10 degree turn reads
as 7.7 degrees, so the wheel is a quarter short exactly where precision matters. Lay
the phone flat and a 30 degree turn reads as zero. Worse, merely shifting position
without turning at all invents almost a degree of steering out of nothing.

What this code uses instead is the pure twist about the screen normal, pulled out of
the relative attitude quaternion by twist-swing decomposition. Tilt produces exactly
zero. Both failures above are pinned as fixtures named TV3 and TV3b, so the shortcut
cannot be quietly reintroduced.

## Design rules

**The sensor loop never touches the main thread.** CoreMotion delivers to a serial
background queue, and the whole chain from attitude to sent packet runs there in
under two microseconds. SwiftUI shares the main queue with layout and gesture
recognition, so one busy frame there would delay a steering packet behind it. The
engine's initialiser throws rather than accept a main queue, because a wheel that
quietly runs its sensor loop on the wrong thread feels almost right, and almost
right is harder to diagnose than broken.

**The screen pulls; the steering never pushes.** The wheel graphic reads the latest
finished snapshot from its own display link and sets one layer transform. Nothing at
120 Hz ever goes through an observable object. The text readouts update at 15 Hz,
because nobody can read an engine speed changing 120 times a second.

**Shaping happens exactly once, here.** Degrees of rotation, deadband and gamma are
applied on the phone. The daemon has no shaper at all, so what you send is what the
game receives.

**Losing telemetry costs haptics and nothing else.** The link degrades after half a
second of silence: the rumble mutes and the status line says so, but steering keeps
streaming. The driver keeps control of the car, which is the right way round.

## What is not done yet

- The checks that need a physical device, such as the send interval and the display
  cadence, are not automated.
- There is no discovery. The address is typed once and remembered.
- The optional sub-bass audio effect is not implemented.
