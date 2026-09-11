using System.Runtime.InteropServices;

namespace OpenSteer.Core.Protocol;

/// <summary>
/// Phone -> host control frame. 32 bytes, little-endian, Pack = 1.
/// </summary>
/// <remarks>
/// <see cref="MagicValue"/> is 0x4F535452. Stored little-endian it appears on the
/// wire as bytes 52 54 53 4F, i.e. ASCII "RTSO" in a hex dump. "OSTR" is what the
/// number spells when printed MSB-first, not what is transmitted.
/// <para>
/// TimestampNs sits at offset 20, which is 4-byte but not 8-byte aligned. That is
/// deliberate and legal here: the managed struct is only ever produced by
/// MemoryMarshal.Read into a stack local, never by taking a pointer to the field.
/// </para>
/// </remarks>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
public readonly struct UplinkPacket
{
    public const int Size = 32;
    public const uint MagicValue = 0x4F535452u;

    public readonly uint Magic;
    public readonly ushort Sequence;
    public readonly short Steer;
    public readonly ushort Throttle;
    public readonly ushort Brake;
    public readonly ushort Clutch;
    public readonly ushort Padding;
    public readonly uint ButtonMask;
    public readonly ulong TimestampNs;
    public readonly uint Checksum;

    public UplinkPacket(ushort sequence, short steer, ushort throttle, ushort brake,
                        ushort clutch, uint buttonMask, ulong timestampNs, uint checksum)
    {
        Magic = MagicValue;
        Sequence = sequence;
        Steer = steer;
        Throttle = throttle;
        Brake = brake;
        Clutch = clutch;
        Padding = 0;
        ButtonMask = buttonMask;
        TimestampNs = timestampNs;
        Checksum = checksum;
    }

    public const uint ButtonUpShift = 1u << 0;
    public const uint ButtonDownShift = 1u << 1;
    public const uint ButtonHandbrake = 1u << 2;

    public bool UpShift => (ButtonMask & ButtonUpShift) != 0u;
    public bool DownShift => (ButtonMask & ButtonDownShift) != 0u;
    public bool Handbrake => (ButtonMask & ButtonHandbrake) != 0u;
}
