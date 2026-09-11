"""High-resolution scheduling helpers for the Windows test harnesses.

Python 3.11+ already backs time.sleep with a 100 ns waitable timer on Windows, but
the OS scheduler still rounds a wake-up to the current timer resolution, so the
feeder raises it for the duration of a run and then puts it back.
"""

from __future__ import annotations

import ctypes
import sys
import time

TIMERR_NOERROR = 0


class WinTimerPeriod:
    """Raises the process timer resolution. Always paired, always restored.

    Since Windows 10 2004 this no longer changes the global resolution, only the
    resolution guaranteed to the calling process, which is exactly what we want.
    """

    def __init__(self, period_ms: int = 1) -> None:
        self.period_ms = int(period_ms)
        self._begun = False

    def __enter__(self) -> "WinTimerPeriod":
        if sys.platform == "win32":
            rc = ctypes.windll.winmm.timeBeginPeriod(self.period_ms)
            self._begun = rc == TIMERR_NOERROR
        return self

    def __exit__(self, *exc: object) -> None:
        if self._begun:
            ctypes.windll.winmm.timeEndPeriod(self.period_ms)
            self._begun = False


def sleep_until(deadline_ns: int, spin_margin_ns: int = 1_500_000) -> int:
    """Sleep to just before the deadline, then spin. Returns wake lateness in ns.

    The spin window is deliberately small. Measured on this machine a 2 ms sleep
    lands at p50 2.73 ms / p99 3.16 ms, so 1.5 ms of margin covers the tail without
    burning a core. Pass spin_margin_ns=0 for a pure-sleep, zero-CPU cadence.
    """
    if spin_margin_ns > 0:
        remaining = deadline_ns - time.perf_counter_ns()
        if remaining > spin_margin_ns:
            time.sleep((remaining - spin_margin_ns) / 1e9)
        while time.perf_counter_ns() < deadline_ns:
            pass
    else:
        remaining = deadline_ns - time.perf_counter_ns()
        if remaining > 0:
            time.sleep(remaining / 1e9)

    return time.perf_counter_ns() - deadline_ns


def pct(samples: list[int], p: float) -> int:
    """Nearest-rank percentile. Matches OpenSteer.Core.LatencyHistogram.Percentile."""
    if not samples:
        return 0
    ordered = sorted(samples)
    rank = max(1, min(len(ordered), int(-(-p * len(ordered) // 1))))
    return ordered[rank - 1]


def require_qpc_clock() -> None:
    """The host logs QueryPerformanceCounter timestamps; the tools must share it."""
    if sys.version_info < (3, 13):
        raise SystemExit("Python 3.13+ required (perf_counter/monotonic unified on QPC)")
    impl = time.get_clock_info("monotonic").implementation
    if sys.platform == "win32" and not impl.startswith("QueryPerformanceCounter"):
        raise SystemExit(f"monotonic clock is {impl}, expected QueryPerformanceCounter")
