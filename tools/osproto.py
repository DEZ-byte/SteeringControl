"""OpenSteer wire protocol - single source of truth for the Python tools.

Mirrors server-windows/OpenSteer.Core/Protocol/*.cs and
client-ios/Sources/OpenSteerCore/UplinkCodec.swift byte for byte.

Stdlib only, so the xxhash package is not used. The reference implementation
below is checked against the published XXH32 test vectors in golden_vectors.py.
"""

from __future__ import annotations

import struct
from enum import Enum

# ---------------------------------------------------------------- wire layout

# Uplink: uint32 magic, uint16 seq, int16 steer, uint16 thr, brk, clu, pad,
#         uint32 buttons, uint64 ts_ns, uint32 checksum  == 32 bytes
UPLINK = struct.Struct("<IHhHHHHIQI")
# Downlink: uint32 magic, uint16 rpm, uint8 abs, uint8 tc, float32 slip,
#           uint32 reserved                                == 16 bytes
DOWNLINK = struct.Struct("<IHBBfI")

UPLINK_SIZE = 32
DOWNLINK_SIZE = 16

# 0x4F535452 stored little-endian appears on the wire as 52 54 53 4F ("RTSO").
# "OSTR" is what the number spells when printed MSB-first, not what is sent.
UPLINK_MAGIC = 0x4F535452
DOWNLINK_MAGIC = 0x46464231  # wire bytes 31 42 46 46

CHECKSUM_SEED = 0x4F535401  # "OST" + protocol version 0x01
CHECKSUM_COVERED = 28       # bytes [0, 28) - everything before the checksum field

BTN_UPSHIFT = 1 << 0
BTN_DOWNSHIFT = 1 << 1
BTN_HANDBRAKE = 1 << 2

assert UPLINK.size == UPLINK_SIZE, f"uplink struct is {UPLINK.size} B, expected 32"
assert DOWNLINK.size == DOWNLINK_SIZE, f"downlink struct is {DOWNLINK.size} B, expected 16"

# ------------------------------------------------------------------- checksum

_P1 = 0x9E3779B1
_P2 = 0x85EBCA77
_P3 = 0xC2B2AE3D
_P4 = 0x27D4EB2F
_P5 = 0x165667B1
_M = 0xFFFFFFFF


def _rotl(x: int, r: int) -> int:
    return ((x << r) | (x >> (32 - r))) & _M


def xxh32(data: bytes, seed: int = 0) -> int:
    """Generic XXH32 per the official spec. Used to self-check the fixed-size
    variant below against published test vectors."""
    n = len(data)
    i = 0
    if n >= 16:
        v1 = (seed + _P1 + _P2) & _M
        v2 = (seed + _P2) & _M
        v3 = seed & _M
        v4 = (seed - _P1) & _M
        while i + 16 <= n:
            lane = int.from_bytes(data[i:i + 4], "little")
            v1 = (_rotl((v1 + lane * _P2) & _M, 13) * _P1) & _M
            lane = int.from_bytes(data[i + 4:i + 8], "little")
            v2 = (_rotl((v2 + lane * _P2) & _M, 13) * _P1) & _M
            lane = int.from_bytes(data[i + 8:i + 12], "little")
            v3 = (_rotl((v3 + lane * _P2) & _M, 13) * _P1) & _M
            lane = int.from_bytes(data[i + 12:i + 16], "little")
            v4 = (_rotl((v4 + lane * _P2) & _M, 13) * _P1) & _M
            i += 16
        h = (_rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)) & _M
    else:
        h = (seed + _P5) & _M
    h = (h + n) & _M
    while i + 4 <= n:
        lane = int.from_bytes(data[i:i + 4], "little")
        h = (_rotl((h + lane * _P3) & _M, 17) * _P4) & _M
        i += 4
    while i < n:
        h = (_rotl((h + data[i] * _P5) & _M, 11) * _P1) & _M
        i += 1
    h ^= h >> 15
    h = (h * _P2) & _M
    h ^= h >> 13
    h = (h * _P3) & _M
    h ^= h >> 16
    return h


def xxh32_28(data: bytes) -> int:
    """The protocol checksum: XXH32 over exactly bytes [0, 28) with the OpenSteer
    seed. Branch-free in the compiled implementations (one 16-byte stripe plus
    three 4-byte lanes, no 1-byte tail)."""
    if len(data) < CHECKSUM_COVERED:
        raise ValueError(f"need at least {CHECKSUM_COVERED} bytes, got {len(data)}")
    return xxh32(bytes(data[:CHECKSUM_COVERED]), CHECKSUM_SEED)


# -------------------------------------------------------------------- helpers

def sat_steer(steer: int) -> int:
    """Invariant I10: senders never emit -32768; receivers saturate it."""
    return -32767 if steer < -32767 else (32767 if steer > 32767 else steer)


def seq_delta(seq: int, last_seq: int) -> int:
    """int16 wrap-around distance. >0 newer, 0 duplicate, <0 stale."""
    d = (seq - last_seq) & 0xFFFF
    return d - 0x10000 if d >= 0x8000 else d


# ----------------------------------------------------------------- pack/unpack

def pack_uplink(seq: int, steer: int, throttle: int, brake: int, clutch: int,
                buttons: int, ts_ns: int, *, pad: int = 0,
                bad_checksum: bool = False) -> bytes:
    buf = bytearray(UPLINK_SIZE)
    UPLINK.pack_into(buf, 0, UPLINK_MAGIC, seq & 0xFFFF, sat_steer(steer),
                     throttle & 0xFFFF, brake & 0xFFFF, clutch & 0xFFFF,
                     pad & 0xFFFF, buttons & 0xFFFFFFFF, ts_ns & 0xFFFFFFFFFFFFFFFF, 0)
    csum = xxh32_28(buf)
    if bad_checksum:
        csum ^= 0x5A5A5A5A
    struct.pack_into("<I", buf, 28, csum)
    return bytes(buf)


def unpack_uplink(buf: bytes) -> tuple:
    return UPLINK.unpack_from(buf, 0)


def pack_downlink(rpm: int, abs_active: int, tc_active: int, slip: float,
                  reserved: int = 0) -> bytes:
    return DOWNLINK.pack(DOWNLINK_MAGIC, rpm & 0xFFFF, 1 if abs_active else 0,
                         1 if tc_active else 0, float(slip), reserved & 0xFFFFFFFF)


def unpack_downlink(buf: bytes) -> tuple:
    return DOWNLINK.unpack_from(buf, 0)


class Verdict(Enum):
    OK = "ok"
    BAD_LEN = "bad_len"
    BAD_MAGIC = "bad_magic"
    BAD_CSUM = "bad_csum"
    BAD_PAD = "bad_pad"


def validate_uplink(buf: bytes) -> tuple[Verdict, tuple | None]:
    """The daemon's receive validation steps 1-4 (Receive validation in
    docs/ARCHITECTURE.md), in the same order and with the same
    one-counter-per-datagram rule."""
    if len(buf) != UPLINK_SIZE:
        return Verdict.BAD_LEN, None
    fields = UPLINK.unpack_from(buf, 0)
    if fields[0] != UPLINK_MAGIC:
        return Verdict.BAD_MAGIC, None
    if xxh32_28(buf) != fields[9]:
        return Verdict.BAD_CSUM, None
    if fields[6] != 0:
        return Verdict.BAD_PAD, None
    return Verdict.OK, fields
