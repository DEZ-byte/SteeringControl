"""Reference twist-swing steering math, shared by golden_vectors.py and the tests.

This is the Python twin of client-ios/Sources/OpenSteerCore/{Quat,TwistExtractor,
AngleUnwrapper,SteerMapper}.swift. Invariant I1: the steering angle is the pure
twist about the device +Z (screen normal). Naive atan2(gravity.y, gravity.x) and
planar vector projections are FORBIDDEN and are only computed here to prove, in a
regression test, that the banned method gives a different (wrong) answer.
"""

from __future__ import annotations

import math

Quat = tuple[float, float, float, float]  # (w, x, y, z)

IDENTITY: Quat = (1.0, 0.0, 0.0, 0.0)


def axis_angle(axis: tuple[float, float, float], deg: float) -> Quat:
    ax, ay, az = axis
    n = math.sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / n, ay / n, az / n
    h = math.radians(deg) / 2.0
    s = math.sin(h)
    return (math.cos(h), ax * s, ay * s, az * s)


def rx(deg: float) -> Quat:
    return axis_angle((1, 0, 0), deg)


def ry(deg: float) -> Quat:
    return axis_angle((0, 1, 0), deg)


def rz(deg: float) -> Quat:
    return axis_angle((0, 0, 1), deg)


def mul(a: Quat, b: Quat) -> Quat:
    """Hamilton product (w1,v1) x (w2,v2)."""
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return (
        w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
        w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
        w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
    )


def conj(q: Quat) -> Quat:
    w, x, y, z = q
    return (w, -x, -y, -z)


def rel_wz(q_ref: Quat, q_cur: Quat) -> tuple[float, float]:
    """Only the w and z components of q_rel = conj(q_ref) x q_cur are needed.
    Eight multiply-adds; the x and y components are the discarded swing."""
    wr, xr, yr, zr = q_ref
    wc, xc, yc, zc = q_cur
    w = wr * wc + xr * xc + yr * yc + zr * zc
    z = wr * zc - xr * yc + yr * xc - zr * wc
    return w, z


def twist_deg(q_ref: Quat, q_cur: Quat, prev_deg: float = 0.0) -> float:
    """Wrapped twist angle about the calibration frame's +Z, in degrees."""
    w, z = rel_wz(q_ref, q_cur)
    if (w * w + z * z) < 1e-9:          # swing ~180 deg: twist is undefined, hold
        return prev_deg
    if w < 0.0:                          # q and -q are the same rotation
        w, z = -w, -z
    return math.degrees(2.0 * math.atan2(z, w))


def rotate(q: Quat, v: tuple[float, float, float]) -> tuple[float, float, float]:
    """Active rotation of v by q:  v' = q (0,v) q*."""
    w, x, y, z = q
    vx, vy, vz = v
    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty),
            vy + w * ty + (z * tx - x * tz),
            vz + w * tz + (x * ty - y * tx))


def gravity_in_body(q: Quat) -> tuple[float, float, float]:
    """CoreMotion attitude maps body -> reference, so the reference-frame down
    vector is carried into the body frame by the inverse rotation."""
    return rotate(conj(q), (0.0, 0.0, -1.0))


def naive_projection_deg(q_ref: Quat, q_cur: Quat) -> float:
    """THE BANNED METHOD (invariant I1): atan2(gravity.y, gravity.x) in the device
    frame, differenced against the same quantity at calibration. Present ONLY so a
    regression test can prove the shipping math is not accidentally equal to it."""
    gr = gravity_in_body(q_ref)
    gc = gravity_in_body(q_cur)
    a = math.atan2(gc[1], gc[0]) - math.atan2(gr[1], gr[0])
    while a > math.pi:
        a -= 2.0 * math.pi
    while a < -math.pi:
        a += 2.0 * math.pi
    return math.degrees(a)


class AngleUnwrapper:
    """Accumulates wrapped twist into a continuous angle so DOR 540/900 work."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._prev: float | None = None
        self.total = 0.0

    def step(self, deg: float) -> float:
        if self._prev is None:
            self._prev = deg
            self.total = deg
            return self.total
        d = deg - self._prev
        while d > 180.0:
            d -= 360.0
        while d < -180.0:
            d += 360.0
        self.total += d
        self._prev = deg
        return self.total


def round_half_away(v: float) -> int:
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


def shape(x: float, deadband: float = 0.0, gamma: float = 1.0) -> float:
    """f(x) = sign(x) * max(0, (|x| - d) / (1 - d)) ** gamma"""
    s = -1.0 if x < 0 else 1.0
    a = abs(x)
    if deadband > 0.0:
        a = max(0.0, (a - deadband) / (1.0 - deadband))
    return s * (a ** gamma)


def steer_norm(theta_cont_deg: float, dor_deg: float,
               deadband: float = 0.0, gamma: float = 1.0) -> float:
    """Positive Steer = clockwise as seen by the driver = negative theta."""
    x = -theta_cont_deg / (dor_deg / 2.0)
    x = max(-1.0, min(1.0, x))
    return shape(x, deadband, gamma)


def steer_i16(norm: float) -> int:
    """Invariant I10: never emit -32768."""
    v = round_half_away(norm * 32767.0)
    return max(-32767, min(32767, v))
