"""Generates tools/golden_vectors.json - the cross-language conformance fixture.

Consumed by:
  server-windows/OpenSteer.Tests        (xunit, via a csproj None item)
  client-ios/Tests/OpenSteerCoreTests   (XCTest, via SwiftPM resources)
  bridge-esp32 host-side unit test

Run:  python tools/golden_vectors.py

Every number in this file is computed, never transcribed by hand.
"""

from __future__ import annotations

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import osproto as p
import twistmath as t

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_vectors.json")

# Watchdog constants - kept here so every implementation agrees.
T_SOFT_MS = 100.0
T_HARD_MS = 250.0
TAU_MS = 30.0
T_SLEW_MS = 300.0     # steer
T_PSLEW_MS = 100.0    # pedals
DECAY_FLOOR = 257     # below this the decay snaps to 0

KAT1_HEX = "525453 4f0100 39 30ffff00000000 000005000000896745 2301000000"
KAT2_HEX = "5254534fffff008000 00ffff0080000007 00008 0ffffffffffffffff"


def hx(v: int) -> str:
    return "0x%08X" % v


def unhex(s: str) -> bytes:
    return bytes.fromhex(s.replace(" ", ""))


def decay(v0: int, s_ms: float) -> int:
    if s_ms >= T_HARD_MS:
        return 0
    if s_ms <= T_SOFT_MS:
        return v0
    v = v0 * math.exp(-(s_ms - T_SOFT_MS) / TAU_MS)
    iv = t.round_half_away(v)
    return 0 if iv < DECAY_FLOOR else iv


def slew(frm: int, to: int, elapsed_ms: float, span_ms: float) -> int:
    a = max(0.0, min(1.0, elapsed_ms / span_ms))
    return t.round_half_away(frm + (to - frm) * a)


def main() -> int:
    doc: dict = {
        "version": 1,
        "generator": "tools/golden_vectors.py",
        "note": "All values computed by execution. Do not hand-edit.",
        "checksum": {
            "algorithm": "XXH32",
            "seed": hx(p.CHECKSUM_SEED),
            "covered_bytes": p.CHECKSUM_COVERED,
            "stored_at_offset": 28,
            "stored_little_endian": True,
        },
        "sizes": {"uplink": p.UPLINK.size, "downlink": p.DOWNLINK.size},
        "magics": {
            "uplink_value": hx(p.UPLINK_MAGIC),
            "uplink_wire_bytes": p.UPLINK_MAGIC.to_bytes(4, "little").hex(" "),
            "downlink_value": hx(p.DOWNLINK_MAGIC),
            "downlink_wire_bytes": p.DOWNLINK_MAGIC.to_bytes(4, "little").hex(" "),
        },
    }

    # ---- generic XXH32, checked against the published reference vectors ------
    published = [
        (b"", 0, 0x02CC5D05),
        (b"a", 0, 0x550D7456),
        (b"abc", 0, 0x32D153FF),
        (b"Nobody inspects the spammish repetition", 0, 0xE2293B2F),
    ]
    doc["xxh32_generic"] = []
    for data, seed, expect in published:
        got = p.xxh32(data, seed)
        if got != expect:
            raise AssertionError(
                "XXH32 reference broken for %r: %s != %s" % (data, hx(got), hx(expect)))
        doc["xxh32_generic"].append(
            {"data_hex": data.hex(), "seed": hx(seed), "expect": hx(got)})

    # ---- the protocol checksum over fixed 28-byte inputs ---------------------
    doc["xxh32_28"] = []
    for name, data in [("KAT-0", bytes(28)), ("KAT-1", unhex(KAT1_HEX)),
                       ("KAT-2", unhex(KAT2_HEX))]:
        if len(data) != 28:
            raise AssertionError("%s is %d bytes, expected 28" % (name, len(data)))
        doc["xxh32_28"].append(
            {"name": name, "data_hex": data.hex(" "), "expect": hx(p.xxh32_28(data))})

    # ---- uplink encoder vectors ---------------------------------------------
    uplink_cases = [
        ("U0-zero", dict(seq=0, steer=0, throttle=0, brake=0, clutch=0,
                         buttons=0, ts_ns=0)),
        ("U1-kat1", dict(seq=1, steer=12345, throttle=65535, brake=0, clutch=0,
                         buttons=0x5, ts_ns=0x123456789)),
        ("U2-extremes", dict(seq=65535, steer=-32768, throttle=0, brake=65535,
                             clutch=32768, buttons=0x80000007,
                             ts_ns=0xFFFFFFFFFFFFFFFF)),
        ("U3-right-lock", dict(seq=4660, steer=32767, throttle=1, brake=2,
                               clutch=3, buttons=0xFFFFFFFF, ts_ns=1000000000)),
    ]
    doc["uplink"] = []
    for name, f in uplink_cases:
        raw = p.pack_uplink(**f)
        if len(raw) != 32:
            raise AssertionError("%s encoded to %d bytes" % (name, len(raw)))
        verdict, fields = p.validate_uplink(raw)
        if verdict is not p.Verdict.OK:
            raise AssertionError("%s failed self-validation: %s" % (name, verdict))
        emitted = dict(f)
        emitted["steer"] = p.sat_steer(f["steer"])  # senders never emit -32768
        doc["uplink"].append({"name": name, "fields": emitted,
                              "hex": raw.hex(" "), "checksum": hx(fields[9])})

    # ---- downlink decoder vectors -------------------------------------------
    downlink_cases = [
        ("D0-mid", dict(rpm=7250, abs_active=1, tc_active=0, slip=0.125)),
        ("D1-idle", dict(rpm=0, abs_active=0, tc_active=1, slip=0.0)),
        ("D2-negzero", dict(rpm=8000, abs_active=0, tc_active=0, slip=-0.0)),
        ("D3-full", dict(rpm=65535, abs_active=1, tc_active=1, slip=1.0)),
    ]
    doc["downlink"] = []
    for name, f in downlink_cases:
        raw = p.pack_downlink(**f)
        if len(raw) != 16:
            raise AssertionError("%s encoded to %d bytes" % (name, len(raw)))
        doc["downlink"].append({"name": name, "fields": f, "hex": raw.hex(" ")})

    # ---- negative cases the host must reject --------------------------------
    base = dict(seq=7, steer=100, throttle=200, brake=300, clutch=400,
                buttons=1, ts_ns=42)
    ok = p.pack_uplink(**base)
    bad_magic = bytearray(ok)
    bad_magic[0] ^= 0x01
    doc["reject"] = [
        {"name": "short", "hex": ok[:31].hex(" "), "verdict": "bad_len"},
        {"name": "oversize", "hex": (ok + b"\x00").hex(" "), "verdict": "bad_len"},
        {"name": "bad_magic", "hex": bytes(bad_magic).hex(" "), "verdict": "bad_magic"},
        {"name": "bad_csum",
         "hex": p.pack_uplink(bad_checksum=True, **base).hex(" "),
         "verdict": "bad_csum"},
        {"name": "bad_pad",
         "hex": p.pack_uplink(pad=0xFFFF, **base).hex(" "),
         "verdict": "bad_pad"},
    ]
    for case in doc["reject"]:
        got = p.validate_uplink(unhex(case["hex"]))[0].value
        if got != case["verdict"]:
            raise AssertionError(
                "%s: got %s, want %s" % (case["name"], got, case["verdict"]))

    # ---- sequence wrap ------------------------------------------------------
    doc["seq_wrap"] = []
    for seq, last in [(0, 65535), (65535, 0), (5, 5), (32768, 0), (32767, 0),
                      (1, 0), (0, 1), (100, 90)]:
        d = p.seq_delta(seq, last)
        doc["seq_wrap"].append({"seq": seq, "last_seq": last, "delta": d,
                                "newer": d > 0})

    # ---- twist / steering ---------------------------------------------------
    tv = []

    def add(name, q_ref, q_cur, dor, deadband=0.0, gamma=1.0, expect_deg=None):
        th = t.twist_deg(q_ref, q_cur)
        if expect_deg is not None and abs(th - expect_deg) > 1e-6:
            raise AssertionError("%s: theta %r != %r" % (name, th, expect_deg))
        norm = t.steer_norm(th, dor, deadband, gamma)
        tv.append({
            "name": name,
            "q_ref": list(q_ref), "q_cur": list(q_cur),
            "theta_deg": th,
            "naive_projection_deg": t.naive_projection_deg(q_ref, q_cur),
            "dor_deg": dor, "deadband": deadband, "gamma": gamma,
            "steer_norm": norm, "steer_i16": t.steer_i16(norm),
        })

    add("TV0-identity", t.IDENTITY, t.IDENTITY, 360, expect_deg=0.0)
    add("TV1-flat-30", t.IDENTITY, t.rz(30), 360, expect_deg=30.0)
    add("TV2-tilt60-twist10", t.rx(60), t.mul(t.rx(60), t.rz(10)), 360,
        expect_deg=10.0)
    add("TV3-tilt85-twist10-swing20", t.rx(85),
        t.mul(t.mul(t.rx(85), t.rz(10)), t.ry(20)), 360, expect_deg=10.0)
    add("TV3b-tilt85-tilt-only", t.rx(85), t.mul(t.rx(85), t.ry(10)), 360,
        expect_deg=0.0)
    add("TV6-deadband-gamma", t.IDENTITY, t.rz(-90), 360, deadband=0.05, gamma=1.2)
    doc["twist"] = tv

    # The whole point of invariant I1: the banned method must disagree, hard.
    tv3 = next(v for v in tv if v["name"].startswith("TV3-"))
    tv3b = next(v for v in tv if v["name"].startswith("TV3b"))
    if abs(abs(tv3["naive_projection_deg"]) - 10.0) < 0.5:
        raise AssertionError("TV3 no longer discriminates the banned method")
    if abs(tv3b["naive_projection_deg"]) < 0.2:
        raise AssertionError("TV3b no longer discriminates the banned method")

    # TV4: unwrap past +/-180 so DOR 540/900 are reachable
    u = t.AngleUnwrapper()
    total = 0.0
    for k in range(81):
        total = u.step(t.twist_deg(t.IDENTITY, t.rz(5 * k)))
    doc["unwrap"] = {
        "name": "TV4-unwrap-400deg",
        "sequence_deg": [5 * k for k in range(81)],
        "continuous_deg": total,
        "dor_deg": 900,
        "steer_norm": t.steer_norm(total, 900),
        "steer_i16": t.steer_i16(t.steer_norm(total, 900)),
    }

    # TV5 / TV8: mapper edges fed as already-unwrapped angles
    doc["steer_map"] = [
        {"theta_cont_deg": th, "dor_deg": 360, "deadband": 0.0, "gamma": 1.0,
         "steer_norm": t.steer_norm(th, 360),
         "steer_i16": t.steer_i16(t.steer_norm(th, 360))}
        for th in (200.0, -200.0, 0.0, 180.0, -180.0, 90.0, -45.0)
    ]
    doc["steer_i16_from_norm"] = [
        {"norm": n, "steer_i16": t.steer_i16(n)}
        for n in (-1.0, -0.5, 0.0, 0.5, 1.0)
    ]
    doc["shape"] = [
        {"x": x, "deadband": 0.05, "gamma": 1.2, "y": t.shape(x, 0.05, 1.2)}
        for x in (0.0, 0.05, 0.5, -0.5, 1.0, -1.0)
    ]

    # ---- watchdog reference curves ------------------------------------------
    doc["watchdog"] = {
        "t_soft_ms": T_SOFT_MS, "t_hard_ms": T_HARD_MS, "tau_ms": TAU_MS,
        "t_slew_ms": T_SLEW_MS, "t_pslew_ms": T_PSLEW_MS,
        "decay_floor": DECAY_FLOOR,
        "failsafe": {"steer": 0, "throttle": 0, "brake": 0, "clutch": 0,
                     "buttons": 0,
                     "note": "brake is 0, never 65535 - the car coasts"},
        "decay_from_40000": [{"silence_ms": s, "value": decay(40000, s)}
                             for s in (100, 120, 150, 200, 240, 245, 249, 250)],
        "steer_slew_0_to_32767": [
            {"elapsed_ms": e, "value": slew(0, 32767, e, T_SLEW_MS)}
            for e in (0, 75, 150, 285, 297, 299, 300)],
        "pedal_slew_0_to_65535": [
            {"elapsed_ms": e, "value": slew(0, 65535, e, T_PSLEW_MS)}
            for e in (0, 25, 50, 95, 99, 100)],
    }

    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=2, sort_keys=False)
        fh.write("\n")
    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
