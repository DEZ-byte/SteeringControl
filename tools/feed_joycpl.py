"""Mock phone: streams OpenSteer uplink frames at a precise rate.

Drives the Windows daemon without an iPhone, so the whole host can be verified
before any Swift exists. Also injects malformed frames and Wi-Fi style bursts, to
prove the daemon rejects and coalesces rather than merely surviving.

Buttons are off unless asked for. With no game focused, the virtual pad's A/B
buttons navigate the Windows desktop, so pulses are opt-in (--buttons-hz), and no
button, pulsed or held with --hold btn=..., goes live before --arm-delay seconds. Every control is released on the way out,
Ctrl+C included, rather than left for the daemon's 250 ms watchdog.

Examples:
    python tools/feed_joycpl.py --duration 30
    python tools/feed_joycpl.py --duration 30 --buttons-hz 1     # blink RB/LB/B in joy.cpl
    python tools/feed_joycpl.py --pause-at 5 --pause-ms 600 --hold steer=12000,thr=40000
    python tools/feed_joycpl.py --burst 12 --burst-every 1 --duration 20
    python tools/feed_joycpl.py --fault bad_magic:50,bad_csum:50 --amp 30000
    python tools/feed_joycpl.py --selftest
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hires_timer as ht
import osproto as p

# Faulty frames carry this steer value so the daemon can be proven never to have
# injected one: if it shows up in an INJ trace, a bad frame reached the wheel.
FAULT_SENTINEL = 0x7FFF

FAULT_CLASSES = ("bad_magic", "bad_csum", "short", "oversize", "bad_pad",
                 "stale", "dup")


def parse_kv(text: str | None) -> dict[str, int]:
    out: dict[str, int] = {}
    if not text:
        return out
    for pair in text.split(","):
        pair = pair.strip()
        if not pair:
            continue
        key, _, value = pair.partition("=")
        out[key.strip()] = int(value)
    return out


def parse_faults(text: str | None) -> dict[str, int]:
    out: dict[str, int] = {}
    if not text:
        return out
    for pair in text.split(","):
        pair = pair.strip()
        if not pair:
            continue
        name, _, count = pair.partition(":")
        name = name.strip()
        if name not in FAULT_CLASSES:
            raise SystemExit(f"unknown fault class {name!r}; pick from {FAULT_CLASSES}")
        out[name] = int(count)
    return out


def make_fault(kind: str, seq: int, last_seq: int, ts: int) -> bytes:
    """Build one deliberately broken frame. Exactly one rule is violated per frame,
    so each daemon counter can be attributed unambiguously."""
    base = dict(steer=FAULT_SENTINEL, throttle=0, brake=0, clutch=0, buttons=0, ts_ns=ts)

    if kind == "bad_magic":
        raw = bytearray(p.pack_uplink(seq=seq, **base))
        raw[0] ^= 0x01
        return bytes(raw)
    if kind == "bad_csum":
        return p.pack_uplink(seq=seq, bad_checksum=True, **base)
    if kind == "short":
        return p.pack_uplink(seq=seq, **base)[:31]
    if kind == "oversize":
        return p.pack_uplink(seq=seq, **base) + b"\x00"
    if kind == "bad_pad":
        return p.pack_uplink(seq=seq, pad=0xFFFF, **base)
    if kind == "stale":
        return p.pack_uplink(seq=(last_seq - 10) & 0xFFFF, **base)
    if kind == "dup":
        return p.pack_uplink(seq=last_seq, **base)
    raise AssertionError(kind)


def signals(t: float, args: argparse.Namespace, hold: dict[str, int]) -> tuple[int, int, int, int, int]:
    """Steer sine, alternating pedal ramps, rotating button pulses."""
    if "steer" in hold:
        steer = hold["steer"]
    else:
        steer = int(args.amp * math.sin(2.0 * math.pi * args.steer_hz * t))

    if "thr" in hold or "brk" in hold:
        throttle = hold.get("thr", 0)
        brake = hold.get("brk", 0)
    else:
        phase = t % (2.0 * args.ramp_s)
        if phase < args.ramp_s:
            throttle = int(65535 * (phase / args.ramp_s))
            brake = 0
        else:
            throttle = 0
            brake = int(65535 * ((phase - args.ramp_s) / args.ramp_s))

    clutch = hold.get("clu", 0)

    if "btn" in hold:
        # An explicit hold still waits for the arm delay, like pulses do.
        buttons = hold["btn"] if t >= args.arm_delay else 0
    else:
        buttons = 0
        if args.buttons_hz > 0 and t >= args.arm_delay:
            slot = t % (1.0 / args.buttons_hz)
            window = 0.100
            if slot < window:
                buttons |= p.BTN_UPSHIFT
            elif 0.333 <= slot < 0.333 + window:
                buttons |= p.BTN_DOWNSHIFT
            elif 0.666 <= slot < 0.666 + window:
                buttons |= p.BTN_HANDBRAKE

    return steer, throttle, brake, clutch, buttons


def selftest() -> int:
    """Round-trips every golden vector with no network involved."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_vectors.json")
    if not os.path.exists(path):
        print("FAIL golden_vectors.json missing - run python tools/golden_vectors.py")
        return 1

    with open(path, encoding="utf-8") as fh:
        gold = json.load(fh)

    checked = 0
    for v in gold["uplink"]:
        raw = bytes.fromhex(v["hex"].replace(" ", ""))
        verdict, fields = p.validate_uplink(raw)
        if verdict is not p.Verdict.OK:
            print(f"FAIL {v['name']} did not validate: {verdict}")
            return 1
        rebuilt = p.pack_uplink(seq=v["fields"]["seq"], steer=v["fields"]["steer"],
                                throttle=v["fields"]["throttle"],
                                brake=v["fields"]["brake"],
                                clutch=v["fields"]["clutch"],
                                buttons=v["fields"]["buttons"],
                                ts_ns=v["fields"]["ts_ns"])
        if rebuilt != raw:
            print(f"FAIL {v['name']} re-encoded differently")
            return 1
        checked += 1

    for kind in FAULT_CLASSES:
        frame = make_fault(kind, 5, 5, 0)
        verdict, _ = p.validate_uplink(frame)
        structural = {"bad_magic": "bad_magic", "bad_csum": "bad_csum",
                      "short": "bad_len", "oversize": "bad_len", "bad_pad": "bad_pad"}
        if kind in structural and verdict.value != structural[kind]:
            print(f"FAIL fault {kind} produced {verdict.value}")
            return 1
        checked += 1

    print(f"PASS selftest ({checked} vectors)")
    return 0


@contextlib.contextmanager
def neutral_on_exit(sock: socket.socket, destination: tuple[str, int], next_seq):
    """Releases every control on the way out, Ctrl+C included.

    Without this the last frame stays applied until the daemon's watchdog times it
    out, so an interrupted run can leave a button held or the wheel turned for a
    quarter of a second. drive_keys.py follows the same rule. next_seq is read at
    exit time, so the neutral frames continue the sequence instead of being
    rejected as duplicates.
    """
    try:
        yield
    finally:
        for i in range(5):
            frame = p.pack_uplink(seq=(next_seq() + i) & 0xFFFF, steer=0, throttle=0,
                                  brake=0, clutch=0, buttons=0,
                                  ts_ns=time.perf_counter_ns())
            try:
                sock.sendto(frame, destination)
            except OSError:
                break


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="OpenSteer mock phone")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--target", default=None,
                    help="alias for --host; use 192.168.4.1 for the ESP32 bridge")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--src-port", type=int, default=0)
    ap.add_argument("--rate", type=float, default=120.0)
    ap.add_argument("--duration", type=float, default=30.0)
    ap.add_argument("--steer-hz", type=float, default=0.25)
    ap.add_argument("--amp", type=int, default=32767)
    ap.add_argument("--ramp-s", type=float, default=2.0)
    ap.add_argument("--buttons-hz", type=float, default=0.0,
                    help="button pulse rate; 0 (default) never presses a button")
    ap.add_argument("--arm-delay", type=float, default=5.0,
                    help="seconds before any button, pulsed or held, goes live (default 5)")
    ap.add_argument("--pause-at", type=float, default=None)
    ap.add_argument("--pause-ms", type=float, default=600.0)
    ap.add_argument("--hold", default=None, help="steer=..,thr=..,brk=..,clu=..,btn=..")
    ap.add_argument("--resume-hold", default=None, help="values used after the pause")
    ap.add_argument("--seq-start", type=int, default=0)
    ap.add_argument("--fault", default=None, help="class:count,... ")
    ap.add_argument("--burst", type=int, default=0,
                    help="send N frames back to back with no pacing")
    ap.add_argument("--burst-every", type=float, default=1.0)
    ap.add_argument("--spin-margin-us", type=int, default=1500)
    ap.add_argument("--stats", type=int, default=1)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    ht.require_qpc_clock()

    host = args.target or args.host
    hold = parse_kv(args.hold)
    resume_hold = parse_kv(args.resume_hold)
    faults = parse_faults(args.fault)

    if faults and args.amp > 30000 and "steer" not in hold:
        raise SystemExit("--amp must be <= 30000 when faults are enabled, so the "
                         "fault sentinel 0x7FFF cannot collide with real steering")

    total_faults = sum(faults.values())
    expected_valid = int(args.rate * args.duration)
    fault_every = max(1, expected_valid // total_faults) if total_faults else 0
    fault_order = [k for k, n in faults.items() for _ in range(n)]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.src_port:
        sock.bind(("0.0.0.0", args.src_port))
    destination = (host, args.port)

    period_ns = int(1_000_000_000 / args.rate)
    spin_margin_ns = args.spin_margin_us * 1000

    seq = args.seq_start & 0xFFFF
    last_seq = seq
    sent = 0
    faults_sent = 0
    burst_frames = 0
    next_burst = args.burst_every if args.burst else None
    lateness: list[int] = []
    intervals: list[int] = []
    window_start_ns = 0
    previous_send_ns = 0

    pause_start = args.pause_at
    pause_end = None if pause_start is None else pause_start + args.pause_ms / 1000.0

    def emit(obj: dict) -> None:
        print(json.dumps(obj) if args.json else
              " ".join(f"{k}={v}" for k, v in obj.items()), flush=True)

    emit({"ev": "FEED_START", "dst": f"{host}:{args.port}", "rate": args.rate,
          "duration": args.duration, "faults": total_faults,
          "burst": args.burst or 0})

    with ht.WinTimerPeriod(1), neutral_on_exit(sock, destination, lambda: seq):
        t0 = time.perf_counter_ns()
        deadline = t0
        window_start_ns = t0

        while True:
            elapsed = (deadline - t0) / 1e9
            if elapsed >= args.duration:
                break

            deadline += period_ns
            lateness.append(ht.sleep_until(deadline, spin_margin_ns))

            t = (deadline - t0) / 1e9
            paused = pause_start is not None and pause_start <= t < pause_end

            if not paused:
                active_hold = resume_hold if (pause_end is not None and t >= pause_end
                                              and resume_hold) else hold
                steer, throttle, brake, clutch, buttons = signals(t, args, active_hold)
                ts = time.perf_counter_ns()

                # A burst is the stimulus for the burst-drain test: several frames
                # hit the socket with no gap, exactly as a Wi-Fi driver releases a
                # queued bunch. Only the last one should ever reach the wheel.
                if next_burst is not None and t >= next_burst:
                    next_burst += args.burst_every
                    for k in range(args.burst):
                        frame = p.pack_uplink(seq=seq, steer=int(k * 2731),
                                              throttle=throttle, brake=brake,
                                              clutch=clutch, buttons=buttons, ts_ns=ts)
                        sock.sendto(frame, destination)
                        last_seq = seq
                        seq = (seq + 1) & 0xFFFF
                        sent += 1
                        burst_frames += 1
                else:
                    if fault_every and sent and sent % fault_every == 0 and faults_sent < total_faults:
                        kind = fault_order[faults_sent]
                        # Faulty frames never consume a sequence number, so the
                        # daemon must not report them as gaps.
                        sock.sendto(make_fault(kind, seq, last_seq, ts), destination)
                        faults_sent += 1

                    frame = p.pack_uplink(seq=seq, steer=steer, throttle=throttle,
                                          brake=brake, clutch=clutch, buttons=buttons,
                                          ts_ns=ts)
                    sock.sendto(frame, destination)
                    last_seq = seq
                    seq = (seq + 1) & 0xFFFF
                    sent += 1

                now_ns = time.perf_counter_ns()
                if previous_send_ns:
                    intervals.append(now_ns - previous_send_ns)
                previous_send_ns = now_ns

            if args.stats and (deadline - window_start_ns) >= 1_000_000_000:
                if intervals:
                    emit({"ev": "FEED",
                          "p50_us": ht.pct(intervals, 0.50) // 1000,
                          "p99_us": ht.pct(intervals, 0.99) // 1000,
                          "max_us": max(intervals) // 1000,
                          "late": sum(1 for v in intervals if v > 10_000_000)})
                intervals = []
                window_start_ns = deadline

    emit({"ev": "FEED_DONE", "sent": sent, "valid": sent, "faults": faults_sent,
          "burst_frames": burst_frames,
          "wake_p99_us": ht.pct(lateness, 0.99) // 1000 if lateness else 0})
    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
