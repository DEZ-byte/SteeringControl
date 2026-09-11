using System.Runtime.InteropServices;

namespace OpenSteer.Core.Protocol;

/// <summary>
/// Host -> phone telemetry frame. 16 bytes, little-endian, Pack = 1.
/// Magic 0x46464231 appears on the wire as 31 42 46 46.
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
public readonly struct DownlinkPacket
{
    public const int Size = 16;
    public const uint MagicValue = 0x46464231u;

    public readonly uint Magic;
    public readonly ushort EngineRpm;
    public readonly byte AbsActive;
    public readonly byte TcActive;
    public readonly float TireSlipRatio;
    public readonly uint Reserved;

    public DownlinkPacket(ushort engineRpm, bool absActive, bool tcActive,
                          float tireSlipRatio, uint reserved = 0u)
    {
        Magic = MagicValue;
        EngineRpm = engineRpm;
        AbsActive = absActive ? (byte)1 : (byte)0;
        TcActive = tcActive ? (byte)1 : (byte)0;
        TireSlipRatio = Sanitize(tireSlipRatio);
        Reserved = reserved;
    }

    /// <summary>NaN and infinity become 0; everything else is clamped to [0, 1].</summary>
    public static float Sanitize(float slip)
    {
        if (float.IsNaN(slip) || float.IsInfinity(slip))
        {
            return 0f;
        }

        return slip < 0f ? 0f : (slip > 1f ? 1f : slip);
    }
}
