"""Can a rejected packet steal the wheel from the driver?

The daemon drains a burst of datagrams in one pass and publishes the lease once at
the end. Publishing the address of the last datagram it touched rather than the one
it accepted hands the wheel to whoever sent the final datagram of the burst. Every
real packet after that is counted as other_src and dropped, and the force-feedback
downlink goes to a machine that is not driving.

Reproducing it needs the right shape of traffic, and two earlier attempts failed
for reasons worth recording:

  A single stray behind a good packet does nothing. On loopback the daemon turns a
  packet around in about 300 us, so it has gone back to the blocking wait long
  before a second sender can get a datagram out. The pass contains one packet and
  there is nothing to confuse.

  A stray sent while the lease is already held does nothing either. It fails the
  magic check at step one and is thrown away before the lease code runs at step
  five. Only a packet that reaches step five can move the lease.

What does reproduce it is a stray sender flooding continuously, so the receive
queue always has strays in it, while the driver's good packets arrive at 120 Hz and
land in the middle of a drain pass. The good packet claims the lease; a stray later
in the same pass overwrites the address; the lease is published for the stray.

A noisy shared network produces this traffic pattern.

Safe to run: the daemon starts in --mode none, so no virtual controller exists and
nothing can reach the desktop.

Run:  python tools/probe_lease_hijack.py
"""

from __future__ import annotations

import argparse
import json
import os
import socket
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


class Daemon:
    """Runs the host headless and collects its 1 Hz stats lines."""

    def __init__(self, exe: str, port: int) -> None:
        self.stats: list[dict] = []
        self.lines: list[str] = []
        self.proc = subprocess.Popen(
            [exe, "--mode", "none", "--stats-json", "1", "--port", str(port)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip()
            self.lines.append(line)
            if line.startswith("{"):
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("ev") == "STATS":
                    self.stats.append(obj)

    def wait_stats(self, count: int, timeout: float = 15.0) -> bool:
        deadline = time.perf_counter() + timeout
        while len(self.stats) < count:
            if time.perf_counter() > deadline:
                return False
            time.sleep(0.02)
        return True

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def good_frame(seq: int) -> bytes:
    # Buttons stay at zero. Windows maps gamepad A and B to select and back, so a
    # probe that presses buttons clicks things on the operator's desktop.
    return p.pack_uplink(seq=seq, steer=0, throttle=0, brake=0, clutch=0,
                         buttons=0, ts_ns=time.perf_counter_ns())


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Probe the burst-drain lease defect")
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--windows", type=int, default=5, help="1 Hz stats windows to watch")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.exists(args.exe):
        print(f"MISSING  {args.exe}", file=sys.stderr)
        print("         Build it: dotnet build server-windows/OpenSteer.Server"
              "/OpenSteer.Server.csproj -c Release", file=sys.stderr)
        return 2

    dst = ("127.0.0.1", args.port)
    daemon = Daemon(args.exe, args.port)
    stop = threading.Event()

    try:
        time.sleep(1.5)
        if not any("listening" in line for line in daemon.lines):
            print("daemon never reported a bound socket", file=sys.stderr)
            return 2

        driver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        driver.bind(("127.0.0.1", 0))
        stray = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        stray.bind(("127.0.0.1", 0))
        driver_port = driver.getsockname()[1]
        stray_port = stray.getsockname()[1]

        # Fails the magic check at step one, so the daemon throws it away. A packet
        # it rejects must not be able to move the wheel.
        bad = bytearray(good_frame(1))
        bad[0] ^= 0x01
        bad = bytes(bad)

        def flood() -> None:
            while not stop.is_set():
                for _ in range(64):
                    stray.sendto(bad, dst)
                time.sleep(0.0005)

        def drive() -> None:
            seq = 0
            while not stop.is_set():
                driver.sendto(good_frame(seq), dst)
                seq = (seq + 1) & 0xFFFF
                time.sleep(1 / 120)

        threading.Thread(target=flood, daemon=True).start()
        time.sleep(0.5)
        threading.Thread(target=drive, daemon=True).start()

        daemon.wait_stats(args.windows)
        stop.set()
        time.sleep(0.3)

        windows = daemon.stats[-args.windows:]
        driver_tag = f":{driver_port}"
        stray_tag = f":{stray_port}"

        stolen = [w for w in windows if str(w.get("src", "")).endswith(stray_tag)]
        rejected = max((w.get("other_src", 0) for w in windows), default=0)
        reproduced = bool(stolen) or rejected > 0

        # The positive control. A run in which no packet reached the daemon - wrong
        # port, a crashed daemon, no stats at all - has no stray in any window and
        # no rejections, so without this it would print NOT REPRODUCED. Such a run
        # passes while proving nothing: src=null throughout.
        held = [w for w in windows
                if str(w.get("src", "")).endswith(driver_tag) and (w.get("acc") or 0) > 0]

        if args.json:
            print(json.dumps({
                "reproduced": reproduced,
                "inconclusive": not reproduced and not held,
                "driver_port": driver_port, "stray_port": stray_port,
                "windows_with_stolen_lease": len(stolen),
                "windows_driver_held_lease": len(held),
                "driver_packets_rejected": rejected,
                "windows": [{k: w.get(k) for k in
                             ("src", "other_src", "acc", "bad_magic", "drain_cap")}
                            for w in windows]}))
        else:
            for w in windows:
                print(f"  src={str(w.get('src')):<22} other_src={w.get('other_src'):<6} "
                      f"acc={w.get('acc'):<5} bad_magic={w.get('bad_magic'):<8} "
                      f"drain_cap={w.get('drain_cap')}")
            print()
            print(f"driver port {driver_port}, stray port {stray_port}")

        # Strays fail the magic check, so they land in bad_magic, never other_src.
        # A nonzero other_src therefore means the driver's own valid packets were
        # turned away, which only happens if the lease moved.
        if reproduced:
            if not args.json:
                print(f"REPRODUCED  the stray held the lease in {len(stolen)} window(s) "
                      f"and {rejected} of the driver's packets were rejected")
            return 1

        if not held:
            if not args.json:
                print("INCONCLUSIVE  the driver never held the lease, so nothing was "
                      "tested. Check the port and that the daemon stayed up.")
            return 2

        if not args.json:
            print("NOT REPRODUCED  the lease stayed with the driver in every window, "
                  "and none of its packets were rejected")
        return 0
    finally:
        stop.set()
        daemon.stop()


if __name__ == "__main__":
    raise SystemExit(main())
