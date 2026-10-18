# OpenSteer ESP32-S3 bridge

Optional. An ESP32-S3 board that lets the phone drive a game with no OpenSteer
software on the PC.

The board creates its own Wi-Fi network, listens for the same 32-byte packets the
Windows daemon does, and presents itself over USB as a plain HID game controller.
It needs no driver, installer or background service. Windows, Linux, macOS and a
PlayStation all bind a generic HID joystick out of the box.

The cost is that there is no force feedback. The bridge has no game telemetry to
read, so it never sends a downlink. The phone only enters its degraded state after
it has seen at least one downlink, so a bridge session is not reported as a fault.

## Status

Both firmware variants (`pio run -e dev` and `pio run -e release`) build in CI with
the pinned PlatformIO platform. The board has never been flashed, so none of the
hardware tests below has run.

The checksum and the watchdog are plain C++ with no chip headers, so they are
tested on the host: `test/test_pure.cpp` builds them with g++ and checks them
against numbers from `tools/golden_vectors.json`, the fixture that also pins the
C# daemon and the Swift client. Those tests pass in CI, and
`tools/test_bridge_logic.py` runs a Python re-derivation of both against the same
fixture.

## Hardware

An ESP32-S3 DevKitC-1. Any S3 board with a native USB connector works; what
matters is that the chip has a USB OTG peripheral, which the original ESP32 does
not. Plug into the port marked **USB**, not the one marked **UART**: the UART port
goes through a separate serial chip and cannot present a HID device.

## Building

**First, set the Wi-Fi passphrase.** There is no default. Copy the example file to
`src/ap_secret.h`, which is git-ignored, and set `OSTEER_AP_PASSWORD` to a passphrase
of your own, 8 to 63 characters. The build stops with an error until you do.

```bash
cp bridge-esp32/src/ap_secret.example.h bridge-esp32/src/ap_secret.h
```

One way to make a good passphrase:

```bash
python -c "import secrets; print(secrets.token_urlsafe(18))"
```

Either the Arduino CLI or PlatformIO can be used; the Arduino CLI is the primary
path. Install the same core version PlatformIO is pinned to:

```bash
arduino-cli core install esp32:esp32@3.3.12
```

```bash
arduino-cli compile -v --fqbn esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,UploadMode=cdc,PartitionScheme=default,FlashSize=4M,PSRAM=disabled,UploadSpeed=921600 --build-property "compiler.cpp.extra_flags=-DOSTEER_DEV_CDC=1" bridge-esp32
```

**Never pass `build.extra_flags`.** In the ESP32 platform definition that key
expands to the whole group of USB defines, and `--build-property` replaces a value
rather than adding to it. Overriding it wipes `ARDUINO_USB_MODE`, and the build
then fails on the `#error` at the top of the sketch, which exists to catch this.
`compiler.cpp.extra_flags` is empty by default and is the right place.

PlatformIO instead:

```bash
pio run -e dev
```

`platformio.ini` pins the platform to pioarduino release 55.03.312-1 (Arduino core
3.3.12, ESP-IDF 5.5.5) rather than the moving `stable` tag, so a build does not
change underneath you. `default_envs = dev`, so a bare `pio run` builds the
development firmware; `pio run -e release` builds the release one.

A successful build shows exactly one `-DARDUINO_USB_MODE=0` in the compile line.
Two means the board definition and the override are both setting it.

## Flashing

```bash
arduino-cli board list
```

Hold **BOOT**, tap **RESET**, release BOOT, then upload to the port that appears.

```bash
arduino-cli upload -p COM5 --fqbn esp32:esp32:esp32s3 bridge-esp32
```

The release build has no serial interface at all, so re-flashing it always needs
the BOOT and RESET buttons. The development build can be re-flashed without them.

On Windows, remove any WinUSB or libusb filter you may have installed for
`303A:1001` before testing. A filter driver claims the device and the HID
interface never appears.

**The USB product ids are placeholders.** The firmware presents Espressif's vendor
id `0x303A` with product id `0x8100` (development) or `0x8101` (release). Espressif
has not allocated those two to this project. They are fine on your own desk; before
distributing a build, request a real pair at https://github.com/espressif/usb-pids
and put them in `src/config.h`.

## Using it

1. Plug the board into the PC.
2. Join the Wi-Fi network **OpenSteer-AP** with the passphrase you set in `src/ap_secret.h`.
3. Point the phone at `192.168.4.1` port `9999`.
4. Open `joy.cpl` on the PC. "OpenSteer Wheel" should be listed.

The LED shows the bridge's link state.

| Color | Meaning |
|---|---|
| Blue | Access point up, nothing connected |
| Green | Streaming |
| Amber | Link has gone quiet, pedals decaying |
| Red | Fail-safe, coasting |
| Purple | Slewing back after a reconnection |
| Pink | Startup failed; stays pink until reset |

## The development console

The development build adds a serial console on the same USB cable, used to read
counters during the hardware tests below.

| Command | Does |
|---|---|
| `stats` | Counters, jitter, free heap, link state |
| `reset` | Clears the counters |
| `info` | Network settings and the LED pin |
| `led <38\|48>` | Sets the LED pin and remembers it; any other pin is refused |
| `pw <password>` | Changes the Wi-Fi passphrase, 8 to 63 characters |
| `ch <1\|6\|11>` | Changes the Wi-Fi channel |

If the LED never lights, try `led 38`. DevKitC-1 revision 1.0 wires it to
GPIO 48 and revision 1.1 to GPIO 38. The revision is not readable at runtime, so
the firmware guesses 48 and lets you correct it.

Stored values are checked again on every boot, not only when the console writes
them. A stored passphrase outside 8 to 63 characters falls back to the one built in
from `src/ap_secret.h`, a channel other than 1, 6 or 11 falls back to 6, and an LED
pin other than 38 or 48 falls back to 48.

## How it is built

**Nothing on the packet path allocates.** The receiver is a callback registered
straight onto an lwIP control block, so the packet is validated on the network
task that already owns it. What reaches the USB task is a 32-byte struct in a
mailbox allocated once at startup. A BSD socket would have meant a second task, a
copy, and a blocking read to wake. The heap soak test below is meant to confirm
this.

**The mailbox is one slot deep, and writing to it overwrites.** If two packets
arrive while the USB task is busy, the older one is stale. Delivering it would put
the wheel where the driver's hands were rather than where they are.

**The USB task runs on core 1 at near-top priority.** Core 0 carries the Wi-Fi and
lwIP stacks, and sharing a core with them would put millisecond gaps into a stream
that should arrive every 8 ms.

**When the link is lost, the car coasts.** After 100 ms of silence the pedals
decay. After 250 ms steering centers and every pedal goes to zero, including the
brake. The brake is released rather than applied because a full brake at that
point would destabilize the tire model and can spin a car mid-corner. On
reconnection steering eases back over 300 ms and the pedals over 100 ms, so
throttle response returns almost at once and only the wheel is eased.

This watchdog matches the Windows daemon's to the least significant bit and is
tested against the same reference curves, so a lost link behaves the same on
either path; the schedule is in [ARCHITECTURE.md](../docs/ARCHITECTURE.md).

**The access point reports when the phone disconnects.** That signal arrives
sooner than the timeout, so a disconnection goes straight to the fail-safe instead
of waiting 250 ms with the last steering angle still applied.

## Hardware tests

None of these have been run.

| Test | What it checks | Needs |
|---|---|---|
| Enumeration | Enumerates, axes and buttons move | Board and a PC |
| Coast and recovery | Coast and recovery, seen in joy.cpl | Board and a PC |
| Heap soak | Free heap does not move over ten minutes | Board, console |
| Latency | Motion to injection under 3 ms | Board, a microswitch fixture |
