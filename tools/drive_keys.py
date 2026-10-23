"""Drive the wheel from the keyboard, for testing the PC half without a phone.

Sends the same 32-byte uplink packets the phone sends, at 120 Hz by default (a real
iPhone sends 100), so the daemon handles them exactly like the phone's and the run
exercises the real validator, the real watchdog and the real virtual controller.

    A / D     steer left and right, ramped
    W         throttle
    S         brake
    Space     handbrake
    E / Q     shift up and down
    R         re-center the steering at once
    Esc       stop

Keys are read with GetAsyncKeyState rather than from the terminal. Terminal input
only arrives while the terminal has focus, and the purpose here is to drive a game
that has taken the focus for itself. GetAsyncKeyState also reports keys that are
held, where a terminal reports keys that were typed, and a throttle needs the former.

As a result, this reads your keyboard globally while it runs: whatever window is in
front, W is throttle.

    python tools/drive_keys.py

Run:  python tools/drive_keys.py --selftest
"""

from __future__ import annotations

import argparse
import ctypes
import math
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hires_timer as ht
import osproto as p

# Virtual key codes. https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes
VK = {
    "A": 0x41, "D": 0x44, "W": 0x57, "S": 0x53,
    "Q": 0x51, "E": 0x45, "R": 0x52,
    "SPACE": 0x20, "ESC": 0x1B,
}

_user32 = ctypes.WinDLL("user32", use_last_error=True) if os.name == "nt" else None
if _user32 is not None:
    _user32.GetAsyncKeyState.restype = ctypes.c_short
    _user32.GetAsyncKeyState.argtypes = [ctypes.c_int]


def key_down(vk: int) -> bool:
    """True while the key is physically held.

    Only the high bit is read. The low bit means "was pressed since the last
    call", which is a one-shot latch and would make a held key flicker.
    """
    if _user32 is None:
        return False
    return bool(_user32.GetAsyncKeyState(vk) & 0x8000)


def round_half_away(v: float) -> int:
    """The project's rounding rule, matching AxisMath.RoundHalfAway in C#."""
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


class Axis:
    """One ramped control value in 0..1 or -1..1.

    The value ramps rather than jumps, because a keyboard has no middle. Full lock
    the instant a key goes down would be unusable in a car and would also hide
    what is under test: the daemon has to pass a smoothly changing axis through,
    and a square wave would not show whether it does.
    """

    def __init__(self, rise_s: float, fall_s: float, bipolar: bool) -> None:
        self.value = 0.0
        self.rise_s = max(1e-3, rise_s)
        self.fall_s = max(1e-3, fall_s)
        self.bipolar = bipolar

    def step(self, target: float, dt: float) -> float:
        if target > self.value:
            rate = 1.0 / (self.rise_s if target > 0 else self.fall_s)
            self.value = min(target, self.value + rate * dt)
        elif target < self.value:
            rate = 1.0 / (self.rise_s if target < 0 else self.fall_s)
            self.value = max(target, self.value - rate * dt)

        low = -1.0 if self.bipolar else 0.0
        self.value = max(low, min(1.0, self.value))
        return self.value

    def reset(self) -> None:
        self.value = 0.0


def read_controls(steer: Axis, throttle: Axis, brake: Axis, dt: float,
                  buttons_armed: bool) -> tuple[int, int, int, int, bool]:
    """One frame of input. Returns wire values plus whether Esc was pressed."""
    left = key_down(VK["A"])
    right = key_down(VK["D"])

    # Both keys held cancel out and the wheel centers, which is what a driver
    # would expect and is also how the phone behaves when it is put down.
    target = (1.0 if right else 0.0) - (1.0 if left else 0.0)
    steer.step(target, dt)

    if key_down(VK["R"]):
        steer.reset()

    throttle.step(1.0 if key_down(VK["W"]) else 0.0, dt)
    brake.step(1.0 if key_down(VK["S"]) else 0.0, dt)

    mask = 0
    if buttons_armed:
        if key_down(VK["E"]):
            mask |= p.BTN_UPSHIFT
        if key_down(VK["Q"]):
            mask |= p.BTN_DOWNSHIFT
        if key_down(VK["SPACE"]):
            mask |= p.BTN_HANDBRAKE

    steer_i16 = max(-32767, min(32767, round_half_away(steer.value * 32767.0)))
    thr_u16 = round_half_away(throttle.value * 65535.0)
    brk_u16 = round_half_away(brake.value * 65535.0)

    return steer_i16, thr_u16, brk_u16, mask, key_down(VK["ESC"])


def bar(value: float, width: int = 11, bipolar: bool = False) -> str:
    """A tiny meter, so the status line is readable at a glance while driving."""
    if bipolar:
        middle = width // 2
        pos = middle + round_half_away(value * middle)
        pos = max(0, min(width - 1, pos))
        cells = ["-"] * width
        cells[middle] = "|"
        cells[pos] = "#"
        return "".join(cells)

    filled = round_half_away(max(0.0, min(1.0, value)) * width)
    return "#" * filled + "-" * (width - filled)


def selftest() -> int:
    failures = []

    # A frame built here must satisfy the daemon's own validator.
    frame = p.pack_uplink(seq=1, steer=-12345, throttle=65535, brake=0, clutch=0,
                          buttons=p.BTN_UPSHIFT, ts_ns=123456789)
    verdict, fields = p.validate_uplink(frame)
    if verdict is not p.Verdict.OK:
        failures.append(f"validator rejected our own frame: {verdict}")
    elif fields[2] != -12345 or fields[3] != 65535 or fields[7] != p.BTN_UPSHIFT:
        failures.append(f"fields did not round-trip: {fields}")
    if len(frame) != p.UPLINK_SIZE:
        failures.append(f"frame is {len(frame)} bytes, expected {p.UPLINK_SIZE}")

    # Invariant I10: never emit the one 16-bit value with no positive twin.
    axis = Axis(0.001, 0.001, bipolar=True)
    axis.step(-1.0, 1.0)
    if max(-32767, min(32767, round_half_away(axis.value * 32767.0))) != -32767:
        failures.append("full left did not clamp to -32767")

    # A ramp must take about as long as it says it will.
    axis = Axis(rise_s=0.4, fall_s=0.2, bipolar=False)
    elapsed = 0.0
    while axis.value < 1.0 and elapsed < 2.0:
        axis.step(1.0, 1 / 120)
        elapsed += 1 / 120
    if not (0.39 <= elapsed <= 0.42):
        failures.append(f"rise took {elapsed:.3f} s, expected about 0.40")

    elapsed = 0.0
    while axis.value > 0.0 and elapsed < 2.0:
        axis.step(0.0, 1 / 120)
        elapsed += 1 / 120
    if not (0.19 <= elapsed <= 0.22):
        failures.append(f"fall took {elapsed:.3f} s, expected about 0.20")

    # Holding both steering keys must center, not pick one.
    axis = Axis(0.4, 0.25, bipolar=True)
    axis.step(1.0, 0.4)
    axis.step(0.0, 1.0)
    if abs(axis.value) > 1e-9:
        failures.append(f"both keys held did not center: {axis.value}")

    for f in failures:
        print("FAIL " + f)
    print("PASS selftest" if not failures else "FAIL selftest")
    return 0 if not failures else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Drive the OpenSteer wheel from the keyboard")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--rate", type=float, default=120.0, help="packets per second")
    ap.add_argument("--steer-rise", type=float, default=0.45,
                    help="seconds from center to full lock")
    ap.add_argument("--steer-centre", type=float, default=0.30,
                    help="seconds to center when no key is held")
    ap.add_argument("--pedal-rise", type=float, default=0.25, help="seconds to full pedal")
    ap.add_argument("--pedal-fall", type=float, default=0.15, help="seconds to release")
    ap.add_argument("--arm-delay", type=float, default=5.0,
                    help="seconds before the buttons go live; axes stream at once")
    ap.add_argument("--no-buttons", action="store_true",
                    help="never send buttons, whatever is pressed")
    ap.add_argument("--duration", type=float, default=0.0, help="0 means until Esc")
    ap.add_argument("--quiet", action="store_true", help="no status line")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if os.name != "nt":
        print("This reads the keyboard through a Windows API and is Windows only.",
              file=sys.stderr)
        return 2

    ht.require_qpc_clock()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dst = (args.host, args.port)

    steer = Axis(args.steer_rise, args.steer_centre, bipolar=True)
    throttle = Axis(args.pedal_rise, args.pedal_fall, bipolar=False)
    brake = Axis(args.pedal_rise, args.pedal_fall, bipolar=False)

    print(f"OpenSteer keyboard wheel  ->  {args.host}:{args.port}  at {args.rate:g} Hz")
    print("  A / D steer    W throttle    S brake    Space handbrake")
    print("  E / Q shift up and down      R re-center     Esc stop")
    print()
    print("Keys are read globally, so whatever window is in front, W is throttle.")

    if args.no_buttons:
        print("Buttons are disabled for this run.")
    elif args.arm_delay > 0:
        # A virtual pad's buttons are wired to Windows UI navigation when no game
        # has the focus, so a handbrake press on the desktop clicks things. The
        # axes are harmless and start at once; the buttons wait until you have had
        # time to switch to the game.
        print(f"Buttons go live in {args.arm_delay:g} s. Switch to the game now.")

    print()

    period_ns = int(1_000_000_000 / args.rate)
    seq = 0
    sent = 0
    last_status = 0.0
    stop_reason = "Esc"

    try:
        with ht.WinTimerPeriod(1):
            start = time.perf_counter_ns()
            deadline = start
            previous = start

            while True:
                deadline += period_ns
                ht.sleep_until(deadline, 1_500_000)

                now = time.perf_counter_ns()
                dt = (now - previous) / 1e9
                previous = now
                elapsed = (now - start) / 1e9

                armed = (not args.no_buttons) and elapsed >= args.arm_delay
                steer_i16, thr, brk, mask, quit_now = read_controls(
                    steer, throttle, brake, dt, armed)

                if quit_now:
                    break

                if args.duration > 0 and elapsed >= args.duration:
                    stop_reason = "duration reached"
                    break

                sock.sendto(
                    p.pack_uplink(seq=seq, steer=steer_i16, throttle=thr, brake=brk,
                                  clutch=0, buttons=mask, ts_ns=now),
                    dst)
                seq = (seq + 1) & 0xFFFF
                sent += 1

                if not args.quiet and (now - last_status) > 100_000_000:
                    last_status = now
                    held = "".join(c for c, on in (
                        ("E", mask & p.BTN_UPSHIFT),
                        ("Q", mask & p.BTN_DOWNSHIFT),
                        ("_", mask & p.BTN_HANDBRAKE)) if on) or "."
                    gate = "" if armed or args.no_buttons else " (buttons arming)"
                    sys.stdout.write(
                        f"\rsteer [{bar(steer.value, bipolar=True)}] {steer_i16:+6d}  "
                        f"thr [{bar(throttle.value)}]  "
                        f"brk [{bar(brake.value)}]  "
                        f"btn {held:3s}  tx {sent}{gate}   ")
                    sys.stdout.flush()
    except KeyboardInterrupt:
        stop_reason = "Ctrl+C"
    finally:
        # Release everything explicitly rather than leaving the watchdog to time
        # it out. The daemon would coast to neutral on its own after 250 ms, but
        # until then a stuck throttle keeps the car accelerating with nobody
        # driving it.
        # Each copy takes the next sequence number. Five copies of one number would
        # be one frame and four duplicates to the daemon.
        for i in range(5):
            neutral = p.pack_uplink(seq=(seq + 1 + i) & 0xFFFF, steer=0, throttle=0,
                                    brake=0, clutch=0, buttons=0,
                                    ts_ns=time.perf_counter_ns())
            try:
                sock.sendto(neutral, dst)
            except OSError:
                break
        sock.close()

    print(f"\nstopped: {stop_reason}. {sent} packets sent, everything released.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
