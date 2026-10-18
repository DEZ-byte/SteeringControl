using OpenSteer.Core;
using Xunit;

namespace OpenSteer.Tests;

/// <summary>
/// Assetto Corsa's packet counter as the shared-memory reader sees it. Synthetic
/// clock, 1 tick = 1 us, so nothing here sleeps.
/// </summary>
public class CounterLivenessTests
{
    private const long WindowTicks = 2_000_000;   // the reader's 2000 ms

    private static long At(double ms) => (long)(ms * 1000.0);

    [Fact]
    public void AMovingCounterIsLive()
    {
        var live = new CounterLiveness(WindowTicks);

        for (int i = 0; i < 100; i++)
        {
            Assert.True(live.Observe(i, At(i * 16.6)));
        }
    }

    [Fact]
    public void AFrozenCounterGoesStaleOnlyAfterTheWindow()
    {
        var live = new CounterLiveness(WindowTicks);

        Assert.True(live.Observe(7, At(0)));
        Assert.True(live.Observe(7, At(1999)));
        Assert.False(live.Observe(7, At(2001)));
    }

    [Fact]
    public void AFrozenCounterStaysStaleAcrossReopens()
    {
        // The menu loop. The reader closes the page when it goes stale and
        // re-opens it once a second. Each re-open reads the same frozen value, and
        // it must still read as frozen; treating it as new is what made the phone
        // rumble at a fixed engine speed on a two-second cycle.
        var live = new CounterLiveness(WindowTicks);

        Assert.True(live.Observe(7, At(0)));
        Assert.False(live.Observe(7, At(2100)));

        for (int reopen = 1; reopen <= 5; reopen++)
        {
            Assert.False(live.Observe(7, At(2100 + (reopen * 1000))));
        }

        // The game resumes.
        Assert.True(live.Observe(8, At(8000)));
    }

    [Fact]
    public void TheFirstReadingIsLiveWhateverItsValue()
    {
        // The reader once used -1 as "never seen". A real counter of -1 or 0 must
        // not be mistaken for that.
        Assert.True(new CounterLiveness(WindowTicks).Observe(-1, At(0)));
        Assert.True(new CounterLiveness(WindowTicks).Observe(0, At(0)));
    }
}
