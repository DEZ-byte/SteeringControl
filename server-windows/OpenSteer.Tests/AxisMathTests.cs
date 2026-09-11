using OpenSteer.Core;
using Xunit;

namespace OpenSteer.Tests;

public class AxisMathTests
{
    [Fact]
    public void SteerSaturatesAwayFromInt16Minimum()
    {
        // Invariant I10: -32768 is never handed to a sink, because negating it
        // overflows and because senders are specified never to emit it.
        Assert.Equal((short)-32767, AxisMath.SaturateSteer(short.MinValue));
        Assert.Equal((short)-32767, AxisMath.SaturateSteer(-32767));
        Assert.Equal((short)0, AxisMath.SaturateSteer(0));
        Assert.Equal((short)32767, AxisMath.SaturateSteer(32767));
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(255, 0)]
    [InlineData(256, 1)]
    [InlineData(32768, 128)]
    [InlineData(65535, 255)]
    public void XInputTriggersAreEightBit(int value, int expected)
    {
        // Mode A loses 8 bits on the pedals by design: that is the XInput contract,
        // and it is exactly why Mode B exists for people who want load-cell feel.
        Assert.Equal((byte)expected, AxisMath.ToXInputTrigger((ushort)value));
    }

    [Theory]
    [InlineData(1, 0)]
    [InlineData(32768, 0x4000)]
    [InlineData(65535, 0x7FFF)]
    public void VJoyScalingUsesTheDeviceReportedRange(int value, int expected)
    {
        // min/max come from GetVJDAxisMin/Max at Open(), never hard-coded: the vJoy
        // docs say 0x1..0x8000 and the shipping driver reports 0x0..0x7FFF.
        Assert.Equal(expected, AxisMath.ScaleToVJoy((ushort)value, 0, 0x7FFF));
    }

    [Fact]
    public void VJoyScalingHitsBothEndpointsExactly()
    {
        Assert.Equal(0, AxisMath.ScaleToVJoy(0, 0, 0x7FFF));
        Assert.Equal(0x7FFF, AxisMath.ScaleToVJoy(65535, 0, 0x7FFF));
        Assert.Equal(1, AxisMath.ScaleToVJoy(0, 1, 0x8000));
        Assert.Equal(0x8000, AxisMath.ScaleToVJoy(65535, 1, 0x8000));
    }

    [Fact]
    public void SteerToUnsignedCentresAtMidScale()
    {
        Assert.Equal((ushort)32768, AxisMath.SteerToUnsigned(0));
        Assert.Equal((ushort)1, AxisMath.SteerToUnsigned(-32767));
        Assert.Equal((ushort)65535, AxisMath.SteerToUnsigned(32767));
    }

    [Theory]
    [InlineData(0.5, 1)]
    [InlineData(-0.5, -1)]
    [InlineData(1.5, 2)]
    [InlineData(-1.5, -2)]
    [InlineData(2.4, 2)]
    public void RoundingIsHalfAwayFromZeroNotBankers(double input, int expected)
    {
        // Must match the Python and Swift references or the golden vectors diverge
        // by one LSB at exactly the midpoints.
        Assert.Equal(expected, AxisMath.RoundHalfAway(input));
    }

    [Fact]
    public void LerpPinsBothEndpoints()
    {
        Assert.Equal(0, AxisMath.Lerp(0, 32767, 0.0));
        Assert.Equal(32767, AxisMath.Lerp(0, 32767, 1.0));
        Assert.Equal(32767, AxisMath.Lerp(0, 32767, 1.5));
        Assert.Equal(0, AxisMath.Lerp(0, 32767, -0.2));
    }
}
