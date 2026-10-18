using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using OpenSteer.Server.Diagnostics;
using OpenSteer.Server.Output;
using OpenSteer.Server.Telemetry;

namespace OpenSteer.Server.Net;

/// <summary>
/// The hot thread. Owns the socket receive side, the validator, the watchdog and the
/// output sink, and is the only thing that touches any of them.
/// </summary>
public sealed class UdpHotLoop
{
    /// <summary>SIO_UDP_CONNRESET. Disabled so an ICMP port-unreachable from a phone
    /// that vanished cannot surface as an exception on a later receive.</summary>
    private const int SioUdpConnReset = unchecked((int)0x9800000C);

    /// <summary>Upper bound on packets absorbed in one pass. Stops a flood from
    /// starving the watchdog; anything left over is taken on the next pass.</summary>
    private const int DrainCap = 64;

    private const int PollLiveUs = 5_000;
    private const int PollIdleUs = 250_000;

    private static readonly double TicksPerUs = Stopwatch.Frequency / 1_000_000.0;

    private readonly Socket _socket;
    private readonly IOutputSink _sink;
    private readonly Watchdog _watchdog;
    private readonly PacketValidator _validator = new();
    private readonly LeaseSlot _lease;
    private readonly HotCounters _counters;
    private readonly LogRing _log;
    private readonly bool _takeoverImmediate;
    private readonly int _traceInject;
    private readonly AllowedSender _sources;

    private readonly byte[] _receiveBuffer = new byte[65536];
    private readonly SocketAddress _from = new(AddressFamily.InterNetwork);

    /// <summary>
    /// The address of the last packet that was actually <b>accepted</b>, which is
    /// not the same thing as the last packet the drain loop touched.
    /// </summary>
    /// <remarks>
    /// <c>_from</c> is overwritten by every datagram, valid or not. Publishing the
    /// lease from it after the loop hands the wheel to whoever sent the final
    /// datagram of the burst, so one stray or malformed packet arriving behind a
    /// real one moves the lease to the wrong endpoint. Every genuine packet after
    /// that counts as other_src and the downlink goes to a machine that is not
    /// driving.
    /// <para>Sized like <c>_from</c>, which it is copied from.</para>
    /// </remarks>
    private readonly SocketAddress _acceptedFrom = new(AddressFamily.InterNetwork);

    /// <summary>The lease and reseed decisions for the pass in progress.</summary>
    private readonly PassLease _pass = new();

    private readonly LatencyHistogram _interArrival = new();
    private readonly LatencyHistogram _pipeline = new();
    private readonly LatencyHistogram _jitter = new();

    private long _lastReceiveTicks;
    private ulong _lastSenderTimestampNs;
    private long _injectCounter;

    public UdpHotLoop(Socket socket, IOutputSink sink, Watchdog watchdog, LeaseSlot lease,
                      HotCounters counters, LogRing log, bool takeoverImmediate, int traceInject,
                      AllowedSender sources)
    {
        _socket = socket;
        _sink = sink;
        _watchdog = watchdog;
        _lease = lease;
        _counters = counters;
        _log = log;
        _takeoverImmediate = takeoverImmediate;
        _traceInject = traceInject;
        _sources = sources;
    }

    /// <summary>Set only in --echo-rtt mode. Assigned after construction because
    /// the sender needs the same socket this loop owns.</summary>
    public DownlinkSender? EchoSender { get; set; }

    /// <summary>Always set. Used to wake the telemetry thread the instant a phone
    /// takes the lease, so force feedback resumes with the first frame.</summary>
    public DownlinkSender? Downlink { get; set; }

    public LatencyHistogram InterArrival => _interArrival;

    public LatencyHistogram Pipeline => _pipeline;

    public LatencyHistogram Jitter => _jitter;

    public WatchdogState State => _watchdog.State;

    public static Socket CreateSocket(IPAddress bind, int port)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
        {
            Blocking = true,
            ReceiveBufferSize = 65536,
            ExclusiveAddressUse = true,
            ReceiveTimeout = 250,
        };

        socket.Bind(new IPEndPoint(bind, port));
        socket.IOControl(SioUdpConnReset, new byte[] { 0, 0, 0, 0 }, null);
        return socket;
    }

    public void Run(CancellationToken cancellation)
    {
        var control = default(ControllerState);

        while (!cancellation.IsCancellationRequested)
        {
            // Outer wait is BLOCKING: the thread sits in select() at 0% CPU until a
            // datagram lands or the timeout expires. This is the invariant that keeps
            // an idle daemon off the CPU entirely.
            int timeoutUs = _watchdog.State is WatchdogState.Live or WatchdogState.Decaying
                                             or WatchdogState.Recovering
                ? PollLiveUs
                : PollIdleUs;

            bool ready = _socket.Poll(timeoutUs, SelectMode.SelectRead);
            long now = Stopwatch.GetTimestamp();
            long passStart = now;

            bool fresh = false;
            int drained = 0;
            _pass.Begin();
            UplinkPacket newest = default;

            // Burst drain. Wi-Fi delivers packets in bunches; replaying a bunch one
            // frame at a time would make the wheel lag behind the hand by the length
            // of the bunch. Instead every packet is validated and counted, but only
            // the newest one is allowed to move the wheel.
            while (ready && drained < DrainCap && !cancellation.IsCancellationRequested)
            {
                int received;

                try
                {
                    received = _socket.ReceiveFrom(_receiveBuffer.AsSpan(), SocketFlags.None, _from);
                }
                catch (SocketException)
                {
                    _counters.SocketErrors++;
                    break;
                }

                drained++;

                if (TryAccept(_receiveBuffer.AsSpan(0, received), now, ref newest))
                {
                    if (fresh)
                    {
                        _counters.Coalesced++;
                    }

                    fresh = true;
                }

                // Non-blocking readiness probe. Not a spin: it returns false the
                // moment the kernel queue is empty and the loop exits back to the
                // blocking wait above.
                ready = _socket.Poll(0, SelectMode.SelectRead);
            }

            if (drained >= DrainCap)
            {
                _counters.DrainCap++;
            }

            if (fresh)
            {
                if (_pass.Claimed)
                {
                    _lease.Publish(_acceptedFrom, now);
                    Downlink?.OnLeaseAcquired();
                }
                else
                {
                    _lease.Touch(now);
                }

                RecordArrival(now, newest.TimestampNs);
                _watchdog.OnPacket(now, in newest);
                EchoSender?.SendEcho(now, newest.TimestampNs);
            }

            // Runs every pass, packet or not: this is what makes the fail-safe fire
            // on silence rather than needing a packet to notice the silence.
            if (_watchdog.Evaluate(now, ref control))
            {
                _sink.Update(in control);
                _pipeline.Record((long)((Stopwatch.GetTimestamp() - passStart) / TicksPerUs));
                TraceInjection(control);
            }

            DrainWatchdogEvents();
        }
    }

    private bool TryAccept(ReadOnlySpan<byte> frame, long now, ref UplinkPacket newest)
    {
        // Steps 1-4: size, magic, checksum, reserved padding.
        Verdict verdict = PacketValidator.CheckFrame(frame);

        if (verdict != Verdict.Ok)
        {
            switch (verdict)
            {
                case Verdict.BadLen: _counters.BadLen++; break;
                case Verdict.BadMagic: _counters.BadMagic++; break;
                case Verdict.BadCsum: _counters.BadCsum++; break;
                case Verdict.BadPad: _counters.BadPad++; break;
            }

            return false;
        }

        // Step 4b: --allow. AllowedSender reads the address out of the raw socket
        // address (layout pinned by AllowedSenderTests against the framework's
        // own). A source that is not allowed can never hold the lease, so it can
        // never become the downlink target either. Counted as other_src: to the
        // driver it is another sender. Without --allow this returns at once.
        if (!_sources.AllowsSocketAddress(_from.Buffer.Span[.._from.Size]))
        {
            _counters.OtherSource++;
            return false;
        }

        // Step 5: the lease. The address comparisons are socket-typed, so they live
        // here; what they mean is decided by PassLease in Core, where it is tested.
        //
        // Once the lease has been claimed earlier in this same pass, the claimant
        // is the authority for the rest of it, not the published lease. The
        // published one is still stale - it is only written after the loop - so
        // checking it again would let every later packet in the burst re-claim
        // from a different address, leaving whichever arrived last in possession.
        //
        // Equals compares the address bytes and allocates nothing. Never ==, which
        // is reference equality on this class.
        bool failSafe = _watchdog.State == WatchdogState.FailSafe;
        bool sameEndpoint = _pass.Claimed
            ? _acceptedFrom.Equals(_from)
            : _lease.Matches(_from);

        LeaseVerdict lease = _pass.Admit(sameEndpoint, _lease.HasPeer, _takeoverImmediate,
                                         failSafe);

        if (lease == LeaseVerdict.Rejected)
        {
            _counters.OtherSource++;
            return false;
        }

        // Step 6: sequence. Reseed whenever continuity cannot be assumed - a new
        // endpoint, a fail-safe, or a gap long enough that the phone may have
        // restarted and come back at sequence zero. The last two describe the
        // pass rather than the packet, so they reseed once per pass, not once per
        // packet: a reseed accepts any sequence, and doing it for every packet in a
        // burst would let an older one later in the burst move the wheel back.
        ushort sequence = BinaryPrimitives.ReadUInt16LittleEndian(frame.Slice(4, 2));

        bool longGap = _lastReceiveTicks != 0
                    && (now - _lastReceiveTicks) / TicksPerUs > Watchdog.SoftMs * 1000.0;

        if (_pass.ShouldReseed(lease, _validator.HasSequence, longGap, failSafe))
        {
            _validator.Reseed(sequence);
            _counters.Reseeds++;
        }

        SequenceVerdict sequenceVerdict = _validator.CheckSequence(sequence, out int lost);

        if (sequenceVerdict == SequenceVerdict.Duplicate)
        {
            _counters.Duplicate++;
            return false;
        }

        if (sequenceVerdict == SequenceVerdict.Stale)
        {
            _counters.Stale++;
            return false;
        }

        _counters.Dropped += lost;
        _counters.Accepted++;

        // A 32-byte copy onto the stack, NOT a reference into the receive buffer:
        // the next iteration of the drain loop overwrites that buffer.
        newest = MemoryMarshal.Read<UplinkPacket>(frame);

        // Same reasoning, one level up: remember where this packet came from while
        // we still know, because _from will not survive the next iteration. Size
        // goes with the bytes so the two compare equal. Allocates nothing.
        _from.Buffer.Span[.._from.Size].CopyTo(_acceptedFrom.Buffer.Span);
        _acceptedFrom.Size = _from.Size;
        return true;
    }

    /// <summary>
    /// Inter-arrival is measured pass to pass rather than packet to packet. Inside a
    /// burst the packets share one timestamp, so per-packet figures would read as
    /// zero and flatter the link; the coalesced counter is what exposes bunching.
    /// </summary>
    private void RecordArrival(long now, ulong senderTimestampNs)
    {
        if (_lastReceiveTicks != 0)
        {
            long deltaUs = (long)((now - _lastReceiveTicks) / TicksPerUs);
            _interArrival.Record(deltaUs);

            // Packet delay variation, RFC 3393 style. Both terms are differences
            // within their own clock, so the unknown offset between the phone's
            // uptime clock and this machine's cancels out. Never subtract the two
            // clocks directly: they share no epoch.
            if (_lastSenderTimestampNs != 0 && senderTimestampNs > _lastSenderTimestampNs)
            {
                long senderDeltaUs = (long)((senderTimestampNs - _lastSenderTimestampNs) / 1000UL);
                _jitter.Record(Math.Abs(deltaUs - senderDeltaUs));
            }
        }

        _lastReceiveTicks = now;
        _lastSenderTimestampNs = senderTimestampNs;
    }

    private void TraceInjection(in ControllerState control)
    {
        if (_traceInject <= 0)
        {
            return;
        }

        _injectCounter++;

        if (_injectCounter % _traceInject != 0)
        {
            return;
        }

        var evt = new LogEvent
        {
            Kind = LogKind.Inject,
            TimestampNs = NowNs(),
            State = control,
        };

        _log.TryPush(in evt);
    }

    private void DrainWatchdogEvents()
    {
        while (_watchdog.TryDequeueEvent(out WatchdogEvent transition))
        {
            var evt = new LogEvent
            {
                Kind = LogKind.Watchdog,
                TimestampNs = NowNs(),
                From = transition.From,
                To = transition.To,
                SilenceUs = transition.SilenceUs,
                SlewUs = transition.SlewUs,
            };

            _log.TryPush(in evt);

            if (transition.To == WatchdogState.FailSafe)
            {
                // The lease goes with it, so a different phone can take over at once
                // instead of waiting out a timeout of its own.
                _lease.Release();
                _validator.Forget();

                var alert = new LogEvent { Kind = LogKind.Alert, TimestampNs = NowNs() };
                _log.TryPush(in alert);
                _watchdog.ClearAlert();
            }
        }
    }

    public static long NowNs() =>
        (long)(Stopwatch.GetTimestamp() * (1_000_000_000.0 / Stopwatch.Frequency));
}
