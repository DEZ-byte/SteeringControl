using OpenSteer.Server.Interop;

namespace OpenSteer.Server.Telemetry;

/// <summary>
/// A drift-free periodic wait built on a high-resolution waitable timer.
/// </summary>
/// <remarks>
/// Deliberately not PeriodicTimer or Thread.Sleep. Both quantise to whole
/// milliseconds, so a 60 Hz cadence of 16.667 ms would land on 16 or 17 and walk
/// away from the grid. This schedules each tick against an absolute timeline
/// instead, so a late wake-up does not push every later tick along with it.
/// </remarks>
public sealed class HighResTimer : IDisposable
{
    private readonly nint _handle;
    private readonly double _ticksPerMs;
    private long _nextTick;

    public HighResTimer(long ticksPerSecond)
    {
        _ticksPerMs = ticksPerSecond / 1000.0;
        _handle = Kernel32.CreateWaitableTimerExW(
            nint.Zero, nint.Zero,
            Kernel32.CreateWaitableTimerHighResolution,
            Kernel32.TimerAllAccess);
    }

    /// <summary>False when the OS refused a high-resolution timer, which is the cue
    /// to fall back to a plain sleep rather than to give up.</summary>
    public bool IsHighResolution => _handle != nint.Zero;

    public void Start(long nowTicks) => _nextTick = nowTicks;

    /// <summary>
    /// Waits until the next slot on the grid. Returns the tick the caller should
    /// treat as "now". Slots already in the past are skipped rather than fired in a
    /// burst, so a stall cannot turn into a flood of catch-up frames.
    /// </summary>
    public long WaitNext(long nowTicks, double periodMs)
    {
        long step = (long)(periodMs * _ticksPerMs);
        _nextTick += step;

        if (_nextTick <= nowTicks)
        {
            long behind = (nowTicks - _nextTick) / step + 1;
            _nextTick += behind * step;
        }

        long remaining = _nextTick - nowTicks;

        if (remaining <= 0)
        {
            return nowTicks;
        }

        if (_handle != nint.Zero)
        {
            long due = -(long)(remaining / _ticksPerMs * 10_000.0);   // negative = relative, 100 ns units
            if (Kernel32.SetWaitableTimer(_handle, in due, 0, nint.Zero, nint.Zero, false))
            {
                Kernel32.WaitForSingleObject(_handle, 0xFFFFFFFF);
                return _nextTick;
            }
        }

        Thread.Sleep(Math.Max(1, (int)(remaining / _ticksPerMs)));
        return _nextTick;
    }

    public void Dispose()
    {
        if (_handle != nint.Zero)
        {
            Kernel32.CloseHandle(_handle);
        }
    }
}
