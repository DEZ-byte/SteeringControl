using OpenSteer.Core;
using OpenSteer.Core.Protocol;

namespace OpenSteer.Server.Diagnostics;

public enum LogKind : byte
{
    Info = 0,
    Watchdog,
    Inject,
    Alert,
    Shm,
    Exit,
}

/// <summary>One diagnostic record. A plain struct so pushing one allocates nothing.</summary>
public struct LogEvent
{
    public LogKind Kind;
    public long TimestampNs;
    public WatchdogState From;
    public WatchdogState To;
    public long SilenceUs;
    public long SlewUs;
    public ControllerState State;
}

/// <summary>
/// Single-producer, single-consumer ring. The hot thread must never format a string
/// or touch the console, so it drops a fixed-size struct in here and the 1 Hz stats
/// thread does all the allocating and printing.
/// </summary>
public sealed class LogRing
{
    private readonly LogEvent[] _buffer;
    private readonly int _mask;
    private long _write;
    private long _read;
    private long _dropped;

    public LogRing(int capacity = 2048)
    {
        if (capacity <= 0 || (capacity & (capacity - 1)) != 0)
        {
            throw new ArgumentException("capacity must be a power of two", nameof(capacity));
        }

        _buffer = new LogEvent[capacity];
        _mask = capacity - 1;
    }

    public long Dropped => Volatile.Read(ref _dropped);

    /// <summary>Hot thread. Never blocks; drops the record if the reader has fallen
    /// behind, because stalling the wheel to keep a log line is the wrong trade.</summary>
    public bool TryPush(in LogEvent evt)
    {
        long write = _write;

        if (write - Volatile.Read(ref _read) >= _buffer.Length)
        {
            _dropped++;
            return false;
        }

        _buffer[write & _mask] = evt;
        Volatile.Write(ref _write, write + 1);
        return true;
    }

    /// <summary>Stats thread.</summary>
    public bool TryPop(out LogEvent evt)
    {
        long read = _read;

        if (read >= Volatile.Read(ref _write))
        {
            evt = default;
            return false;
        }

        evt = _buffer[read & _mask];
        Volatile.Write(ref _read, read + 1);
        return true;
    }
}
