using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using OpenSteer.Server.Net;

namespace OpenSteer.Server.Telemetry;

/// <summary>
/// The 60 Hz telemetry thread. Reads the game's physics page and returns a 16-byte
/// frame to whichever phone currently holds the lease.
/// </summary>
/// <remarks>
/// It sends on the same socket the hot loop receives on, and it is the only thing in
/// the process that ever calls SendTo. One reader plus one writer on a UDP socket is
/// the supported pattern, the socket is idle over 99% of the time at these rates, and
/// sharing it keeps the phone on a single connected flow: the reply arrives from the
/// port the phone sent to, so no listener and no second firewall rule is needed.
/// <para>
/// Zeros are sent when the game is absent, rather than nothing. That makes the
/// downlink a liveness signal the phone can use to tell "PC is there, no telemetry"
/// apart from "PC is gone". Repeating the last real values instead would leave the
/// phone rumbling at 6000 RPM after the game exited.
/// </para>
/// </remarks>
public sealed class DownlinkSender : IDisposable
{
    public const double PeriodMs = 1000.0 / 60.0;

    /// <summary>Matches the watchdog's hard timeout: once the wheel has given up on a
    /// phone, we stop talking to it too.</summary>
    private const double LeaseLiveMs = 250.0;

    private const double IdlePeriodMs = 250.0;

    private static readonly double TicksPerMs = Stopwatch.Frequency / 1000.0;

    private readonly Socket _socket;
    private readonly LeaseSlot _lease;
    private readonly AcSharedMemoryReader _reader;
    private readonly HotCounters _counters;
    private readonly bool _echoRtt;

    private readonly SocketAddress _destination = new(AddressFamily.InterNetwork);
    private readonly byte[] _scratch = new byte[DownlinkPacket.Size];

    private readonly AutoResetEvent _leaseAcquired = new(false);

    private long _packedTelemetry;

    public DownlinkSender(Socket socket, LeaseSlot lease, AcSharedMemoryReader reader,
                          HotCounters counters, bool echoRtt)
    {
        _socket = socket;
        _lease = lease;
        _reader = reader;
        _counters = counters;
        _echoRtt = echoRtt;
    }

    public ShmState ShmState => _reader.State;

    /// <summary>
    /// Called by the hot thread the moment a phone takes the lease.
    /// </summary>
    /// <remarks>
    /// Without this the sender sits out its idle wait before noticing anyone came
    /// back. Measured: a 600 ms uplink outage produced a 517 ms gap in force
    /// feedback, because the 350 ms the lease was genuinely dead was followed by
    /// up to another idle period of obliviousness. Haptics returning late is worse
    /// than haptics never starting, because the driver has already stopped
    /// trusting the wheel by then.
    /// </remarks>
    public void OnLeaseAcquired() => _leaseAcquired.Set();

    /// <summary>The last frame that read cleanly, so a torn read can repeat it.
    /// Telemetry thread only.</summary>
    private AcTelemetry _lastGood;

    public void Run(CancellationToken cancellation)
    {
        using var timer = new HighResTimer(Stopwatch.Frequency);
        timer.Start(Stopwatch.GetTimestamp());

        while (!cancellation.IsCancellationRequested)
        {
            long now;

            if (_lease.HasPeer)
            {
                now = timer.WaitNext(Stopwatch.GetTimestamp(), PeriodMs);
            }
            else
            {
                // Idle: park on the event with a long timeout rather than spinning a
                // 60 Hz timer at nothing. Costs four wake-ups a second while nobody is
                // connected, and none of the delay when somebody is.
                _leaseAcquired.WaitOne((int)IdlePeriodMs);
                now = Stopwatch.GetTimestamp();
                timer.Start(now);
            }

            if (cancellation.IsCancellationRequested)
            {
                break;
            }

            AcTelemetry telemetry;

            if (_reader.TryRead(now, out AcTelemetry read))
            {
                telemetry = read;
                _lastGood = read;
            }
            else if (_reader.State == ShmState.Attached)
            {
                // A read can fail while the page is healthy: the seqlock retries ran
                // out because the game rewrote the page faster than it could be read.
                // That is one frame out of sixty and repeating the previous one is
                // invisible, where dropping to zeros is a haptic dropout the driver
                // feels as the car briefly losing its engine.
                telemetry = _lastGood;
            }
            else
            {
                // Not Attached means the game is gone or frozen, and here zeros are
                // the honest answer. Repeating the last good frame would leave an
                // engine note rumbling away after the game exited, which is worse
                // than silence because it is indistinguishable from a live one.
                telemetry = default;
                _lastGood = default;
            }

            Volatile.Write(ref _packedTelemetry, Pack(telemetry));

            // In echo mode the hot thread does the sending, one frame per accepted
            // uplink, so that the measured round trip excludes however long a frame
            // would otherwise sit waiting for the next 60 Hz slot.
            if (_echoRtt || !IsLeaseLive(now))
            {
                continue;
            }

            Send(telemetry, reserved: 0u);
        }
    }

    /// <summary>Hot thread, echo mode only. Returns the sender's own timestamp so the
    /// phone can compute a round trip without either clock knowing the other's epoch.</summary>
    public void SendEcho(long nowTicks, ulong senderTimestampNs)
    {
        if (!_echoRtt || !IsLeaseLive(nowTicks))
        {
            return;
        }

        Send(Unpack(Volatile.Read(ref _packedTelemetry)),
             reserved: (uint)(senderTimestampNs & 0xFFFFFFFFUL));
    }

    private bool IsLeaseLive(long nowTicks) =>
        _lease.HasPeer
        && (nowTicks - _lease.LastSeenTicks) / TicksPerMs <= LeaseLiveMs;

    private void Send(in AcTelemetry telemetry, uint reserved)
    {
        if (!_lease.TryCopyTo(_destination))
        {
            return;
        }

        var packet = new DownlinkPacket(
            telemetry.EngineRpm, telemetry.AbsActive, telemetry.TcActive,
            telemetry.TireSlipRatio, reserved);

        Span<byte> frame = _scratch;
        MemoryMarshal.Write(frame, in packet);

        try
        {
            _socket.SendTo(frame, SocketFlags.None, _destination);
            _counters.DownlinkSent++;
        }
        catch (SocketException)
        {
            // A phone that walked away produces an ICMP unreachable. Counted, not
            // fatal: the watchdog is already the authority on whether it is gone.
            _counters.SocketErrors++;
        }
    }

    private static long Pack(in AcTelemetry t) =>
        ((long)t.EngineRpm << 48)
        | ((long)(t.AbsActive ? 1 : 0) << 40)
        | ((long)(t.TcActive ? 1 : 0) << 32)
        | BitConverter.SingleToUInt32Bits(t.TireSlipRatio);

    private static AcTelemetry Unpack(long v) => new(
        (ushort)((v >> 48) & 0xFFFF),
        ((v >> 40) & 0xFF) != 0,
        ((v >> 32) & 0xFF) != 0,
        BitConverter.UInt32BitsToSingle((uint)v));

    public void Dispose()
    {
        _leaseAcquired.Dispose();
        _reader.Dispose();
    }
}
