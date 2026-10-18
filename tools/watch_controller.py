"""Watch the virtual controller without touching it, to find where a break is.

When the car will not move there are four links in the chain and the symptom looks
the same at every one of them: the keyboard tool, the network, the daemon, or the
game's own binding. This reads the pad the way Windows reports it, which sits
between the daemon and the game, so it can tell which side is broken.

    axes move  ->  keyboard, network and daemon are all fine, the game is the problem
    axes still ->  the break is before the pad, so look at the keyboard tool

Passive. It never sends a packet and never presses anything, so it is safe to run
while somebody is driving.

Run:  python tools/watch_controller.py --seconds 10
"""

from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from verify_controller import describe, find_devices, read_joystick


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Watch the virtual pad, passively")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--index", type=int, default=None,
                    help="joystick index; default is the first one found")
    ap.add_argument("--rate", type=float, default=60.0)
    args = ap.parse_args(argv)

    devices = find_devices()
    if not devices:
        print("NO DEVICE  Windows reports no joystick at all.")
        print("           The daemon is not running, or it is not in --mode a.")
        return 1

    index = args.index if args.index is not None else devices[0]
    print(f"watching joystick {index}: {describe(index)}")
    for other in devices:
        if other != index:
            print(f"  (also present: {other}: {describe(other)})")
    print(f"sampling for {args.seconds:g} s. Hold the keys now.")
    print()

    lo = {"x": 1 << 20, "y": 1 << 20, "z": 1 << 20, "r": 1 << 20}
    hi = {"x": 0, "y": 0, "z": 0, "r": 0}
    buttons_seen = 0
    samples = 0

    end = time.perf_counter() + args.seconds
    period = 1.0 / args.rate

    while time.perf_counter() < end:
        info = read_joystick(index)
        if info is None:
            print("device vanished mid-sample")
            return 1

        for key, value in (("x", info.dwXpos), ("y", info.dwYpos),
                           ("z", info.dwZpos), ("r", info.dwRpos)):
            lo[key] = min(lo[key], value)
            hi[key] = max(hi[key], value)

        buttons_seen |= info.dwButtons
        samples += 1
        time.sleep(period)

    # A virtual pad reports 0..65535 on every axis, so a spread of a few hundred is
    # noise and anything past a couple of thousand is a real input.
    moved = {k: hi[k] - lo[k] for k in lo}
    print(f"{samples} samples")
    for key, label in (("x", "X  steering"), ("y", "Y"),
                       ("z", "Z  triggers"), ("r", "R")):
        print(f"  {label:<12} {lo[key]:>6} .. {hi[key]:<6}  spread {moved[key]}")

    print(f"  buttons      0x{buttons_seen:04X}")
    print()

    anything = max(moved.values()) > 2000 or buttons_seen != 0
    if anything:
        print("MOVED     the keyboard tool, the network and the daemon are all working.")
        print("          If the car still does not respond, the game is not reading")
        print("          this pad: check its input method and that nothing else has")
        print("          claimed the controller.")
        return 0

    print("STILL     nothing reached the pad in that window.")
    print("          Either no keys were held, or the break is before the daemon:")
    print("          check that tools/drive_keys.py is still running.")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
