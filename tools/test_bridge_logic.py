"""The ESP32 bridge's pure logic, re-derived from the C++ and checked here.

There is no C++ toolchain on this machine, by the same decision that removed the
Visual Studio build tools from the project, so `bridge-esp32/` cannot be compiled
where it was written. The checksum and the watchdog are the two pieces that must
agree with the Windows daemon to the least significant bit, and both are plain
C++ with no chip headers, so they are transcribed here straight from the source
and run against the same golden fixture the C# and Swift suites use.

This catches a mistyped constant, a swapped term, or a rounding rule that drifted
- the class of mistake a compiler would never have caught anyway. It does not
catch a syntax error; only a real build does that, and `bridge-esp32/test/` holds
a host-compilable version of these same checks for a machine that has one.

Transcribed from:
  bridge-esp32/src/checksum.cpp
  bridge-esp32/src/watchdog.cpp
"""

from __future__ import annotations

import json
import math
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "golden_vectors.json")

M = 0xFFFFFFFF
P1, P2, P3, P4, P5 = 0x9E3779B1, 0x85EBCA77, 0xC2B2AE3D, 0x27D4EB2F, 0x165667B1
SEED = 0x4F535401
COVERED = 28

# src/config.h
SOFT_MS = 100.0
HARD_MS = 250.0
TAU_MS = 30.0
STEER_SLEW_MS = 300.0
PEDAL_SLEW_MS = 100.0
DECAY_FLOOR = 257
SNAP_THRESHOLD = 4096


# ------------------------------------------------------- src/checksum.cpp

def _rotl(x: int, r: int) -> int:
    return ((x << r) | (x >> (32 - r))) & M


def _u32(b: bytes, i: int) -> int:
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)


def _round32(acc: int, lane: int) -> int:
    return (_rotl((acc + (lane * P2 & M)) & M, 13) * P1) & M


def _avalanche(h: int) -> int:
    h ^= h >> 15
    h = (h * P2) & M
    h ^= h >> 13
    h = (h * P3) & M
    h ^= h >> 16
    return h


def xxh32_28(data: bytes) -> int:
    v1 = (SEED + P1 + P2) & M
    v2 = (SEED + P2) & M
    v3 = SEED & M
    v4 = (SEED - P1) & M

    v1 = _round32(v1, _u32(data, 0))
    v2 = _round32(v2, _u32(data, 4))
    v3 = _round32(v3, _u32(data, 8))
    v4 = _round32(v4, _u32(data, 12))

    h = (_rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)) & M
    h = (h + COVERED) & M

    for offset in (16, 20, 24):
        h = (_rotl((h + (_u32(data, offset) * P3 & M)) & M, 17) * P4) & M

    return _avalanche(h)


def xxh32(data: bytes, seed: int) -> int:
    n = len(data)
    i = 0

    if n >= 16:
        v1 = (seed + P1 + P2) & M
        v2 = (seed + P2) & M
        v3 = seed & M
        v4 = (seed - P1) & M
        while i + 16 <= n:
            v1 = _round32(v1, _u32(data, i))
            v2 = _round32(v2, _u32(data, i + 4))
            v3 = _round32(v3, _u32(data, i + 8))
            v4 = _round32(v4, _u32(data, i + 12))
            i += 16
        h = (_rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)) & M
    else:
        h = (seed + P5) & M

    h = (h + n) & M

    while i + 4 <= n:
        h = (_rotl((h + (_u32(data, i) * P3 & M)) & M, 17) * P4) & M
        i += 4
    while i < n:
        h = (_rotl((h + (data[i] * P5 & M)) & M, 11) * P1) & M
        i += 1

    return _avalanche(h)


# ------------------------------------------------------- src/watchdog.cpp

def round_half_away(v: float) -> int:
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def lerp_int(a: int, b: int, alpha: float) -> int:
    if alpha <= 0.0:
        return a
    if alpha >= 1.0:
        return b
    return round_half_away(a + (b - a) * alpha)


def decay_to(v0: int, factor: float) -> int:
    v = round_half_away(v0 * factor)
    return 0 if v < DECAY_FLOOR else v


def decay_value(v0: int, silence_ms: float) -> int:
    """What DECAYING emits after `silence_ms` of no packets."""
    if silence_ms >= HARD_MS:
        return 0
    return decay_to(v0, math.exp(-(silence_ms - SOFT_MS) / TAU_MS))


def seq_delta(seq: int, last_seq: int) -> int:
    d = (seq - last_seq) & 0xFFFF
    return d - 0x10000 if d >= 0x8000 else d


def saturate_steer(steer: int) -> int:
    return -32767 if steer < -32767 else steer


class ChecksumTests(unittest.TestCase):
    """The bridge is the fourth implementation of this checksum."""

    @classmethod
    def setUpClass(cls) -> None:
        with open(FIXTURE, encoding="utf-8") as handle:
            cls.golden = json.load(handle)

    def test_published_reference_vectors(self) -> None:
        # The anchor. Without these, the bridge agreeing with the daemon would
        # only prove they are wrong in the same way.
        for vector in self.golden["xxh32_generic"]:
            data = bytes.fromhex(vector["data_hex"].replace(" ", ""))
            self.assertEqual(xxh32(data, int(vector["seed"], 16)),
                             int(vector["expect"], 16),
                             f"XXH32 of {len(data)} bytes")

    def test_fixed_size_known_answers(self) -> None:
        for vector in self.golden["xxh32_28"]:
            data = bytes.fromhex(vector["data_hex"].replace(" ", ""))
            self.assertEqual(len(data), COVERED, vector["name"])
            self.assertEqual(xxh32_28(data), int(vector["expect"], 16), vector["name"])

    def test_fixed_agrees_with_generic(self) -> None:
        # Two different code paths. If they ever disagree the protocol quietly
        # stops interoperating.
        for vector in self.golden["xxh32_28"]:
            data = bytes.fromhex(vector["data_hex"].replace(" ", ""))
            self.assertEqual(xxh32_28(data), xxh32(data, SEED), vector["name"])

    def test_uplink_frames_checksum_correctly(self) -> None:
        for vector in self.golden["uplink"]:
            frame = bytes.fromhex(vector["hex"].replace(" ", ""))
            self.assertEqual(xxh32_28(frame), int(vector["checksum"], 16), vector["name"])


class WatchdogTests(unittest.TestCase):
    """The coasting fail-safe and the dual slew, checked against the reference curves."""

    @classmethod
    def setUpClass(cls) -> None:
        with open(FIXTURE, encoding="utf-8") as handle:
            cls.golden = json.load(handle)
        cls.wd = cls.golden["watchdog"]

    def test_constants_match_the_daemon(self) -> None:
        self.assertEqual(SOFT_MS, self.wd["t_soft_ms"])
        self.assertEqual(HARD_MS, self.wd["t_hard_ms"])
        self.assertEqual(TAU_MS, self.wd["tau_ms"])
        self.assertEqual(STEER_SLEW_MS, self.wd["t_slew_ms"])
        self.assertEqual(PEDAL_SLEW_MS, self.wd["t_pslew_ms"])
        self.assertEqual(DECAY_FLOOR, self.wd["decay_floor"])

    def test_failsafe_coasts_rather_than_braking(self) -> None:
        # The fail-safe emits brake 0, not 65535, so the car coasts. A full brake
        # injected while the link is down destabilises the tyre model and can spin
        # a car mid-corner.
        failsafe = self.wd["failsafe"]
        self.assertEqual(failsafe["brake"], 0)
        self.assertEqual(failsafe["steer"], 0)
        self.assertEqual(failsafe["throttle"], 0)
        self.assertEqual(failsafe["clutch"], 0)
        self.assertEqual(failsafe["buttons"], 0)

    def test_decay_curve(self) -> None:
        for point in self.wd["decay_from_40000"]:
            self.assertEqual(decay_value(40000, point["silence_ms"]), point["value"],
                             f"silence {point['silence_ms']} ms")

    def test_decay_is_monotone_and_reaches_zero(self) -> None:
        previous = 65535
        for silence in range(100, 251):
            value = decay_value(65535, float(silence))
            self.assertLessEqual(value, previous, f"decay rose at {silence} ms")
            previous = value
        self.assertEqual(decay_value(65535, HARD_MS), 0)

    def test_steer_slew(self) -> None:
        for point in self.wd["steer_slew_0_to_32767"]:
            alpha = clamp01(point["elapsed_ms"] / STEER_SLEW_MS)
            self.assertEqual(lerp_int(0, 32767, alpha), point["value"],
                             f"steer at {point['elapsed_ms']} ms")

    def test_pedal_slew(self) -> None:
        for point in self.wd["pedal_slew_0_to_65535"]:
            alpha = clamp01(point["elapsed_ms"] / PEDAL_SLEW_MS)
            self.assertEqual(lerp_int(0, 65535, alpha), point["value"],
                             f"pedal at {point['elapsed_ms']} ms")

    def test_pedals_finish_long_before_steering(self) -> None:
        # The whole point of two slew times. Throttle response comes back almost
        # at once; only the wheel needs easing.
        self.assertEqual(lerp_int(0, 65535, clamp01(100 / PEDAL_SLEW_MS)), 65535)
        self.assertLess(lerp_int(0, 32767, clamp01(100 / STEER_SLEW_MS)), 32767)

    def test_snap_threshold(self) -> None:
        # A short hiccup must not cost a 300 ms slew.
        self.assertLessEqual(abs(12000 - 15000), SNAP_THRESHOLD)
        self.assertGreater(abs(0 - 32767), SNAP_THRESHOLD)


class WireTests(unittest.TestCase):
    """The two helpers in wire_protocol.h that are easy to get subtly wrong."""

    @classmethod
    def setUpClass(cls) -> None:
        with open(FIXTURE, encoding="utf-8") as handle:
            cls.golden = json.load(handle)

    def test_sequence_wrap_table(self) -> None:
        for case in self.golden["seq_wrap"]:
            delta = seq_delta(case["seq"], case["last_seq"])
            self.assertEqual(delta, case["delta"],
                             f"seq {case['seq']} after {case['last_seq']}")
            self.assertEqual(delta > 0, case["newer"])

    def test_steer_saturation(self) -> None:
        # Invariant I10. -32768 is the one 16-bit value with no positive twin.
        self.assertEqual(saturate_steer(-32768), -32767)
        self.assertEqual(saturate_steer(-32767), -32767)
        self.assertEqual(saturate_steer(0), 0)
        self.assertEqual(saturate_steer(32767), 32767)


if __name__ == "__main__":
    unittest.main()
