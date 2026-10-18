"""Checks that the virtual controller reaches Windows, without needing a human to
watch joy.cpl.

Sends a handful of held steering positions to the daemon, then reads the resulting
axis values back out of Windows through the multimedia joystick API - the same
source joy.cpl itself displays. Comparing numbers is more reliable than reading a
bar graph by eye.

It moves axes only and never presses a button. Windows maps gamepad A and B to
select and back for shell navigation, so a test that presses buttons will click
things on the user's desktop.

Run:  python tools/verify_controller.py
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import osproto as p

JOY_RETURNX = 0x0001
JOY_RETURNY = 0x0002
JOY_RETURNZ = 0x0004
JOY_RETURNR = 0x0008
JOY_RETURNBUTTONS = 0x0080
JOY_RETURNALL = 0x00FF
JOYERR_NOERROR = 0
MAXPNAMELEN = 32


class JOYINFOEX(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("dwFlags", wt.DWORD),
        ("dwXpos", wt.DWORD), ("dwYpos", wt.DWORD), ("dwZpos", wt.DWORD),
        ("dwRpos", wt.DWORD), ("dwUpos", wt.DWORD), ("dwVpos", wt.DWORD),
        ("dwButtons", wt.DWORD), ("dwButtonNumber", wt.DWORD), ("dwPOV", wt.DWORD),
        ("dwReserved1", wt.DWORD), ("dwReserved2", wt.DWORD),
    ]


class JOYCAPSW(ctypes.Structure):
    _fields_ = [
        ("wMid", wt.WORD), ("wPid", wt.WORD),
        ("szPname", wt.WCHAR * MAXPNAMELEN),
        ("wXmin", wt.UINT), ("wXmax", wt.UINT),
        ("wYmin", wt.UINT), ("wYmax", wt.UINT),
        ("wZmin", wt.UINT), ("wZmax", wt.UINT),
        ("wNumButtons", wt.UINT), ("wPeriodMin", wt.UINT), ("wPeriodMax", wt.UINT),
        ("wRmin", wt.UINT), ("wRmax", wt.UINT),
        ("wUmin", wt.UINT), ("wUmax", wt.UINT),
        ("wVmin", wt.UINT), ("wVmax", wt.UINT),
        ("wCaps", wt.UINT), ("wMaxAxes", wt.UINT), ("wNumAxes", wt.UINT),
        ("wMaxButtons", wt.UINT),
        ("szRegKey", wt.WCHAR * MAXPNAMELEN),
        ("szOEMVxD", wt.WCHAR * 260),
    ]


winmm = ctypes.WinDLL("winmm")


def read_joystick(index: int) -> JOYINFOEX | None:
    info = JOYINFOEX()
    info.dwSize = ctypes.sizeof(JOYINFOEX)
    info.dwFlags = JOY_RETURNALL
    if winmm.joyGetPosEx(index, ctypes.byref(info)) != JOYERR_NOERROR:
        return None
    return info


def describe(index: int) -> str:
    caps = JOYCAPSW()
    if winmm.joyGetDevCapsW(index, ctypes.byref(caps), ctypes.sizeof(JOYCAPSW)) != JOYERR_NOERROR:
        return "?"
    return caps.szPname


def find_devices() -> list[int]:
    return [i for i in range(16) if read_joystick(i) is not None]


def hold(sock: socket.socket, dst: tuple[str, int], seq: int, *, steer: int,
         throttle: int = 0, brake: int = 0, seconds: float = 0.35,
         rate: float = 120.0) -> int:
    """Streams one held position. Buttons are hard-coded to zero: this script must
    never be able to click anything on the machine it is testing."""
    period = 1.0 / rate
    end = time.perf_counter() + seconds
    while time.perf_counter() < end:
        frame = p.pack_uplink(seq=seq, steer=steer, throttle=throttle, brake=brake,
                              clutch=0, buttons=0, ts_ns=time.perf_counter_ns())
        sock.sendto(frame, dst)
        seq = (seq + 1) & 0xFFFF
        time.sleep(period)
    return seq


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Verify the virtual wheel from Windows")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--tolerance", type=int, default=2000,
                    help="allowed error on a 0..65535 axis")
    args = ap.parse_args(argv)

    devices = find_devices()
    if not devices:
        print("FAIL no joystick visible to Windows - is the daemon running in mode a?")
        return 1

    print("devices visible to Windows:")
    for i in devices:
        print(f"  id {i}: {describe(i)}")
    print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dst = (args.host, args.port)
    seq = 0

    # Settle at center first, and pick whichever device actually responds. Scanning
    # for the one that moves avoids guessing wrong when other pads are plugged in.
    seq = hold(sock, dst, seq, steer=0, seconds=0.5)
    centre = {i: read_joystick(i) for i in devices}

    seq = hold(sock, dst, seq, steer=32767, seconds=0.5)
    right = {i: read_joystick(i) for i in devices}

    target = None
    for i in devices:
        if centre[i] and right[i] and abs(int(right[i].dwXpos) - int(centre[i].dwXpos)) > 8000:
            target = i
            break

    if target is None:
        print("FAIL no device responded to a full-right steering command")
        print("     the daemon may not be in mode a, or another app owns the pad")
        return 1

    print(f"responding device: id {target}  ({describe(target)})")
    print()

    # Windows reports these axes as unsigned 0..65535, so signed steering maps to
    # center 32767. The tolerance covers the driver's own rounding.
    cases = [
        ("full left", -32767, 0, 0, "X", 0),
        ("center", 0, 0, 0, "X", 32767),
        ("full right", 32767, 0, 0, "X", 65535),
        ("half right", 16384, 0, 0, "X", 49151),
    ]

    failures = 0
    print(f"{'case':<12} {'sent':>8} {'axis':>5} {'expected':>9} {'read':>7} {'error':>7}  result")
    for name, steer, throttle, brake, axis, expected in cases:
        seq = hold(sock, dst, seq, steer=steer, throttle=throttle, brake=brake)
        info = read_joystick(target)
        if info is None:
            print(f"{name:<12} device vanished")
            failures += 1
            continue
        actual = int(info.dwXpos)
        error = abs(actual - expected)
        ok = error <= args.tolerance
        failures += 0 if ok else 1
        print(f"{name:<12} {steer:>8} {axis:>5} {expected:>9} {actual:>7} {error:>7}  "
              f"{'PASS' if ok else 'FAIL'}")

    # Triggers share one axis under this API, as joy.cpl shows them.
    print()
    seq = hold(sock, dst, seq, steer=0, throttle=65535, seconds=0.4)
    thr = read_joystick(target)
    seq = hold(sock, dst, seq, steer=0, brake=65535, seconds=0.4)
    brk = read_joystick(target)
    seq = hold(sock, dst, seq, steer=0, seconds=0.3)
    rest = read_joystick(target)

    if thr and brk and rest:
        t, b, r = int(thr.dwZpos), int(brk.dwZpos), int(rest.dwZpos)
        print(f"combined trigger axis: throttle={t}  released={r}  brake={b}")
        if t < r < b or b < r < t:
            print("  PASS  throttle and brake push the shared axis opposite ways")
        else:
            print("  FAIL  the two pedals did not move the axis in opposite directions")
            failures += 1

    # Leave the wheel centered and every pedal released.
    hold(sock, dst, seq, steer=0, seconds=0.3)
    sock.close()

    print()
    print("RESULT:", "PASS - the wheel reaches Windows correctly" if failures == 0
          else f"FAIL - {failures} check(s) failed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
