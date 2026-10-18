namespace OpenSteer.Core;

/// <summary>
/// Whether a counter somebody else increments is still moving.
/// </summary>
/// <remarks>
/// Used on Assetto Corsa's physics packet counter, which a paused game leaves
/// frozen. Kept free of shared memory so it can be tested (invariant I16).
/// <para>
/// It has no reset method. The reader closes and re-opens the page once a second
/// while it is frozen, and forgetting the counter on each re-open made the frozen
/// value look brand new every time: live for the length of the window, stale,
/// re-opened, live again, a two-second loop that rumbled the phone at a fixed
/// engine speed for as long as the driver sat in a menu. Keeping the memory across
/// re-opens keeps a frozen page recognizably frozen.
/// </para>
/// </remarks>
public sealed class CounterLiveness
{
    private readonly long _staleAfterTicks;
    private bool _seen;
    private int _last;
    private long _lastChangeTicks;

    /// <param name="staleAfterTicks">How long the counter may stand still before it
    /// counts as frozen, in the caller's clock ticks.</param>
    public CounterLiveness(long staleAfterTicks) => _staleAfterTicks = staleAfterTicks;

    /// <summary>
    /// Records one reading. True if the counter changed on this reading, or within
    /// the window before it. False once it has stood still for longer than that.
    /// </summary>
    public bool Observe(int counter, long nowTicks)
    {
        if (!_seen || counter != _last)
        {
            _seen = true;
            _last = counter;
            _lastChangeTicks = nowTicks;
            return true;
        }

        return nowTicks - _lastChangeTicks <= _staleAfterTicks;
    }
}
