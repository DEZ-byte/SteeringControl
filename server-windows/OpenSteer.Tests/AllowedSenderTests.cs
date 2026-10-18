using System.Net;
using OpenSteer.Core;
using Xunit;

namespace OpenSteer.Tests;

/// <summary>The <c>--allow</c> rule: one named phone, or anyone when none is named.</summary>
public class AllowedSenderTests
{
    private static readonly byte[] Phone = { 192, 168, 4, 2 };
    private static readonly byte[] Stranger = { 192, 168, 4, 3 };

    /// <summary>The bytes the hot loop hands over: a real socket address, serialised
    /// by the framework exactly as ReceiveFrom fills one in.</summary>
    private static byte[] SocketAddressOf(string ip, int port)
    {
        SocketAddress address = new IPEndPoint(IPAddress.Parse(ip), port).Serialize();
        byte[] bytes = new byte[address.Size];

        for (int i = 0; i < bytes.Length; i++)
        {
            bytes[i] = address[i];
        }

        return bytes;
    }

    [Fact]
    public void WithoutAllowEverySourceMayDrive()
    {
        Assert.False(AllowedSender.Anyone.IsRestricted);
        Assert.True(AllowedSender.Anyone.Allows(Phone));
        Assert.True(AllowedSender.Anyone.Allows(Stranger));
        Assert.True(AllowedSender.Anyone.AllowsSocketAddress(SocketAddressOf("10.0.0.9", 1)));
    }

    [Fact]
    public void WithAllowOnlyTheNamedPhoneMayDrive()
    {
        AllowedSender filter = AllowedSender.Only(Phone);

        Assert.True(filter.IsRestricted);
        Assert.True(filter.Allows(Phone));
        Assert.False(filter.Allows(Stranger));
    }

    [Fact]
    public void ByteOrderMatters()
    {
        // 2.4.168.192 is a different host, not the same one read backwards.
        AllowedSender filter = AllowedSender.Only(Phone);

        Assert.False(filter.Allows(new byte[] { 2, 4, 168, 192 }));
    }

    [Fact]
    public void AnythingButFourBytesIsRefused()
    {
        AllowedSender filter = AllowedSender.Only(Phone);

        Assert.False(filter.Allows(ReadOnlySpan<byte>.Empty));
        Assert.False(filter.Allows(new byte[] { 192, 168, 4, 2, 0 }));
        Assert.Throws<ArgumentException>(() => AllowedSender.Only(new byte[] { 192, 168, 4 }));
    }

    [Fact]
    public void ReadsTheAddressOutOfARealSocketAddress()
    {
        // The hot loop slices the address out of the bytes ReceiveFrom wrote. This
        // pins that layout to the framework's own, port and all, so a wrong offset
        // fails here rather than silently letting everyone, or no one, drive.
        AllowedSender filter = AllowedSender.Only(Phone);

        Assert.True(filter.AllowsSocketAddress(SocketAddressOf("192.168.4.2", 50_000)));
        Assert.True(filter.AllowsSocketAddress(SocketAddressOf("192.168.4.2", 1)));
        Assert.False(filter.AllowsSocketAddress(SocketAddressOf("192.168.4.3", 50_000)));
        Assert.False(filter.AllowsSocketAddress(SocketAddressOf("2.4.168.192", 50_000)));
    }

    [Fact]
    public void ARestrictedFilterRefusesAnythingThatIsNotIPv4()
    {
        AllowedSender filter = AllowedSender.Only(Phone);

        Assert.False(filter.AllowsSocketAddress(SocketAddressOf("::ffff:192.168.4.2", 50_000)));
        Assert.False(filter.AllowsSocketAddress(SocketAddressOf("::1", 50_000)));
        Assert.False(filter.AllowsSocketAddress(new byte[] { 2, 0, 0, 1 }));
    }

    [Theory]
    [InlineData("192.168.4.2")]
    [InlineData("10.0.0.1")]
    [InlineData("127.0.0.1")]
    [InlineData("172.20.10.2")]
    public void ParsesAPlainAddress(string text)
    {
        Assert.True(AllowedSender.TryParse(text, out AllowedSender filter, out string error), error);
        Assert.True(filter.IsRestricted);
        Assert.Equal(text, filter.ToString());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("10.1")]            // the framework reads this as 10.0.0.1
    [InlineData("0x0A000001")]      // and this as 10.0.0.1
    [InlineData("010.0.0.1")]       // leading zero: octal to some parsers, decimal to others
    [InlineData("192.168.4.256")]
    [InlineData("1.2.3.4.5")]
    [InlineData(" 192.168.4.2")]
    [InlineData("192.168.4.2 ")]
    [InlineData("::1")]
    [InlineData("0.0.0.0")]         // unspecified: nothing could ever match it
    [InlineData("0.1.2.3")]
    [InlineData("224.0.0.1")]       // multicast
    [InlineData("255.255.255.255")] // broadcast
    public void RefusesAnythingThatIsNotPlainlyOnePhone(string? text)
    {
        Assert.False(AllowedSender.TryParse(text, out AllowedSender filter, out string error));
        Assert.False(filter.IsRestricted);
        Assert.NotEmpty(error);
    }
}
