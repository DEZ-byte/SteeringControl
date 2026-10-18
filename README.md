# SteeringControl (OpenSteer)

[![CI](https://github.com/DEZ-byte/SteeringControl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DEZ-byte/SteeringControl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Turn an iPhone into a low-latency 120 Hz virtual steering wheel for PC sim racing, with haptic feedback driven by Assetto Corsa telemetry.

---

## Why I Built This

This started as a fun project after I got frustrated driving on a keyboard and mouse in Assetto Corsa—personally, it felt awful. *(Side note: if you can't run this project and only have a mouse, what worked best for me was Assetto Corsa's mouse steering with medium-to-low in-game steering sensitivity and a high mouse DPI, which gives a proper lock-to-lock wheel rotation feel.)*

When I looked for ways to use my iPhone as a steering wheel instead, I couldn't easily find a good solution. Most of the decent free tools only supported Android, and the iPhone apps I found were either locked behind paywalls or packed with ads. Even worse, the phone-wheel apps I tried had two fundamental technical problems:
1. **Tilt-drift:** They behaved like a naive gravity projection (`atan2(gravity.y, gravity.x)`). That is only right while the phone turns in one plane: the moment the phone tilts sideways as you turn, the steering angle reads short, and shifting in your seat steers the car on its own.
2. **Wi-Fi burst lag:** A receiver that processes queued packets one by one replays old motion frames after every Wi-Fi micro-stutter, instead of jumping to where your hands actually are.

So I decided to build my own from scratch to fix all of that.

---

## How It Works

OpenSteer splits the pipeline into a **120 Hz UDP control uplink** and a **60 Hz force-feedback telemetry downlink**, with an optional **ESP32-S3 hardware bridge** when you want a driverless plug-and-play USB HID joystick:

```text
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                        iPhone Client (client-ios)                       │
  │  • CMMotionManager @ 120 Hz (.xArbitraryZVertical)                      │
  │  • Quaternion twist-swing decomposition around screen normal (Z)        │
  │  • Floating-anchor thumb pedals + tap shift paddles                     │
  │  • CoreHaptics driven by the 60 Hz downlink (RPM, slip, ABS, TC)        │
  └───────────────────┬─────────────────────────────────────▲───────────────┘
                      │ 32-byte UDP Uplink (120 Hz)         │ 16-byte UDP Downlink (60 Hz)
                      │ Magic 0x4F535452 + XXH32            │ Magic 0x46464231, no checksum
                      ▼                                     │
  ┌─────────────────────────────────────────────────────────┴───────────────┐
  │                  Windows Host Daemon (OpenSteer.Server)                 │
  │  • T1 Hot Loop: blocking socket poll + 64-packet non-blocking drain     │
  │  • Zero heap allocations on hot path (Span<byte>, pre-sized buffers)    │
  │  • Watchdog: 100 ms pedal decay -> 250 ms coasting fail-safe            │
  │  • T2 Telemetry: lock-free seqlock reader on Assetto Corsa shared mem   │
  └───────────────────┬─────────────────────────────────────▲───────────────┘
                      │ P/Invoke (ViGEmClient.dll)          │ Local\acpmf_physics
                      ▼                                     │
  ┌─────────────────────────────────────────────────────────┴───────────────┐
  │               Windows Kernel (ViGEmBus) & Sim Racing Title              │
  │  • Appears as an Xbox 360 controller (driven in Assetto Corsa)          │
  └─────────────────────────────────────────────────────────────────────────┘

  Optional Driverless Path (bridge-esp32, no downlink or haptics):
  [iPhone 120 Hz UDP] ──► [ESP32-S3 Wi-Fi SoftAP (192.168.4.1:9999)] ──► [PC USB-HID Joystick]
```

Target end-to-end LAN latency is **under 3 ms**. That is a design budget, not yet measured with a phone; the measured loopback round trip on Windows is **173 µs** median and **517 µs** p99. Full architecture details, quaternion derivations, and benchmark tables are in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Status

Every component builds and passes its automated test suite in CI across Windows, macOS (iOS Simulator), and Ubuntu (ESP32-S3 PlatformIO + C++ host tests).

| Component | Status |
|---|---|
| **`OpenSteer.Core`** — wire codecs, XXH32, validator, watchdog, axis math, lease & `--allow` logic | Working (`79` xUnit tests passing) |
| **`tools/`** — Python reference codecs, twist math, golden vector generator, mock phone, probes | Working (`41` unittest tests passing) |
| **`OpenSteer.Server`** — UDP hot loop, Win32 high-res timers, ViGEm output | Verified on Windows with Assetto Corsa and loopback harness |
| **Telemetry & 60 Hz FFB Downlink** — lock-free shared-memory reader (`AcSharedMemoryReader`) | Verified against a mock physics page; Assetto Corsa's live physics page confirmed with `tools/ac_shm_peek.py`; not yet received by a phone |
| **`client-ios`** — SwiftUI app & `OpenSteerCore` Swift package | Builds and passes XCTest suite in CI (macOS / iOS Simulator); not yet run on a physical iPhone |
| **`bridge-esp32`** — optional ESP32-S3 Wi-Fi SoftAP to USB-HID bridge | Builds in CI (`dev` & `release` environments) and passes C++ host tests; not yet flashed to a board |
| **`third_party/vigem/ViGEmClient.dll`** — native x64 ViGEm client | Committed and SHA-256 verified at build time (`VerifyViGEmClientHash`) |

---

## Core Design Rules

The codebase enforces four core rules. Rules 1 and 4 are pinned by regression tests in several languages; rules 2 and 3 were verified by measurement on the running daemon (idle CPU, burst coalescing, and its `gc0` counter):

1. **Steering is a quaternion twist, not a gravity projection.**
   Steering angle is the pure rotation around the phone's screen normal (`Z` axis), extracted via quaternion twist-swing decomposition. A standard `atan2(gravity.y, gravity.x)` projection is only right while the phone turns in one plane: at an 85° recline, a 10° turn made together with a 20° sideways swing reads as 7.7°, a 10° swing with no turn at all reads as 0.87° of steering, and with the phone lying flat a 30° turn reads as 0°. Twist-swing decomposition is unaffected by the swing.
2. **The receive loop blocks when idle and drains bursts when active.**
   A blocking socket poll parks the receive thread in the kernel at 0% CPU while waiting for traffic. Once woken, a non-blocking inner loop drains up to 64 queued UDP datagrams and applies only the newest valid frame—so a Wi-Fi burst moves the wheel straight to your current hand position instead of replaying stale angles.
3. **Zero heap allocations on the hot path.**
   Socket buffers, endpoint structures, and log ring-buffer slots are pre-allocated once at startup. Incoming packets are validated and decoded directly from `Span<byte>`; Gen-0 garbage collections measured 0 in the mock-phone runs and across a 150-second, 18,001-frame soak with the real ViGEm driver.
4. **Losing the link makes the car coast, not brake.**
   After 100 ms without packets, throttle and brake decay exponentially. At 250 ms, the watchdog enters fail-safe: steering centers and all pedals drop to zero (including brake). Slamming full brake during a packet drop can unsettle the car and spin it mid-corner. When packets resume, steering eases back to live input over 300 ms and the pedals over 100 ms, buttons return immediately, and a short hiccup with the wheel near its held angle snaps straight back.

---

## Wire Protocol at a Glance

All multi-byte fields are little-endian. The uplink is validated by length, magic bytes, an **XXH32** checksum seeded with `0x4F535401`, and zeroed padding, in that order. The downlink carries no checksum: the phone checks only its length and magic, and sanitizes the slip value.

### Uplink Frame: Phone → Host (`32 bytes`, 120 Hz)

| Offset | Type | Field | Description |
|---|---|---|---|
| `0..3` | `uint32` | `magic` | `0x4F535452` (wire bytes `52 54 53 4F`) |
| `4..5` | `uint16` | `seq` | Monotonic sequence number (`0..65535`, signed-16 wrap window) |
| `6..7` | `int16` | `steer` | Steering angle (`-32767` full left .. `0` center .. `+32767` full right) |
| `8..9` | `uint16` | `throttle` | Throttle pedal (`0..65535`) |
| `10..11` | `uint16` | `brake` | Brake pedal (`0..65535`) |
| `12..13` | `uint16` | `clutch` | Clutch pedal (`0..65535`; the app sends `0`) |
| `14..15` | `uint16` | `pad` | Reserved (`0`, rejected if non-zero) |
| `16..19` | `uint32` | `buttons` | Bitmask: `bit 0` UpShift (RB), `bit 1` DownShift (LB), `bit 2` Handbrake (B), `bit 3` spare (mapped to A; the app never sets it) |
| `20..27` | `uint64` | `ts_ns` | Sender monotonic timestamp in nanoseconds |
| `28..31` | `uint32` | `checksum` | `XXH32(bytes[0..27], seed = 0x4F535401)` |

### Downlink Frame: Host → Phone (`16 bytes`, 60 Hz)

| Offset | Type | Field | Description |
|---|---|---|---|
| `0..3` | `uint32` | `magic` | `0x46464231` (wire bytes `31 42 46 46`) |
| `4..5` | `uint16` | `rpm` | Engine RPM from Assetto Corsa `rpms`, clamped to `0..65535` |
| `6` | `uint8` | `abs` | ABS active (`0` or `1`; the phone treats any non-zero value as active) |
| `7` | `uint8` | `tc` | Traction control active (`0` or `1`) |
| `8..11` | `float32` | `slip` | Largest absolute wheel slip divided by `--slip-full`, clamped to `0.0..1.0` (the phone maps NaN/infinity to `0`) |
| `12..15` | `uint32` | `reserved` | `0`; with `--echo-rtt`, the low 32 bits of the uplink's `ts_ns`, for round-trip measurement (in that mode the host replies once per accepted uplink instead of on the 60 Hz timer) |

The downlink has no sequence number and no checksum: loss is tolerated. The full specification, including the checksum algorithm and its known-answer tests, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#2-wire-protocol).

---

## Repository Layout

```text
server-windows/
  OpenSteer.Core/          portable protocol, math, and watchdog library (no Win32, no sockets, no Console)
  OpenSteer.Server/        Windows daemon: UDP hot loop, P/Invoke, ViGEm sink, shared-memory telemetry
  OpenSteer.Tests/         xUnit test suite (references OpenSteer.Core only)
tools/                     Python reference implementation, desktop feeders, probes, and golden vector generator
client-ios/
  Sources/OpenSteerCore/   quaternion twist math, wire codecs, pedal mapper, haptics policy (Foundation only)
  Tests/                   XCTest suite pinned to the shared golden vector fixture
  App/                     XcodeGen project spec and SwiftUI application
bridge-esp32/              ESP32-S3 Wi-Fi SoftAP to USB-HID joystick firmware (optional hardware bridge)
docs/
  ARCHITECTURE.md          full wire specification, state machines, threading model, and latency numbers
  sim-presets/             per-game setup guides (Assetto Corsa, BeamNG.drive, Forza Horizon) and an Assetto Corsa controller preset
third_party/vigem/         ViGEmClient.dll, committed and hash-verified at build time
```

`OpenSteer.Tests` references `OpenSteer.Core` and never the server executable. That keeps the test project free of the executable's entry point and allows `OpenSteer.Server` to publish cleanly as a self-contained single-file binary.

---

## Building & Running

### Prerequisites
* **Windows Daemon:** .NET 8 SDK and the [ViGEmBus v1.22.0](https://github.com/nefarius/ViGEmBus/releases) driver (provides the virtual Xbox 360 controller).
* **Python Harness & Tools:** Python 3.13+ (uses standard library only—no `pip install` needed for tests).
* **iOS Client:** macOS with Xcode 15+ and XcodeGen (see **[client-ios/README.md](client-ios/README.md)**).
* **ESP32-S3 Bridge:** PlatformIO or Arduino CLI (see **[bridge-esp32/README.md](bridge-esp32/README.md)**).

### Running the Test Suites

From the repository root:

```bash
# Run the 79 C# xUnit tests
dotnet test server-windows/OpenSteer.Tests/OpenSteer.Tests.csproj

# Run the 41 Python unittest tests (protocol, bridge logic, and live daemon probes).
# The 3 daemon probes need Windows and a Release build: they are skipped if the daemon
# has not been built, and fail if the build is older than its sources, so rebuild first.
dotnet build server-windows/OpenSteer.sln -c Release
python -m unittest discover -s tools -p "test_*.py"
```

### Running the Windows Daemon

Start the daemon and restrict UDP input to your phone's IPv4 address with `--allow`:

```powershell
dotnet run --project server-windows/OpenSteer.Server -c Release -- --mode a --allow <phone-ip>
```

To build a standalone release executable:

```powershell
dotnet publish server-windows/OpenSteer.Server -c Release -r win-x64
```

The standalone executable and `ViGEmClient.dll` are written to `server-windows/OpenSteer.Server/bin/Release/net8.0-windows/win-x64/publish/`.

### Testing on Windows Without an iPhone

You can test the daemon and drive in Assetto Corsa on a Windows PC without an iPhone using the included Python tools. The tools send from `127.0.0.1`, so start the daemon with `--allow 127.0.0.1` (a phone-only `--allow` drops their packets):

```powershell
dotnet run --project server-windows/OpenSteer.Server -c Release -- --mode a --allow 127.0.0.1
```

Then, in a second terminal:

```powershell
# Drive the virtual Xbox 360 controller using your keyboard
# (A/D = steer, W/S = throttle/brake, Space = handbrake, E/Q = shift, R = re-center, Esc = stop)
python tools/drive_keys.py

# Or run the automated sine-wave mock phone feeder and inspect the controller in joy.cpl
python tools/feed_joycpl.py --duration 30
```

`drive_keys.py` reads the keyboard globally while it runs, so its keys act whatever window has focus. In Assetto Corsa, set **Input method: Gamepad** and load the `OpenSteer_Xbox360` preset first: the stock preset binds several of those keys to game shortcuts.

Setup guides for **Assetto Corsa**, **BeamNG.drive**, and **Forza Horizon 4/5**, plus a ready-made Assetto Corsa controller preset, are in **[docs/sim-presets/](docs/sim-presets/)**.

---

## Cross-Language Golden Vectors

`tools/golden_vectors.json` is the single conformance fixture behind all four implementations. It is generated deterministically by `tools/golden_vectors.py` and never edited by hand.

* Before writing the fixture, `golden_vectors.py` checks its own XXH32 implementation against four published reference values (`""`, `"a"`, `"abc"`, and `"Nobody inspects the spammish repetition"`).
* The Python suites (`test_osproto.py` and `test_bridge_logic.py`) load `tools/golden_vectors.json` directly, the C# suite (`OpenSteer.Tests`) loads the copy its build places beside the test assembly, and the Swift suite (`OpenSteerCoreTests`) loads a byte-identical copy bundled with its tests; each checks the frame bytes, checksums, steering math, or watchdog curves it implements. The C++ host test (`bridge-esp32/test/test_pure.cpp`) carries checksum, sequence-wrap, and watchdog values copied from the fixture.
* CI regenerates the fixture on every push to `main` and on every pull request, and fails if it differs from the committed file or from the Swift test bundle's copy.

```bash
python tools/golden_vectors.py
```

---

## Security Model

The UDP protocol uses an XXH32 checksum to catch packet corruption, not to provide cryptographic authentication. Without `--allow`, any host that can reach UDP port 9999 on the PC can claim an idle session and drive the virtual controller.

* **Filter by source IP:** Pass `--allow <phone-ip>` on any network you do not fully control so packets from any other address are dropped before they can take the session. This is a source filter, not authentication: a host on the same network can still forge the phone's address.
* **Scope the Windows Firewall rule:** Allow UDP 9999 inbound on the **Private** network profile and local subnet only—never on `Public`:
  ```powershell
  New-NetFirewallRule -DisplayName 'OpenSteer UDP 9999' -Direction Inbound -Protocol UDP -LocalPort 9999 -RemoteAddress LocalSubnet -Action Allow -Profile Private
  ```
* **ESP32-S3 SoftAP passphrase:** No default Wi-Fi password ships in the repository. Copy `bridge-esp32/src/ap_secret.example.h` to `bridge-esp32/src/ap_secret.h` (git-ignored) and set your own WPA2 passphrase before building the firmware.

See **[SECURITY.md](SECURITY.md)** for full details and private vulnerability reporting instructions.

---

## Third-Party Components & License

`third_party/vigem/ViGEmClient.dll` (x64, FileVersion `1.21.233.0`, 141,312 bytes, MIT-licensed) is extracted unmodified from the `costura64.vigemclient.dll` resource of the official `Nefarius.ViGEm.Client` `1.21.256` NuGet package and committed so the server build needs no separate download of the ViGEm client.

* The MSBuild target `VerifyViGEmClientHash` verifies the DLL's SHA-256 digest on every build and publish.
* The P/Invoke resolver loads `ViGEmClient.dll` only from the executable's own directory (`AppContext.BaseDirectory`) and fails closed if it is missing; every other native import is limited to `SafeDirectories`, so nothing is searched for on `PATH` or in the working directory.

Full provenance, the pinned SHA-256 digest, and upstream license texts are in **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**. This project is licensed under the **[MIT License](LICENSE)**.
