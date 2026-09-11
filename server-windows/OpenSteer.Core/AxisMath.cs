namespace OpenSteer.Core;

/// <summary>
/// Pure axis arithmetic shared by both output backends and by the watchdog slews.
/// Lives in Core so it is unit-testable with no driver, no socket and no Win32 -
/// which is what lets the Mode B scaling be proven on a machine where Memory
/// Integrity refuses to load the vJoy driver.
/// </summary>
public static class AxisMath
{
    /// <summary>Invariant I10: -32768 never reaches a sink; it saturates to -32767.</summary>
    public static short SaturateSteer(short steer) =>
        steer == short.MinValue ? (short)-32767 : steer;

    /// <summary>Mode A: XInput triggers are 8-bit by design.</summary>
    public static byte ToXInputTrigger(ushort value) => (byte)(value >> 8);

    /// <summary>Steer as an unsigned axis value for vJoy (centre becomes 32768).</summary>
    public static ushort SteerToUnsigned(short steer) => (ushort)(steer + 32768);

    /// <summary>
    /// Mode B: map a 16-bit axis onto the device's own reported range. The range is
    /// read at Open() with GetVJDAxisMin/Max and never hard-coded, because the vJoy
    /// docs and the shipping driver disagree (0x1..0x8000 vs 0x0..0x7FFF).
    /// </summary>
    public static int ScaleToVJoy(ushort value, int min, int max)
    {
        if (max <= min)
        {
            return min;
        }

        return min + (int)(((long)value * (max - min) + 32767L) / 65535L);
    }

    /// <summary>Round half away from zero, matching the Python and Swift references.</summary>
    public static int RoundHalfAway(double v) =>
        v >= 0.0 ? (int)Math.Floor(v + 0.5) : (int)Math.Ceiling(v - 0.5);

    /// <summary>Linear interpolation used by both watchdog slews.</summary>
    public static int Lerp(int from, int to, double alpha)
    {
        if (alpha <= 0.0)
        {
            return from;
        }

        if (alpha >= 1.0)
        {
            return to;
        }

        return RoundHalfAway(from + (to - from) * alpha);
    }

    public static double Clamp01(double v) => v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);

    public static ushort ClampU16(int v) => (ushort)(v < 0 ? 0 : (v > 65535 ? 65535 : v));

    public static short ClampSteer(int v) =>
        (short)(v < -32767 ? -32767 : (v > 32767 ? 32767 : v));
}
