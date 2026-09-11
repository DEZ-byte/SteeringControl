using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using Xunit;

namespace OpenSteer.Tests;

/// <summary>
/// The watchdog is the only thing standing between a dropped Wi-Fi frame and a car
/// that will not steer, so every constant here is pinned to a value computed by
/// tools/golden_vectors.py rather than typed in by hand.
/// </summary>
public class WatchdogTests
{
    private const long TicksPerSecond = 1_000_000L;   // synthetic clock: 1 tick = 1 us

    private static long At(double ms) => (long)(ms * 1000.0);

    private static UplinkPacket Pkt(short steer, ushort thr = 0, ushort brk = 0,
                                    ushort clu = 0, uint btn = 0) =>
        new(sequence: 1, steer: steer, throttle: thr, brake: brk, clutch: clu,
            buttonMask: btn, timestampNs: 0UL, checksum: 0U);

    private static (Watchdog wd, ControllerState outState) Live(short steer, ushort thr,
                                                                ushort brk = 0, uint btn = 0)
    {
        var wd = new Watchdog(TicksPerSecond);
        var state = default(ControllerState);
        wd.OnPacket(0, Pkt(steer, thr, brk, 0, btn));
        wd.Evaluate(0, ref state);
        Assert.Equal(WatchdogState.Live, wd.State);
        return (wd, state);
    }

    [Fact]
    public void IdleWritesNothingUntilTheFirstPacket()
    {
        var wd = new Watchdog(TicksPerSecond);
        var state = default(ControllerState);

        Assert.False(wd.Evaluate(At(0), ref state));
        Assert.False(wd.Evaluate(At(500), ref state));
        Assert.Equal(WatchdogState.Idle, wd.State);
    }

    [Fact]
    public void DecayCurveMatchesTheGoldenVectors()
    {
        var (wd, state) = Live(12000, 40000);

        foreach (var point in Golden.Section("watchdog")
                                    .GetProperty("decay_from_40000").EnumerateArray())
        {
            double ms = point.GetProperty("silence_ms").GetDouble();
            int expect = point.GetProperty("value").GetInt32();

            wd.Evaluate(At(ms), ref state);

            Assert.Equal((ushort)expect, state.Throttle);
        }
    }

    [Fact]
    public void SteerIsHeldWhileThePedalsDecay()
    {
        // Centring the wheel mid-corner is worse than holding the last known angle
        // for 150 ms, so only the pedals bleed off during stage one.
        var (wd, state) = Live(12000, 40000, btn: 0x7);

        wd.Evaluate(At(150), ref state);

        Assert.Equal(WatchdogState.Decaying, wd.State);
        Assert.Equal((short)12000, state.Steer);
        Assert.Equal(0u, state.Buttons);    // a shift paddle must never stick
    }

    [Fact]
    public void FailSafeCoastsAndDoesNotBrake()
    {
        // Brake is 0 here, not 65535: a full brake injected mid-corner while the
        // link is down destabilises the tyre model and can spin the car. Coasting
        // is recoverable.
        var (wd, state) = Live(12000, 40000, brk: 30000);

        wd.Evaluate(At(250), ref state);

        Assert.Equal(WatchdogState.FailSafe, wd.State);
        Assert.Equal((short)0, state.Steer);
        Assert.Equal((ushort)0, state.Throttle);
        Assert.Equal((ushort)0, state.Brake);
        Assert.Equal((ushort)0, state.Clutch);
        Assert.Equal(0u, state.Buttons);
        Assert.True(wd.AlertPending);

        var failsafe = Golden.Section("watchdog").GetProperty("failsafe");
        Assert.Equal(0, failsafe.GetProperty("brake").GetInt32());
    }

    [Fact]
    public void FailSafeIsWrittenOnceAndThenHolds()
    {
        var (wd, state) = Live(12000, 40000);

        Assert.True(wd.Evaluate(At(250), ref state));
        Assert.False(wd.Evaluate(At(300), ref state));
        Assert.False(wd.Evaluate(At(5000), ref state));
    }

    [Fact]
    public void SteerSlewMatchesTheGoldenVectors()
    {
        var (wd, state) = Live(12000, 40000);
        wd.Evaluate(At(250), ref state);
        Assert.Equal(WatchdogState.FailSafe, wd.State);

        long recoverStart = At(1000);
        short target = 32767;

        foreach (var point in Golden.Section("watchdog")
                                    .GetProperty("steer_slew_0_to_32767").EnumerateArray())
        {
            double ms = point.GetProperty("elapsed_ms").GetDouble();
            int expect = point.GetProperty("value").GetInt32();

            // Packets keep arriving at 120 Hz through the slew, so the soft timeout
            // never fires; feeding one at each sample point models that.
            long now = recoverStart + At(ms);
            wd.OnPacket(now, Pkt(target, 0));
            wd.Evaluate(now, ref state);

            Assert.Equal((short)expect, state.Steer);
        }

        Assert.Equal(WatchdogState.Live, wd.State);
        Assert.Equal(target, state.Steer);
    }

    [Fact]
    public void PedalSlewMatchesTheGoldenVectorsAndFinishesFirst()
    {
        var (wd, state) = Live(0, 0);
        wd.Evaluate(At(250), ref state);
        Assert.Equal(WatchdogState.FailSafe, wd.State);

        long recoverStart = At(1000);

        foreach (var point in Golden.Section("watchdog")
                                    .GetProperty("pedal_slew_0_to_65535").EnumerateArray())
        {
            double ms = point.GetProperty("elapsed_ms").GetDouble();
            int expect = point.GetProperty("value").GetInt32();

            long now = recoverStart + At(ms);
            wd.OnPacket(now, Pkt(0, 65535));
            wd.Evaluate(now, ref state);

            Assert.Equal((ushort)expect, state.Throttle);
        }

        // Pedals are done at 100 ms while steering has 200 ms left to run, which is
        // the point: throttle response returns immediately, the wheel eases back.
        Assert.Equal((ushort)65535, state.Throttle);
        Assert.Equal(WatchdogState.Recovering, wd.State);
    }

    [Fact]
    public void ButtonsAreNeverSlewed()
    {
        var (wd, state) = Live(0, 0);
        wd.Evaluate(At(250), ref state);

        long now = At(1000);
        wd.OnPacket(now, Pkt(0, 0, 0, 0, btn: 0x5));
        wd.Evaluate(now, ref state);

        // An upshift requested during recovery has to fire on the frame it arrives,
        // not 300 ms later when the slew finishes.
        Assert.Equal(0x5u, state.Buttons);
    }

    [Fact]
    public void ShortHiccupSnapsBackInsteadOfSlewing()
    {
        var (wd, state) = Live(12000, 40000);

        wd.Evaluate(At(150), ref state);
        Assert.Equal(WatchdogState.Decaying, wd.State);

        // Within the snap threshold, so a 300 ms slew would be a pointless penalty.
        wd.OnPacket(At(160), Pkt(12000 + Watchdog.SnapThreshold, 40000));
        wd.Evaluate(At(160), ref state);

        Assert.Equal(WatchdogState.Live, wd.State);
        Assert.Equal((short)(12000 + Watchdog.SnapThreshold), state.Steer);
        Assert.Equal((ushort)40000, state.Throttle);
    }

    [Fact]
    public void LargeJumpAfterAHiccupSlewsFromTheHeldAngle()
    {
        var (wd, state) = Live(0, 0);

        wd.Evaluate(At(150), ref state);
        Assert.Equal(WatchdogState.Decaying, wd.State);

        wd.OnPacket(At(160), Pkt(32767, 0));
        wd.Evaluate(At(160), ref state);

        Assert.Equal(WatchdogState.Recovering, wd.State);
        Assert.Equal((short)0, state.Steer);   // starts from the held value, not the target
    }

    [Fact]
    public void InterruptedSlewFallsBackIntoDecay()
    {
        var (wd, state) = Live(0, 0);
        wd.Evaluate(At(250), ref state);

        long now = At(1000);
        wd.OnPacket(now, Pkt(32767, 65535));
        wd.Evaluate(now, ref state);
        Assert.Equal(WatchdogState.Recovering, wd.State);

        // Link dies again halfway through the slew.
        wd.Evaluate(now + At(150), ref state);
        Assert.Equal(WatchdogState.Decaying, wd.State);
    }

    [Fact]
    public void TransitionsAreReportedOnceEach()
    {
        var (wd, state) = Live(0, 40000);
        Assert.True(wd.TryDequeueEvent(out var first));
        Assert.Equal(WatchdogState.Idle, first.From);
        Assert.Equal(WatchdogState.Live, first.To);

        wd.Evaluate(At(150), ref state);
        Assert.True(wd.TryDequeueEvent(out var soft));
        Assert.Equal(WatchdogState.Decaying, soft.To);
        Assert.InRange(soft.SilenceUs, 100_000L, 160_000L);

        wd.Evaluate(At(260), ref state);
        Assert.True(wd.TryDequeueEvent(out var hard));
        Assert.Equal(WatchdogState.FailSafe, hard.To);
        Assert.InRange(hard.SilenceUs, 250_000L, 262_000L);

        Assert.False(wd.TryDequeueEvent(out _));
    }

    [Fact]
    public void ConstantsMatchTheGoldenVectors()
    {
        var w = Golden.Section("watchdog");
        Assert.Equal(Watchdog.SoftMs, w.GetProperty("t_soft_ms").GetDouble());
        Assert.Equal(Watchdog.HardMs, w.GetProperty("t_hard_ms").GetDouble());
        Assert.Equal(Watchdog.TauMs, w.GetProperty("tau_ms").GetDouble());
        Assert.Equal(Watchdog.SteerSlewMs, w.GetProperty("t_slew_ms").GetDouble());
        Assert.Equal(Watchdog.PedalSlewMs, w.GetProperty("t_pslew_ms").GetDouble());
        Assert.Equal(Watchdog.DecayFloor, w.GetProperty("decay_floor").GetInt32());
    }
}
