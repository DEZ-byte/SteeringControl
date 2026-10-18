namespace OpenSteer.Core;

/// <summary>
/// The optional <c>--allow</c> check: which IPv4 source may drive the wheel at all.
/// </summary>
/// <remarks>
/// The uplink carries a checksum, not a signature. Its seed is public, so anyone who
/// can reach the port can build a frame that passes every check in
/// <see cref="PacketValidator"/>. On a network the driver does not control, naming
/// the phone is the only thing that keeps a stranger's packets off the wheel and
/// keeps the force-feedback downlink, which goes to whoever holds the lease, from
/// being pointed at a third machine.
/// <para>
/// This is a filter, not authentication. A host on the same segment can still forge
/// the phone's address; only a keyed MAC would stop that.
/// </para>
/// Kept free of sockets so it can be tested (invariant I16): the caller hands over
/// raw bytes and this type decides what they mean.
/// </remarks>
public sealed class AllowedSender
{
    /// <summary>AF_INET as Windows stores it in the first two bytes of a sockaddr,
    /// little-endian.</summary>
    private const ushort AddressFamilyInterNetwork = 2;

    private readonly uint _allowed;

    private AllowedSender(bool restricted, uint allowed)
    {
        IsRestricted = restricted;
        _allowed = allowed;
    }

    /// <summary>Accepts every source. What the daemon does without <c>--allow</c>.</summary>
    public static AllowedSender Anyone { get; } = new(false, 0);

    /// <summary>True when only one address may drive.</summary>
    public bool IsRestricted { get; }

    /// <param name="ipv4">The four address bytes in network order, as
    /// <c>IPAddress.GetAddressBytes</c> returns them for an IPv4 address.</param>
    public static AllowedSender Only(ReadOnlySpan<byte> ipv4)
    {
        if (ipv4.Length != 4)
        {
            throw new ArgumentException("an IPv4 address is four bytes", nameof(ipv4));
        }

        return new AllowedSender(true, Pack(ipv4));
    }

    /// <summary>
    /// Parses the <c>--allow</c> argument. Strict: four dotted decimal octets and
    /// nothing else.
    /// </summary>
    /// <remarks>
    /// The framework parser also takes <c>10.1</c> (as 10.0.0.1), <c>0x0A000001</c>
    /// and leading-zero forms. On this flag a typo fails closed: the daemon runs and
    /// nothing can drive, with no hint why. So anything that is not plainly one
    /// phone's address is refused at startup:
    /// shorthand, hex, leading zeros, the unspecified address, broadcast, multicast
    /// and the reserved range above it.
    /// </remarks>
    public static bool TryParse(string? text, out AllowedSender sender, out string error)
    {
        sender = Anyone;
        error = string.Empty;

        string[] parts = (text ?? string.Empty).Split('.');
        Span<byte> octets = stackalloc byte[4];

        if (parts.Length != 4)
        {
            error = "--allow needs the phone's IPv4 address as four numbers, e.g. 192.168.1.10";
            return false;
        }

        for (int i = 0; i < 4; i++)
        {
            string part = parts[i];
            bool digits = part.Length is >= 1 and <= 3
                       && part.All(c => c is >= '0' and <= '9')
                       && (part.Length == 1 || part[0] != '0');

            if (!digits || int.Parse(part, System.Globalization.CultureInfo.InvariantCulture) > 255)
            {
                error = $"--allow: '{text}' is not a plain IPv4 address (four numbers 0-255, no leading zeros)";
                return false;
            }

            octets[i] = (byte)int.Parse(part, System.Globalization.CultureInfo.InvariantCulture);
        }

        uint packed = Pack(octets);

        if (octets[0] == 0 || octets[0] >= 224)
        {
            error = $"--allow: '{text}' cannot be a phone (unspecified, multicast, broadcast or reserved)";
            return false;
        }

        sender = new AllowedSender(true, packed);
        return true;
    }

    /// <summary>Hot thread. Allocates nothing.</summary>
    /// <param name="ipv4">The sender's four address bytes in network order.</param>
    public bool Allows(ReadOnlySpan<byte> ipv4)
    {
        if (!IsRestricted)
        {
            return true;
        }

        return ipv4.Length == 4 && Pack(ipv4) == _allowed;
    }

    /// <summary>
    /// Hot thread. Allocates nothing. Takes the raw bytes of the sender's socket
    /// address as Windows fills them in: family (2 bytes, little-endian), port
    /// (2 bytes, network order), then the IPv4 address (4 bytes, network order).
    /// </summary>
    /// <remarks>
    /// The family is checked rather than assumed, so a socket address that is not
    /// IPv4 can never be read as one. Without a restriction every sender passes.
    /// </remarks>
    public bool AllowsSocketAddress(ReadOnlySpan<byte> socketAddress)
    {
        if (!IsRestricted)
        {
            return true;
        }

        return socketAddress.Length >= 8
            && (socketAddress[0] | socketAddress[1] << 8) == AddressFamilyInterNetwork
            && Allows(socketAddress.Slice(4, 4));
    }

    public override string ToString() =>
        IsRestricted
            ? $"{_allowed >> 24}.{(_allowed >> 16) & 0xFF}.{(_allowed >> 8) & 0xFF}.{_allowed & 0xFF}"
            : "anyone";

    private static uint Pack(ReadOnlySpan<byte> ipv4) =>
        (uint)(ipv4[0] << 24 | ipv4[1] << 16 | ipv4[2] << 8 | ipv4[3]);
}
