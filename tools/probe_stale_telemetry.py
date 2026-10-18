"""Does a paused game's frozen engine speed keep coming back?

Assetto Corsa leaves its physics page mapped and its counter frozen while the
driver sits in a menu. The daemon notices after two seconds, calls the page stale
and closes it. If closing also forgets which counter value it last saw, the next
probe reads the frozen counter as brand new, declares the page live again, and
holds it for another two seconds. The result is a two-second cycle: the phone
rumbles at a fixed engine speed, drops to silence, then rumbles again, for as long
as the driver stays in the menu.

Emulates that with a page that is written once and never again, and watches what
the downlink actually carries.

The verdict is not "did 5000 ever follow a 0". The first 0 is the daemon sending
zeros before the page exists, so that test fires on a healthy run too and has
already produced one false positive. What matters is whether 5000 comes back after
the page has been declared stale, which is the loop.

Safe to run: the daemon starts in --mode none, so no virtual controller exists.
Refuses to start if the real game is running, because writing into a live physics
page would corrupt it for whoever is driving.

Run:  python tools/probe_stale_telemetry.py
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import mmap
import os
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import osproto as p

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXE = os.path.join(
    ROOT, "server-windows", "OpenSteer.Server", "bin", "Release",
    "net8.0-windows", "win-x64", "OpenSteer.Server.exe")

MAP_NAME = "Local\\acpmf_physics"
OFF_PACKET_ID = 0
OFF_RPMS = 20
FROZEN_RPM = 5000

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenFileMappingW.restype = wt.HANDLE
kernel32.OpenFileMappingW.argtypes = [wt.DWORD, wt.BOOL, wt.LPCWSTR]
kernel32.CloseHandle.argtypes = [wt.HANDLE]


def section_exists(name: str) -> bool:
    handle = kernel32.OpenFileMappingW(0x0004, False, name)
    if handle:
        kernel32.CloseHandle(handle)
        return True
    return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Probe the stale-telemetry oscillation")
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.exists(args.exe):
        print(f"MISSING  {args.exe}", file=sys.stderr)
        return 2

    if section_exists(MAP_NAME):
        print(f"REFUSING  {MAP_NAME!r} already exists.", file=sys.stderr)
        print("          Assetto Corsa is running. Writing into a live physics page "
              "would corrupt it for the driver.", file=sys.stderr)
        return 3

    dst = ("127.0.0.1", args.port)
    states: list[str] = []
    lines: list[str] = []

    proc = subprocess.Popen(
        [args.exe, "--mode", "none", "--stats-json", "1", "--port", str(args.port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)

    def pump() -> None:
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip()
            lines.append(line)
            if line.startswith("{"):
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("ev") == "STATS":
                    states.append(str(obj.get("shm")))

    threading.Thread(target=pump, daemon=True).start()
    stop = threading.Event()
    region = None

    try:
        time.sleep(1.5)
        if not any("listening" in line for line in lines):
            # Typically the port is taken, by a daemon that is already running.
            # Without this check the probe would talk to that one instead.
            print("daemon never reported a bound socket", file=sys.stderr)
            return 2

        # Written once and never again, which is what a paused game leaves behind.
        region = mmap.mmap(-1, 4096, tagname=MAP_NAME)
        struct.pack_into("<i", region, OFF_RPMS, FROZEN_RPM)
        struct.pack_into("<i", region, OFF_PACKET_ID, 7)

        phone = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        phone.bind(("127.0.0.1", 0))
        phone.settimeout(0.25)

        def feed() -> None:
            seq = 0
            while not stop.is_set():
                phone.sendto(
                    p.pack_uplink(seq=seq, steer=0, throttle=0, brake=0, clutch=0,
                                  buttons=0, ts_ns=time.perf_counter_ns()), dst)
                seq = (seq + 1) & 0xFFFF
                time.sleep(1 / 120)

        feeder = threading.Thread(target=feed, daemon=True)
        feeder.start()

        timeline: list[tuple[float, int]] = []
        last = None
        start = time.perf_counter()

        while time.perf_counter() - start < args.seconds:
            try:
                data, _ = phone.recvfrom(64)
            except socket.timeout:
                continue
            if len(data) != p.DOWNLINK_SIZE:
                continue
            _, rpm, _, _, _, _ = p.unpack_downlink(data)
            if rpm != last:
                timeline.append((round(time.perf_counter() - start, 3), rpm))
                last = rpm

        stop.set()
        # The feeder must be done with the socket before it is closed, or its next
        # sendto raises inside the thread and prints a traceback after the verdict.
        feeder.join(timeout=1.0)
        phone.close()
    finally:
        stop.set()
        if region is not None:
            region.close()
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    # A revival is the frozen value returning after it has been dropped, and the
    # drop only counts once the value has actually been seen.
    #
    # The zero at the start of every run is the daemon sending silence before the
    # page exists, and treating that as a drop makes a healthy run look broken.
    seen_frozen = False
    dropped_after_frozen = False
    revivals = 0
    for _, rpm in timeline:
        if rpm == FROZEN_RPM:
            if dropped_after_frozen:
                revivals += 1
                dropped_after_frozen = False
            seen_frozen = True
        elif rpm == 0 and seen_frozen:
            dropped_after_frozen = True

    reproduced = revivals > 0

    # The positive control. If the frozen value never arrived, telemetry never
    # flowed and there was nothing that could revive, so a quiet run proves nothing.
    inconclusive = not seen_frozen

    if args.json:
        print(json.dumps({"reproduced": reproduced, "inconclusive": inconclusive,
                          "revivals": revivals, "timeline": timeline,
                          "shm_states": states}))
    else:
        print("rpm transitions (seconds, rpm):", timeline)
        print("shm state per window:", states)
        print()
        if reproduced:
            print(f"REPRODUCED  the frozen engine speed came back {revivals} time(s) "
                  "after being dropped")
        elif inconclusive:
            print(f"INCONCLUSIVE  the frozen value {FROZEN_RPM} never arrived, so "
                  "nothing was tested")
        else:
            print("NOT REPRODUCED  the frozen page was dropped once and stayed "
                  "dropped; zeros held")

    if reproduced:
        return 1
    return 2 if inconclusive else 0


if __name__ == "__main__":
    raise SystemExit(main())
