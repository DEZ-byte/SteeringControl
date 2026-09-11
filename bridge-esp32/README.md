# OpenSteer ESP32-S3 bridge

Optional. A four-dollar board that makes the phone work with no software on the
PC at all.

The board creates its own Wi-Fi network, listens for the same 32-byte packets the
Windows daemon does, and presents itself over USB as a plain HID game controller.
No driver, no installer, no service running in the background. Windows, Linux,
macOS and a PlayStation all bind a generic HID joystick out of the box.

The trade is that there is no force feedback. The bridge has nothing to read game
telemetry from, so it never sends a downlink. The phone notices and stays out of
its degraded state on purpose.

## Status

Written, never compiled, never flashed. There is no ESP32 toolchain on the machine
this was authored on, by the same decision that removed the Visual Studio C++
tools from the project. None of the hardware tests below has been run.

What has been checked is the part that can be: the checksum and the watchdog are
plain C++ with no chip headers, and both were re-derived in Python straight from
the source and run against `tools/golden_vectors.json`, the same fixture that pins
the C# daemon and the Swift client. See `tools/test_bridge_logic.py`.

## Hardware

An ESP32-S3 DevKitC-1. Any S3 board with a native USB connector works; what
matters is that the chip has a USB OTG peripheral, which the original ESP32 does
not. Plug into the port marked **USB**, not the one marked **UART**: the UART port
goes through a separate serial chip and cannot present a HID device.

## Building

Either toolchain works. The Arduino CLI is the primary path.

```bash
arduino-cli core install esp32:esp32
```

```bash
arduino-cli compile -v --fqbn esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,UploadMode=cdc,PartitionScheme=default,FlashSize=4M,PSRAM=disabled,UploadSpeed=921600 --build-property "compiler.cpp.extra_flags=-DOSTEER_DEV_CDC=1" bridge-esp32
```

**Never pass `build.extra_flags`.** In the ESP32 platform definition that key
expands to the whole group of USB defines, and `--build-property` replaces a value
rather than adding to it. Overriding it wipes `ARDUINO_USB_MODE` and the build
then fails on the `#error` at the top of the sketch, which is there precisely to
catch this. `compiler.cpp.extra_flags` is empty by default and is the right place.

PlatformIO instead:

```bash
pio run -e dev
```

A successful build shows exactly one `-DARDUINO_USB_MODE=0` in the compile line.
Two means the board definition and the override are fighting.

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

## Using it

1. Plug the board into the PC.
2. Join the Wi-Fi network **OpenSteer-AP**, password `opensteer`.
3. Point the phone at `192.168.4.1` port `9999`.
4. Open `joy.cpl` on the PC. "OpenSteer Wheel" should be listed.

The LED says what the bridge thinks is happening.

| Colour | Meaning |
|---|---|
| Blue | Access point up, nothing connected |
| Green | Streaming |
| Amber | Link has gone quiet, pedals decaying |
| Red | Fail-safe, coasting |
| Purple | Slewing back after a reconnection |
| Pink | Start-up failed |

## The development console

The development build adds a serial console on the same USB cable. It exists to
read counters during the hardware tests below.

| Command | Does |
|---|---|
| `stats` | Counters, jitter, free heap, link state |
| `reset` | Clears the counters |
| `info` | Network settings and the LED pin |
| `led <gpio>` | Sets the LED pin and remembers it |
| `pw <password>` | Changes the Wi-Fi password |
| `ch <1\|6\|11>` | Changes the Wi-Fi channel |

**If the LED never lights, try `led 38`.** DevKitC-1 revision 1.0 wires it to
GPIO 48 and revision 1.1 to GPIO 38. The revision is not readable at runtime, so
the firmware guesses 48 and lets you correct it.

## How it is built

**Nothing on the packet path allocates.** The receiver is a callback registered
straight onto an lwIP control block, so the packet is validated on the network
task that already owns it. What reaches the USB task is a 32-byte struct in a
mailbox allocated once at start-up. A BSD socket would have meant a second task, a
copy, and a blocking read to wake. The heap soak test below proves the claim by
watching the free heap for ten minutes.

**The mailbox is one slot deep, and writing to it overwrites.** If two packets
arrive while the USB task is busy, the older one is worthless. Delivering it would
put the wheel where the driver's hands were rather than where they are.

**The USB task owns core 1 alone.** Core 0 carries the Wi-Fi and lwIP stacks.
Sharing a core with them is what puts millisecond gaps into a stream that is
supposed to arrive every eight.

**Losing the link coasts; it does not brake.** After 100 ms of silence the pedals
decay. After 250 ms steering centres and every pedal goes to zero, including the
brake. Injecting a full brake there would destabilise the tyre model and can spin
a car mid-corner. On reconnection steering eases back over 300 ms and the pedals
over 100 ms, so throttle response returns almost at once and only the wheel is
eased.

This is the same watchdog the Windows daemon runs, to the least significant bit.
It is checked against the same reference curves, because a bridge that coasts on a
different schedule would feel like a different wheel.

**The access point tells us when the phone leaves.** That is better evidence than
silence and it arrives sooner, so a disconnection goes straight to the fail-safe
instead of waiting out the 250 ms timeout with the last steering angle still
applied.

## Hardware tests

None of these have been run.

| Test | What it checks | Needs |
|---|---|---|
| Enumeration | Enumerates, axes and buttons move | Board and a PC |
| Coast and recovery | Coast and recovery, seen in joy.cpl | Board and a PC |
| Heap soak | Free heap does not move over ten minutes | Board, console |
| Latency | Motion to injection under 3 ms | Board, a microswitch fixture |
