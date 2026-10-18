using System.Net;

namespace OpenSteer.Server.Net;

/// <summary>
/// Which phone currently owns the wheel. One driver at a time: a second device, or a
/// stray test harness, must not be able to steer mid-race just by sending packets.
/// </summary>
/// <remarks>
/// The hot thread is the only writer, so it compares without taking the lock. The
/// lock exists only so the telemetry thread can copy the address out consistently
/// while the hot thread is replacing it.
/// </remarks>
public sealed class LeaseSlot
{
    private readonly object _gate = new();
    private readonly byte[] _bytes = new byte[64];
    private int _size;
    private long _lastSeenTicks;

    public bool HasPeer { get; private set; }

    /// <summary>Hot thread only. Byte comparison, never SocketAddress ==, which is
    /// reference equality and would reject every packet.</summary>
    public bool Matches(SocketAddress address)
    {
        if (!HasPeer || address.Size != _size)
        {
            return false;
        }

        for (int i = 0; i < _size; i++)
        {
            if (_bytes[i] != address[i])
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Hot thread only.</summary>
    public void Publish(SocketAddress address, long nowTicks)
    {
        lock (_gate)
        {
            int size = Math.Min(address.Size, _bytes.Length);

            for (int i = 0; i < size; i++)
            {
                _bytes[i] = address[i];
            }

            _size = size;
            HasPeer = true;
        }

        Volatile.Write(ref _lastSeenTicks, nowTicks);
    }

    public void Touch(long nowTicks) => Volatile.Write(ref _lastSeenTicks, nowTicks);

    public long LastSeenTicks => Volatile.Read(ref _lastSeenTicks);

    /// <summary>Released when the watchdog gives up, so a different phone can take
    /// over without waiting for a timeout of its own.</summary>
    public void Release()
    {
        lock (_gate)
        {
            HasPeer = false;
            _size = 0;
        }
    }

    /// <summary>Telemetry thread. Copies into a preallocated SocketAddress.</summary>
    public bool TryCopyTo(SocketAddress destination)
    {
        lock (_gate)
        {
            if (!HasPeer || _size == 0 || destination.Size < _size)
            {
                return false;
            }

            for (int i = 0; i < _size; i++)
            {
                destination[i] = _bytes[i];
            }

            return true;
        }
    }

    /// <summary>Human-readable, for the 1 Hz stats line. Allocates; never call it
    /// from the hot path.</summary>
    public string Describe()
    {
        lock (_gate)
        {
            if (!HasPeer || _size < 8)
            {
                return "null";
            }

            int port = (_bytes[2] << 8) | _bytes[3];
            return $"{_bytes[4]}.{_bytes[5]}.{_bytes[6]}.{_bytes[7]}:{port}";
        }
    }
}
