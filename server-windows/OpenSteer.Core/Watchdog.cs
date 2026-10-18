using OpenSteer.Core.Protocol;

namespace OpenSteer.Core;

public enum WatchdogState : byte
{
    Idle = 0,
    Live,
    Decaying,
    FailSafe,
    Recovering,
}

public readonly record struct WatchdogEvent(
    WatchdogState From,
    WatchdogState To,
    long SilenceUs,
    long SlewUs);

/// <summary>
/// Pure state machine: no I/O, no Win32, no clock of its own - the caller injects
/// <c>now</c> as a tick count, so the whole decay curve and both slews are testable
/// against tools/golden_vectors.json with a synthetic clock. See Watchdog and
/// fail-safe in docs/ARCHITECTURE.md.
/// </summary>
/// <remarks>
/// The fail-safe emits <b>brake 0</b>, not 65535. A full brake applied while the
/// link is down destabilizes the tire model and can spin a car mid-corner; coasting
/// with the wheel centered is recoverable. On recovery, steering slews over
/// 300 ms and the pedals over 100 ms, so a returning link never snaps an input.
/// </remarks>
public sealed class Watchdog
{
    public const double SoftMs = 100.0;
    public const double HardMs = 250.0;
    public const double TauMs = 30.0;
    public const double SteerSlewMs = 300.0;
    public const double PedalSlewMs = 100.0;

    /// <summary>Below this the decay snaps to zero (under 1 LSB of an 8-bit trigger).</summary>
    public const int DecayFloor = 257;

    /// <summary>A returning packet this close to the held angle snaps instead of slewing.</summary>
    public const int SnapThreshold = 4096;

    private readonly double _ticksPerMs;

    private WatchdogState _state = WatchdogState.Idle;
    private ControllerState _out;
    private ControllerState _last;

    private long _tLast;
    private long _tRecover;

    private ushort _decayThr0;
    private ushort _decayBrk0;

    private short _slewFromSteer;
    private ushort _slewFromThr;
    private ushort _slewFromBrk;
    private ushort _slewFromClu;

    private bool _hasPending;
    private ControllerState _pending;

    private bool _hasEvent;
    private WatchdogEvent _event;

    public Watchdog(long ticksPerSecond)
    {
        if (ticksPerSecond <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(ticksPerSecond));
        }

        _ticksPerMs = ticksPerSecond / 1000.0;
    }

    public WatchdogState State => _state;

    /// <summary>True once the fail-safe fired and the alert has not been consumed.</summary>
    public bool AlertPending { get; private set; }

    public void ClearAlert() => AlertPending = false;

    public bool TryDequeueEvent(out WatchdogEvent evt)
    {
        evt = _event;
        bool had = _hasEvent;
        _hasEvent = false;
        return had;
    }

    /// <summary>Records the freshest accepted packet of this pass. Does not transition.</summary>
    public void OnPacket(long now, in UplinkPacket pkt)
    {
        _pending.Steer = AxisMath.SaturateSteer(pkt.Steer);
        _pending.Throttle = pkt.Throttle;
        _pending.Brake = pkt.Brake;
        _pending.Clutch = pkt.Clutch;
        _pending.Buttons = pkt.ButtonMask;
        _hasPending = true;
        _tLast = now;
    }

    /// <summary>
    /// Runs on every pass of the hot loop, whether a packet arrived or the blocking
    /// poll timed out. Returns true when <paramref name="output"/> changed and the
    /// sink therefore needs updating.
    /// </summary>
    public bool Evaluate(long now, ref ControllerState output)
    {
        if (_hasPending)
        {
            ApplyPacket(now);
            _hasPending = false;
        }

        ApplyTimeouts(now);
        ComputeOutput(now);

        if (_out.Equals(output))
        {
            return false;
        }

        output = _out;
        return true;
    }

    private double MsSince(long from, long now) => (now - from) / _ticksPerMs;

    private void Transition(WatchdogState to, long silenceUs = 0L, long slewUs = 0L)
    {
        _event = new WatchdogEvent(_state, to, silenceUs, slewUs);
        _hasEvent = true;
        _state = to;
    }

    private void ApplyPacket(long now)
    {
        _last = _pending;

        switch (_state)
        {
            case WatchdogState.Idle:
                Transition(WatchdogState.Live);
                break;

            case WatchdogState.Live:
                break;

            case WatchdogState.Decaying:
                // A short hiccup should not cost a 300 ms slew. When the returning
                // wheel angle is close to the one we held, snap straight back.
                if (Math.Abs(_pending.Steer - _out.Steer) <= SnapThreshold)
                {
                    Transition(WatchdogState.Live);
                }
                else
                {
                    BeginRecovery(now, _out.Steer, _out.Throttle, _out.Brake, _out.Clutch);
                }

                break;

            case WatchdogState.FailSafe:
                // Everything already sits at zero, so both slews start from zero.
                BeginRecovery(now, 0, 0, 0, 0);
                break;

            case WatchdogState.Recovering:
                break;
        }
    }

    private void BeginRecovery(long now, short fromSteer, ushort fromThr,
                               ushort fromBrk, ushort fromClu)
    {
        _tRecover = now;
        _slewFromSteer = fromSteer;
        _slewFromThr = fromThr;
        _slewFromBrk = fromBrk;
        _slewFromClu = fromClu;
        Transition(WatchdogState.Recovering);
    }

    private void ApplyTimeouts(long now)
    {
        if (_state == WatchdogState.Idle || _state == WatchdogState.FailSafe)
        {
            return;
        }

        double s = MsSince(_tLast, now);

        if (s >= HardMs)
        {
            AlertPending = true;
            Transition(WatchdogState.FailSafe, (long)(s * 1000.0));
            return;
        }

        if (s > SoftMs && _state != WatchdogState.Decaying)
        {
            _decayThr0 = _out.Throttle;
            _decayBrk0 = _out.Brake;
            Transition(WatchdogState.Decaying, (long)(s * 1000.0));
        }
    }

    private void ComputeOutput(long now)
    {
        switch (_state)
        {
            case WatchdogState.Idle:
                break;

            case WatchdogState.Live:
                _out = _last;
                break;

            case WatchdogState.Decaying:
            {
                double s = MsSince(_tLast, now);

                // Exponential in elapsed time, so tick jitter cannot bend the curve.
                double f = Math.Exp(-(s - SoftMs) / TauMs);
                _out.Throttle = DecayTo(_decayThr0, f);
                _out.Brake = DecayTo(_decayBrk0, f);

                // Steer is held, not decayed: centering the wheel mid-corner is worse
                // than holding the last known angle for 150 ms.
                _out.Buttons = 0u;   // never let a shift paddle stick
                break;
            }

            case WatchdogState.FailSafe:
                _out = ControllerState.FailSafe;
                break;

            case WatchdogState.Recovering:
            {
                double elapsed = MsSince(_tRecover, now);
                double a = AxisMath.Clamp01(elapsed / SteerSlewMs);
                double b = AxisMath.Clamp01(elapsed / PedalSlewMs);

                _out.Steer = (short)AxisMath.Lerp(_slewFromSteer, _last.Steer, a);
                _out.Throttle = (ushort)AxisMath.Lerp(_slewFromThr, _last.Throttle, b);
                _out.Brake = (ushort)AxisMath.Lerp(_slewFromBrk, _last.Brake, b);
                _out.Clutch = (ushort)AxisMath.Lerp(_slewFromClu, _last.Clutch, b);
                _out.Buttons = _last.Buttons;   // buttons are never slewed

                if (a >= 1.0)
                {
                    Transition(WatchdogState.Live, 0L, (long)(elapsed * 1000.0));
                }

                break;
            }
        }
    }

    private static ushort DecayTo(ushort v0, double factor)
    {
        int v = AxisMath.RoundHalfAway(v0 * factor);
        return v < DecayFloor ? (ushort)0 : (ushort)v;
    }
}
