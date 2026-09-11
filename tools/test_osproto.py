"""Unit tests for the Python side of the OpenSteer wire protocol and steering math.

Run:  python -m unittest discover -s tools -p "test_*.py" -v

Discovery is used rather than naming the file directly, because unittest only
converts a path to a module name when it is relative to the current directory; an
absolute path is treated as a literal and silently finds nothing.
"""

from __future__ import annotations

import json
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import osproto as p
import twistmath as t

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_vectors.json")


def load_golden() -> dict:
    if not os.path.exists(GOLDEN):
        raise unittest.SkipTest("run python tools/golden_vectors.py first")
    with open(GOLDEN, encoding="utf-8") as fh:
        return json.load(fh)


def unhex(s: str) -> bytes:
    return bytes.fromhex(s.replace(" ", ""))


class TestLayout(unittest.TestCase):
    def test_struct_sizes(self):
        self.assertEqual(p.UPLINK.size, 32)
        self.assertEqual(p.DOWNLINK.size, 16)

    def test_native_alignment_would_be_wrong(self):
        import struct
        # The '<' prefix is not cosmetic: native alignment pads the frame to 36
        # bytes and every other implementation would reject it.
        self.assertEqual(struct.calcsize("@IHhHHHHIQI"), 36)

    def test_magic_wire_bytes(self):
        self.assertEqual(p.UPLINK_MAGIC.to_bytes(4, "little"), b"RTSO")
        self.assertEqual(p.DOWNLINK_MAGIC.to_bytes(4, "little"), b"1BFF")


class TestChecksum(unittest.TestCase):
    def test_published_reference_vectors(self):
        for data, expect in [(b"", 0x02CC5D05), (b"a", 0x550D7456),
                             (b"abc", 0x32D153FF),
                             (b"Nobody inspects the spammish repetition", 0xE2293B2F)]:
            with self.subTest(data=data):
                self.assertEqual(p.xxh32(data, 0), expect)

    def test_known_answer_tests(self):
        for kat in load_golden()["xxh32_28"]:
            with self.subTest(name=kat["name"]):
                data = unhex(kat["data_hex"])
                self.assertEqual(len(data), 28)
                self.assertEqual(p.xxh32_28(data), int(kat["expect"], 16))

    def test_short_input_rejected(self):
        with self.assertRaises(ValueError):
            p.xxh32_28(bytes(27))


class TestFraming(unittest.TestCase):
    def test_golden_uplink_round_trip(self):
        for v in load_golden()["uplink"]:
            with self.subTest(name=v["name"]):
                raw = unhex(v["hex"])
                verdict, fields = p.validate_uplink(raw)
                self.assertIs(verdict, p.Verdict.OK)
                f = v["fields"]
                self.assertEqual(fields[1], f["seq"] & 0xFFFF)
                self.assertEqual(fields[2], f["steer"])
                self.assertEqual(fields[3], f["throttle"])
                self.assertEqual(fields[4], f["brake"])
                self.assertEqual(fields[5], f["clutch"])
                self.assertEqual(fields[6], 0)
                self.assertEqual(fields[7], f["buttons"])
                self.assertEqual(fields[8], f["ts_ns"])

    def test_golden_downlink_bytes(self):
        for v in load_golden()["downlink"]:
            with self.subTest(name=v["name"]):
                self.assertEqual(p.pack_downlink(**v["fields"]), unhex(v["hex"]))

    def test_reject_matrix(self):
        for case in load_golden()["reject"]:
            with self.subTest(name=case["name"]):
                verdict, _ = p.validate_uplink(unhex(case["hex"]))
                self.assertEqual(verdict.value, case["verdict"])

    def test_sender_never_emits_int16_min(self):
        raw = p.pack_uplink(seq=0, steer=-32768, throttle=0, brake=0, clutch=0,
                            buttons=0, ts_ns=0)
        self.assertEqual(p.UPLINK.unpack_from(raw, 0)[2], -32767)


class TestSequence(unittest.TestCase):
    def test_golden_wrap_table(self):
        for row in load_golden()["seq_wrap"]:
            with self.subTest(seq=row["seq"], last=row["last_seq"]):
                d = p.seq_delta(row["seq"], row["last_seq"])
                self.assertEqual(d, row["delta"])
                self.assertEqual(d > 0, row["newer"])

    def test_wrap_is_symmetric_around_the_window(self):
        self.assertGreater(p.seq_delta(32767, 0), 0)
        self.assertLess(p.seq_delta(32768, 0), 0)


class TestTwistMath(unittest.TestCase):
    def test_golden_twist_vectors(self):
        for v in load_golden()["twist"]:
            with self.subTest(name=v["name"]):
                theta = t.twist_deg(tuple(v["q_ref"]), tuple(v["q_cur"]))
                self.assertAlmostEqual(theta, v["theta_deg"], places=9)
                norm = t.steer_norm(theta, v["dor_deg"], v["deadband"], v["gamma"])
                self.assertEqual(t.steer_i16(norm), v["steer_i16"])

    def test_tilt_alone_produces_no_steering(self):
        # The whole reason for twist-swing decomposition: pitching the phone toward
        # or away from the driver must not turn the wheel at all.
        for pitch in (15, 30, 45, 60, 85):
            with self.subTest(pitch=pitch):
                ref = t.rx(pitch)
                cur = t.mul(t.rx(pitch), t.ry(10))
                self.assertAlmostEqual(abs(t.twist_deg(ref, cur)), 0.0, places=9)

    def test_twist_is_invariant_to_how_far_the_phone_is_tilted(self):
        for pitch in (0, 30, 60, 85, 89):
            with self.subTest(pitch=pitch):
                ref = t.rx(pitch)
                cur = t.mul(t.rx(pitch), t.rz(10))
                self.assertAlmostEqual(t.twist_deg(ref, cur), 10.0, places=9)

    def test_banned_planar_projection_is_measurably_wrong(self):
        # Regression guard for invariant I1. If someone ever swaps the shipping math
        # for atan2(gravity.y, gravity.x), these numbers change and this fails.
        ref = t.rx(85)
        twisted = t.mul(t.mul(t.rx(85), t.rz(10)), t.ry(20))
        tilted = t.mul(t.rx(85), t.ry(10))

        self.assertAlmostEqual(t.twist_deg(ref, twisted), 10.0, places=9)
        self.assertAlmostEqual(abs(t.naive_projection_deg(ref, twisted)), 7.705816, places=5)

        self.assertAlmostEqual(t.twist_deg(ref, tilted), 0.0, places=9)
        self.assertAlmostEqual(t.naive_projection_deg(ref, tilted), 0.870385, places=5)

    def test_banned_method_goes_completely_blind_when_flat(self):
        # Phone face-up: gravity has no horizontal component, so the projection sees
        # a real 30 degree turn as exactly zero.
        self.assertAlmostEqual(t.naive_projection_deg(t.IDENTITY, t.rz(30)), 0.0, places=9)
        self.assertAlmostEqual(t.twist_deg(t.IDENTITY, t.rz(30)), 30.0, places=9)

    def test_quaternion_sign_does_not_matter(self):
        ref = t.rx(40)
        cur = t.mul(t.rx(40), t.rz(25))
        flipped = tuple(-c for c in cur)
        self.assertAlmostEqual(t.twist_deg(ref, cur), t.twist_deg(ref, flipped), places=9)

    def test_unwrap_reaches_beyond_half_a_turn(self):
        g = load_golden()["unwrap"]
        u = t.AngleUnwrapper()
        total = 0.0
        for deg in g["sequence_deg"]:
            total = u.step(t.twist_deg(t.IDENTITY, t.rz(deg)))
        self.assertAlmostEqual(total, g["continuous_deg"], places=6)
        self.assertEqual(t.steer_i16(t.steer_norm(total, g["dor_deg"])), g["steer_i16"])

    def test_steer_map_and_shaping(self):
        gold = load_golden()
        for row in gold["steer_map"]:
            with self.subTest(theta=row["theta_cont_deg"]):
                n = t.steer_norm(row["theta_cont_deg"], row["dor_deg"],
                                 row["deadband"], row["gamma"])
                self.assertAlmostEqual(n, row["steer_norm"], places=12)
                self.assertEqual(t.steer_i16(n), row["steer_i16"])
        for row in gold["shape"]:
            with self.subTest(x=row["x"]):
                self.assertAlmostEqual(t.shape(row["x"], row["deadband"], row["gamma"]),
                                       row["y"], places=12)

    def test_deadband_kills_micro_jitter_around_centre(self):
        self.assertEqual(t.shape(0.04, 0.05, 1.2), 0.0)
        self.assertGreater(t.shape(0.06, 0.05, 1.2), 0.0)


class TestWatchdogReference(unittest.TestCase):
    """The golden watchdog curves are consumed by the C# tests; re-derive them here
    so a bad edit to the generator cannot quietly move both sides at once."""

    def test_decay_curve(self):
        w = load_golden()["watchdog"]
        for row in w["decay_from_40000"]:
            s = row["silence_ms"]
            with self.subTest(silence_ms=s):
                if s >= w["t_hard_ms"]:
                    expect = 0
                elif s <= w["t_soft_ms"]:
                    expect = 40000
                else:
                    v = 40000 * math.exp(-(s - w["t_soft_ms"]) / w["tau_ms"])
                    expect = t.round_half_away(v)
                    if expect < w["decay_floor"]:
                        expect = 0
                self.assertEqual(row["value"], expect)

    def test_failsafe_coasts(self):
        fs = load_golden()["watchdog"]["failsafe"]
        self.assertEqual(fs["brake"], 0)
        self.assertEqual(fs["steer"], 0)
        self.assertEqual(fs["throttle"], 0)

    def test_slew_endpoints(self):
        w = load_golden()["watchdog"]
        steer = {r["elapsed_ms"]: r["value"] for r in w["steer_slew_0_to_32767"]}
        pedal = {r["elapsed_ms"]: r["value"] for r in w["pedal_slew_0_to_65535"]}
        self.assertEqual(steer[0], 0)
        self.assertEqual(steer[300], 32767)
        self.assertEqual(steer[297], 32439)   # not 32440: 32767 * 0.99 = 32439.33
        self.assertEqual(pedal[0], 0)
        self.assertEqual(pedal[100], 65535)
        self.assertEqual(pedal[50], 32768)
        # Pedals finish first on purpose, so throttle response returns immediately
        # while the wheel eases back over the remaining 200 ms.
        self.assertLess(w["t_pslew_ms"], w["t_slew_ms"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
