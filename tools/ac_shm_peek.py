"""Read Assetto Corsa's physics page directly, to answer one question.

When the daemon reports `shm=None` there are two very different causes and the
status line cannot tell them apart: the game is not publishing, or the daemon
cannot see what the game is publishing. This attaches to the same named section
the daemon does, read only, and says which.

It samples twice. A section that exists but whose counter does not move means the
game is running but not simulating, which is what sitting in a menu looks like and
is the single most common reason for "the telemetry is not working".

Read only. It never writes, so it is safe to run while somebody is driving, unlike
inject_ac_shm.py, which refuses to start if the game is up.

Run:  python tools/ac_shm_peek.py
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MAP_NAME = "Local\\acpmf_physics"

# Offsets into SPageFilePhysics, identical to
# OpenSteer.Server/Telemetry/AcSharedMemoryReader.cs and to inject_ac_shm.py.
OFF_PACKET_ID = 0
OFF_GAS = 4
OFF_BRAKE = 8
OFF_RPMS = 20
OFF_STEER_ANGLE = 24
OFF_SPEED_KMH = 28
OFF_WHEEL_SLIP = 56
OFF_TC = 204
OFF_ABS = 252

MINIMUM_SIZE = 256

FILE_MAP_READ = 0x0004

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenFileMappingW.restype = wt.HANDLE
kernel32.OpenFileMappingW.argtypes = [wt.DWORD, wt.BOOL, wt.LPCWSTR]
kernel32.CloseHandle.argtypes = [wt.HANDLE]


def section_exists(name: str) -> bool:
    handle = kernel32.OpenFileMappingW(FILE_MAP_READ, False, name)
    if handle:
        kernel32.CloseHandle(handle)
        return True
    return False


def sample(region: mmap.mmap) -> dict:
    """One read of the fields the daemon forwards to the phone.

    Read in the same order the daemon reads them, counter first and last, so a
    torn read is visible rather than silently mixing two moments together.
    """
    packet_id = struct.unpack_from("<i", region, OFF_PACKET_ID)[0]
    gas = struct.unpack_from("<f", region, OFF_GAS)[0]
    brake = struct.unpack_from("<f", region, OFF_BRAKE)[0]
    rpms = struct.unpack_from("<i", region, OFF_RPMS)[0]
    steer = struct.unpack_from("<f", region, OFF_STEER_ANGLE)[0]
    speed = struct.unpack_from("<f", region, OFF_SPEED_KMH)[0]
    slip = struct.unpack_from("<4f", region, OFF_WHEEL_SLIP)
    tc = struct.unpack_from("<f", region, OFF_TC)[0]
    abs_active = struct.unpack_from("<f", region, OFF_ABS)[0]
    packet_id_again = struct.unpack_from("<i", region, OFF_PACKET_ID)[0]

    return {
        "packet_id": packet_id,
        "torn": packet_id != packet_id_again,
        "gas": round(gas, 3),
        "brake": round(brake, 3),
        "rpm": rpms,
        "steer_deg": round(steer, 2),
        "speed_kmh": round(speed, 1),
        "slip": [round(v, 3) for v in slip],
        "tc": round(tc, 3),
        "abs": round(abs_active, 3),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Peek at Assetto Corsa's physics page")
    ap.add_argument("--name", default=MAP_NAME)
    ap.add_argument("--gap", type=float, default=0.5,
                    help="seconds between the two samples")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if not section_exists(args.name):
        print(f"MISSING  the section {args.name!r} does not exist")
        print("         Assetto Corsa is not running, or has not reached a session yet.")
        return 1

    region = mmap.mmap(-1, MINIMUM_SIZE, tagname=args.name, access=mmap.ACCESS_READ)
    try:
        first = sample(region)
        time.sleep(args.gap)
        second = sample(region)
    finally:
        region.close()

    moved = second["packet_id"] != first["packet_id"]
    rate = abs(second["packet_id"] - first["packet_id"]) / args.gap if args.gap else 0

    if args.json:
        print(json.dumps({"attached": True, "live": moved,
                          "packet_rate_hz": round(rate, 1),
                          "first": first, "second": second}))
        return 0 if moved else 2

    print(f"ATTACHED  {args.name}")
    print(f"  packet id   {first['packet_id']} -> {second['packet_id']}"
          f"   ({rate:.0f} per second)")

    if not moved:
        print()
        print("STALE     the section exists but the counter is not moving.")
        print("          The game is running but not simulating, which is what a menu,")
        print("          a loading screen or a paused session looks like from here.")
        print("          Get on track and drive, then run this again.")
        return 2

    print(f"  rpm         {second['rpm']}")
    print(f"  speed       {second['speed_kmh']} km/h")
    print(f"  throttle    {second['gas']}")
    print(f"  brake       {second['brake']}")
    print(f"  steer       {second['steer_deg']} deg")
    print(f"  tire slip   {second['slip']}")
    print(f"  abs / tc    {second['abs']} / {second['tc']}")
    print()
    print("LIVE      the daemon will show shm=Attached and stream this to the phone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
