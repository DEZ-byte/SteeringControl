"""Mock Assetto Corsa physics page, so the FFB path can be tested without the game.

Creates the same named shared-memory section Assetto Corsa publishes and writes a
repeatable pattern into it at 60 Hz. The daemon cannot tell the difference, so the
telemetry tests run on a machine with no game installed.

Refuses to start if the section already exists. If the real game is running, writing
into its page would corrupt live physics for whoever is driving.

Run:  python tools/inject_ac_shm.py --duration 30
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

import hires_timer as ht

MAP_NAME = "Local\\acpmf_physics"

# Offsets into SPageFilePhysics. It is 4-byte packed and made entirely of 4-byte
# members, so field order alone fixes every offset. These match
# OpenSteer.Server/Telemetry/AcSharedMemoryReader.cs exactly.
OFF_PACKET_ID = 0     # int32
OFF_GAS = 4           # float
OFF_BRAKE = 8         # float
OFF_RPMS = 20         # int32
OFF_STEER_ANGLE = 24  # float
OFF_SPEED_KMH = 28    # float
OFF_WHEEL_SLIP = 56   # float[4], FL FR RL RR
OFF_TC = 204          # float
OFF_ABS = 252         # float

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


def square(t: float, hz: float, duty: float = 0.5) -> float:
    if hz <= 0:
        return 0.0
    return 1.0 if (t % (1.0 / hz)) < (duty / hz) else 0.0


def triangle(t: float, hz: float) -> float:
    if hz <= 0:
        return 0.0
    phase = (t * hz) % 1.0
    return phase * 2.0 if phase < 0.5 else (1.0 - phase) * 2.0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mock the Assetto Corsa physics page")
    ap.add_argument("--name", default=MAP_NAME)
    ap.add_argument("--size", type=int, default=4096)
    ap.add_argument("--rate", type=float, default=60.0)
    ap.add_argument("--duration", type=float, default=30.0)
    ap.add_argument("--rpm-lo", type=int, default=800)
    ap.add_argument("--rpm-hi", type=int, default=8000)
    ap.add_argument("--ramp-s", type=float, default=10.0)
    ap.add_argument("--abs-hz", type=float, default=2.0)
    ap.add_argument("--abs-duty", type=float, default=0.25)
    ap.add_argument("--tc-hz", type=float, default=1.0)
    ap.add_argument("--slip-hz", type=float, default=0.5)
    ap.add_argument("--slip-max", type=float, default=1.0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if section_exists(args.name):
        print(f"REFUSING: the section {args.name!r} already exists.", file=sys.stderr)
        print("Assetto Corsa is probably running, or a previous injector is still up.",
              file=sys.stderr)
        print("Writing into a live physics page would corrupt it for the driver.",
              file=sys.stderr)
        return 3

    ht.require_qpc_clock()

    region = mmap.mmap(-1, args.size, tagname=args.name)
    period_ns = int(1_000_000_000 / args.rate)

    def emit(obj: dict) -> None:
        print(json.dumps(obj) if args.json else
              " ".join(f"{k}={v}" for k, v in obj.items()), flush=True)

    emit({"ev": "SHM_START", "name": args.name, "size": args.size,
          "rate": args.rate, "duration": args.duration,
          "t0_ns": time.perf_counter_ns()})

    packet_id = 0
    frames = 0
    abs_edges = 0
    tc_edges = 0
    prev_abs = 0.0
    prev_tc = 0.0

    try:
        with ht.WinTimerPeriod(1):
            t0 = time.perf_counter_ns()
            deadline = t0
            last_report = t0

            while True:
                elapsed = (deadline - t0) / 1e9
                if elapsed >= args.duration:
                    break

                deadline += period_ns
                ht.sleep_until(deadline, 1_500_000)
                t = (deadline - t0) / 1e9

                rpm = int(args.rpm_lo
                          + (args.rpm_hi - args.rpm_lo) * ((t % args.ramp_s) / args.ramp_s))
                abs_active = square(t, args.abs_hz, args.abs_duty)
                tc_active = square(t, args.tc_hz)
                slip = triangle(t, args.slip_hz) * args.slip_max

                if abs_active > prev_abs:
                    abs_edges += 1
                if tc_active > prev_tc:
                    tc_edges += 1
                prev_abs, prev_tc = abs_active, tc_active

                # Payload first, counter last. The daemon reads the counter, the
                # fields, then the counter again, and retries if it moved; writing in
                # this order is what makes that check meaningful.
                struct.pack_into("<f", region, OFF_GAS, 0.5)
                struct.pack_into("<f", region, OFF_BRAKE, abs_active)
                struct.pack_into("<i", region, OFF_RPMS, rpm)
                struct.pack_into("<f", region, OFF_STEER_ANGLE, 0.0)
                struct.pack_into("<f", region, OFF_SPEED_KMH, 120.0)
                struct.pack_into("<4f", region, OFF_WHEEL_SLIP, slip, slip, slip, slip)
                struct.pack_into("<f", region, OFF_TC, tc_active)
                struct.pack_into("<f", region, OFF_ABS, abs_active)

                packet_id += 1
                struct.pack_into("<i", region, OFF_PACKET_ID, packet_id)
                frames += 1

                if (deadline - last_report) >= 1_000_000_000:
                    last_report = deadline
                    emit({"ev": "SHM", "t": time.perf_counter_ns(), "pid": packet_id,
                          "rpm": rpm, "abs": abs_active, "tc": tc_active,
                          "slip": round(slip, 4)})
    except KeyboardInterrupt:
        pass
    finally:
        region.close()

    emit({"ev": "SHM_DONE", "frames": frames, "packet_id": packet_id,
          "abs_edges": abs_edges, "tc_edges": tc_edges})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
