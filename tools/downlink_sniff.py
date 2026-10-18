"""Stand-in for the phone: streams uplink and checks the FFB frames that come back.

One socket does both directions, as in the iOS client. This proves the daemon replies
from the port the phone sent to, so a single connected flow is enough and no listener
or extra firewall rule is needed.

Run:  python tools/downlink_sniff.py --duration 10
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hires_timer as ht
import osproto as p


class Feeder(threading.Thread):
    """Sends uplink at a steady rate so the daemon keeps a live lease."""

    def __init__(self, sock: socket.socket, dst: tuple[str, int], rate: float,
                 pause_at: float | None, pause_ms: float, once: bool) -> None:
        super().__init__(daemon=True)
        self.sock = sock
        self.dst = dst
        self.rate = rate
        self.pause_at = pause_at
        self.pause_ms = pause_ms
        self.once = once
        self.stop = threading.Event()
        self.sent = 0
        self.t0 = 0

    def run(self) -> None:
        if self.once:
            self.sock.sendto(self._frame(0), self.dst)
            self.sent = 1
            return

        period_ns = int(1_000_000_000 / self.rate)
        seq = 0
        with ht.WinTimerPeriod(1):
            self.t0 = time.perf_counter_ns()
            deadline = self.t0
            while not self.stop.is_set():
                deadline += period_ns
                ht.sleep_until(deadline, 1_500_000)
                t = (deadline - self.t0) / 1e9

                if self.pause_at is not None and \
                        self.pause_at <= t < self.pause_at + self.pause_ms / 1000.0:
                    continue

                self.sock.sendto(self._frame(seq), self.dst)
                seq = (seq + 1) & 0xFFFF
                self.sent += 1

    def _frame(self, seq: int) -> bytes:
        # Buttons stay at zero. Windows maps gamepad A and B to select and back, so a
        # long-running test that presses buttons clicks things on the operator desktop.
        return p.pack_uplink(seq=seq, steer=0, throttle=0, brake=0, clutch=0,
                             buttons=0, ts_ns=time.perf_counter_ns())


def selftest() -> int:
    frame = p.pack_downlink(7250, 1, 0, 0.125)
    magic, rpm, abs_a, tc, slip, reserved = p.unpack_downlink(frame)
    ok = (len(frame) == 16 and magic == p.DOWNLINK_MAGIC and rpm == 7250
          and abs_a == 1 and tc == 0 and abs(slip - 0.125) < 1e-9 and reserved == 0)
    print("PASS selftest" if ok else "FAIL selftest")
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Fake phone: uplink out, FFB frames in")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--uplink-rate", type=float, default=120.0)
    ap.add_argument("--duration", type=float, default=10.0)
    ap.add_argument("--no-uplink", action="store_true")
    ap.add_argument("--uplink-once", action="store_true")
    ap.add_argument("--pause-at", type=float, default=None)
    ap.add_argument("--pause-ms", type=float, default=600.0)
    ap.add_argument("--rtt", action="store_true")
    ap.add_argument("--vanish", action="store_true",
                    help="close the socket mid-run to provoke an ICMP unreachable")
    ap.add_argument("--expect-abs-edges", type=int, default=None)
    ap.add_argument("--expect-tc-edges", type=int, default=None)
    ap.add_argument("--expect-min-pps", type=float, default=None)
    ap.add_argument("--expect-max-pps", type=float, default=None)
    ap.add_argument("--expect-gap-ms", type=float, default=None,
                    help="require one downlink outage of at least this long")
    ap.add_argument("--expect-no-gap-ms", type=float, default=None,
                    help="require every downlink gap to stay under this")
    ap.add_argument("--expect-zero", action="store_true",
                    help="pass only if no downlink frames arrive")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    ht.require_qpc_clock()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    sock.settimeout(0.25)
    dst = (args.host, args.port)

    def emit(obj: dict) -> None:
        print(json.dumps(obj) if args.json else
              " ".join(f"{k}={v}" for k, v in obj.items()), flush=True)

    feeder = None
    if not args.no_uplink:
        feeder = Feeder(sock, dst, args.uplink_rate, args.pause_at, args.pause_ms,
                        args.uplink_once)
        feeder.start()

    arrivals: list[int] = []
    sources: set[str] = set()
    lengths: set[int] = set()
    rtts: list[int] = []
    bad = 0
    abs_edges = 0
    tc_edges = 0
    prev_abs = 0
    prev_tc = 0
    slips: list[float] = []
    rpms: list[int] = []
    first_ns = None

    t_end = time.perf_counter() + args.duration
    while time.perf_counter() < t_end:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break

        now_ns = time.perf_counter_ns()
        lengths.add(len(data))
        sources.add(f"{addr[0]}:{addr[1]}")

        if len(data) != p.DOWNLINK_SIZE:
            bad += 1
            continue

        magic, rpm, abs_a, tc, slip, reserved = p.unpack_downlink(data)
        if magic != p.DOWNLINK_MAGIC:
            bad += 1
            continue

        if first_ns is None:
            first_ns = now_ns
        arrivals.append(now_ns)
        rpms.append(rpm)
        slips.append(slip)

        if abs_a and not prev_abs:
            abs_edges += 1
        if tc and not prev_tc:
            tc_edges += 1
        prev_abs, prev_tc = abs_a, tc

        if args.rtt and reserved:
            # Both halves of this subtraction come from this machine's own clock.
            # The daemon only echoes the value back and never interprets it, so the
            # measurement is valid across two clocks with no shared epoch.
            rtt = (now_ns & 0xFFFFFFFF) - reserved
            if rtt < 0:
                rtt += 1 << 32
            if 0 < rtt < 2_000_000_000:
                rtts.append(rtt)

        if args.vanish and len(arrivals) == 30:
            sock.close()
            emit({"ev": "VANISH", "note": "socket closed mid-stream by --vanish"})
            break

    if feeder:
        feeder.stop.set()
        feeder.join(timeout=1.0)

    try:
        sock.close()
    except OSError:
        pass

    count = len(arrivals)
    span = (arrivals[-1] - arrivals[0]) / 1e9 if count > 1 else 0.0
    pps = (count - 1) / span if span > 0 else 0.0
    gaps = [b - a for a, b in zip(arrivals, arrivals[1:])]

    result = {
        "ev": "DL",
        "frames": count,
        "pps": round(pps, 1),
        "bad": bad,
        "lengths": sorted(lengths),
        "src": sorted(sources),
        "abs_edges": abs_edges,
        "tc_edges": tc_edges,
    }
    if gaps:
        result["ia_p50_us"] = ht.pct(gaps, 0.50) // 1000
        result["ia_p99_us"] = ht.pct(gaps, 0.99) // 1000
        # The largest gap is reported separately because a single outage shows up as
        # one outlier, and a p99 over several hundred samples does not see one
        # outlier. It reports a normal gap, and the test would pass even though the
        # daemon streamed through an outage it should have stopped for.
        result["ia_max_us"] = max(gaps) // 1000
    if rpms:
        result["rpm_min"] = min(rpms)
        result["rpm_max"] = max(rpms)
    if slips:
        result["slip_min"] = round(min(slips), 4)
        result["slip_max"] = round(max(slips), 4)
    if rtts:
        result["rtt_p50_us"] = ht.pct(rtts, 0.50) // 1000
        result["rtt_p99_us"] = ht.pct(rtts, 0.99) // 1000
    emit(result)

    failures = []
    if args.expect_zero and count != 0:
        failures.append(f"expected no downlink frames, got {count}")
    if not args.expect_zero and not args.vanish and count == 0:
        failures.append("no downlink frames arrived")
    if bad:
        failures.append(f"{bad} malformed frames")
    if lengths - {p.DOWNLINK_SIZE} and not args.expect_zero:
        failures.append(f"unexpected frame sizes {sorted(lengths)}")
    if not args.expect_zero and count and len(sources) != 1:
        failures.append(f"frames came from {len(sources)} sources, expected 1")
    if not args.expect_zero and count and sources:
        only = next(iter(sources))
        if not only.endswith(f":{args.port}"):
            failures.append(f"reply came from {only}, expected source port {args.port}")
    if args.expect_min_pps is not None and pps < args.expect_min_pps:
        failures.append(f"pps {pps:.1f} below {args.expect_min_pps}")
    if args.expect_max_pps is not None and pps > args.expect_max_pps:
        failures.append(f"pps {pps:.1f} above {args.expect_max_pps}")
    if args.expect_gap_ms is not None:
        largest = (max(gaps) / 1e6) if gaps else 0.0
        if largest < args.expect_gap_ms:
            failures.append(f"largest downlink gap {largest:.0f} ms, "
                            f"expected at least {args.expect_gap_ms:.0f} ms")
    if args.expect_no_gap_ms is not None:
        largest = (max(gaps) / 1e6) if gaps else 0.0
        if largest > args.expect_no_gap_ms:
            failures.append(f"largest downlink gap {largest:.0f} ms, "
                            f"expected under {args.expect_no_gap_ms:.0f} ms")
    if args.expect_abs_edges is not None and abs(abs_edges - args.expect_abs_edges) > 1:
        failures.append(f"abs edges {abs_edges}, expected {args.expect_abs_edges} +/-1")
    if args.expect_tc_edges is not None and abs(tc_edges - args.expect_tc_edges) > 1:
        failures.append(f"tc edges {tc_edges}, expected {args.expect_tc_edges} +/-1")

    for f in failures:
        emit({"ev": "FAIL", "reason": f})

    emit({"ev": "RESULT", "verdict": "PASS" if not failures else "FAIL"})
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
