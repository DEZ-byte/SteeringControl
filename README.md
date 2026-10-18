# SteeringControl (OpenSteer)

Turn an iPhone into a low-latency virtual steering wheel for sim racing on Windows.

The phone streams gyroscope steering and touch-pedal input over UDP. A Windows
daemon turns that into a virtual controller that Assetto Corsa, BeamNG.drive and
Forza Horizon see as real hardware. The daemon reads the game's telemetry back out
of shared memory and returns it to the phone, which renders it as haptics.

Target end-to-end latency is under 3 ms.

## Status

The PC backend is complete. The protocol, the steering math, the safety watchdog,
the Windows daemon, the Assetto Corsa telemetry reader and the 60 Hz force-feedback
downlink are all implemented and verified. The wheel is confirmed to reach Windows
as a real controller.

The iOS client is written and waiting for a Mac. Its steering maths, wire format and
haptics policy are pinned to the same golden fixture the C# suite uses, so both ends
agree with an outside reference rather than with each other. Nothing in it has been
compiled yet: that needs a Mac with Xcode.

| Component | State |
|---|---|
| `OpenSteer.Core` — wire format, checksum, validator, watchdog, axis math, lease and `--allow` decisions | implemented, 79 xunit tests passing |
| `tools/` — protocol reference, twist math, golden vectors, timing helpers | implemented, 41 unittest tests passing |
| `OpenSteer.Server` — hot loop, Win32 interop, output backends | implemented and tested on Windows |
| Telemetry reader and force-feedback downlink | implemented and tested against a mock physics page |
| `third_party/vigem/ViGEmClient.dll` — native ViGEm client | committed on purpose, hash-pinned by the build |
| `client-ios` — SwiftUI client | written, not yet built on a Mac |
| `bridge-esp32` — optional driverless USB-HID bridge | source complete: written, not yet compiled or flashed |

## Layout

```
server-windows/
  OpenSteer.Core/     portable logic: no sockets, no Win32, no Console
  OpenSteer.Server/   the daemon: hot loop, P/Invoke, output backends
  OpenSteer.Tests/    xunit, references Core only
tools/                Python test harness and the cross-language fixture
client-ios/
  Sources/OpenSteerCore/   twist math, wire codecs, haptics policy: Foundation only
  Tests/                   XCTest, pinned to the same golden fixture as C#
  App/                     XcodeGen spec and the SwiftUI app
bridge-esp32/         ESP32-S3 Wi-Fi to USB-HID bridge (optional; not yet compiled)
third_party/vigem/    ViGEmClient.dll, committed and hash-pinned
```

`OpenSteer.Tests` deliberately references `OpenSteer.Core` and never the executable.
That keeps the test project free of the executable's entry point and lets the daemon
publish as a self-contained single file without upsetting the project reference.

## Design rules

Four rules the code is built to, each with a test that proves it:

1. **Steering is a quaternion twist, not a projection.** The angle is the pure twist
   about the screen normal, extracted by twist-swing decomposition. The obvious
   approach, `atan2(gravity.y, gravity.x)`, collapses when the phone is tilted: at an
   85 degree recline it reads a real 10 degree turn as 7.7 degrees, and with the phone
   flat it reads a 30 degree turn as exactly zero. Both failures are pinned as
   regression tests.
2. **The receive loop blocks, never spins.** A blocking poll parks the thread in the
   kernel at 0% CPU. An inner non-blocking drain then empties a queued Wi-Fi burst and
   keeps only the freshest frame, so the wheel jumps to the current angle instead of
   replaying stale ones.
3. **No heap allocation on the hot path.** Buffers and socket addresses are allocated
   once at startup; frames are read straight out of the receive buffer.
4. **Losing the link coasts, it does not brake.** After 100 ms of silence the pedals
   decay; after 250 ms steering centres and every pedal goes to zero. Injecting a full
   brake here would destabilise the tyre model and can spin a car mid-corner.

## Building

Needs the .NET 8 SDK and Python 3.13+. No C++ toolchain, no CMake.

```bash
dotnet test server-windows/OpenSteer.Tests/OpenSteer.Tests.csproj
```

```bash
python -m unittest discover -s tools -p "test_*.py"
```

## Security model

The UDP uplink carries an XXH32 checksum, not authentication. Anyone who can reach
UDP 9999 on the PC can drive the wheel, unless the daemon is started with
`--allow <phone-ip>`: then only that IPv4 source may drive, and everything else is
counted as `other_src` and dropped. Use `--allow` on any network you do not own. It
is a source filter, not authentication; a host on the same segment can still forge
the phone's address. Open the firewall on the Private profile only, from the local
subnet only, and never on Public:

```powershell
New-NetFirewallRule -DisplayName 'OpenSteer UDP 9999' -Direction Inbound -Protocol UDP -LocalPort 9999 -RemoteAddress LocalSubnet -Action Allow -Profile Private
```

The force-feedback downlink goes only to the address that holds the lease. The ESP32
bridge has no shared default passphrase: each build sets its own in the git-ignored
`bridge-esp32/src/ap_secret.h`. [SECURITY.md](SECURITY.md) has the full model and
explains how to report a problem privately.

## The golden vectors

`tools/golden_vectors.json` is the single conformance fixture. It is generated by
running `tools/golden_vectors.py`, never edited by hand, and it is consumed by the C#
tests today and by the Swift and C++ tests later. Its checksum implementation is
checked against the published XXH32 reference vectors before it emits anything, so
every downstream number is anchored to a known-good source rather than to itself.

```bash
python tools/golden_vectors.py
```

## Third-party pieces

`third_party/vigem/ViGEmClient.dll` is committed on purpose, so the daemon builds
with no download. It is the x64 native client, FileVersion 1.21.233.0, 141,312 bytes,
taken unmodified from the `costura64.vigemclient.dll` resource of the official
`Nefarius.ViGEm.Client` 1.21.256 NuGet package, and it is MIT-licensed. Its licence
text and SHA-256 are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The Server build refuses a DLL whose hash differs (MSBuild target
`VerifyViGEmClientHash`). The publish keeps the DLL as a loose file beside the exe,
and the daemon loads it only from there: if it is missing, loading fails rather than
falling back to `PATH` or the current directory. The matching ViGEmBus driver is
installed separately.
