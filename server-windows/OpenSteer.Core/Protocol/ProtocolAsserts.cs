using System.Runtime.CompilerServices;

namespace OpenSteer.Core.Protocol;

/// <summary>
/// Invariant I6, enforced at module load so a layout regression cannot reach the
/// wire. Duplicated as an xunit test so the failure is readable in CI.
/// </summary>
public static class ProtocolAsserts
{
    // CA2255 warns that a module initializer in a library runs at a time the
    // consumer does not control. That is precisely the intent here: if the wire
    // structs ever stop being 32 and 16 bytes, nothing that links this assembly
    // should be able to reach a socket. The check is branch-only and runs once.
#pragma warning disable CA2255
    [ModuleInitializer]
#pragma warning restore CA2255
    internal static void Verify()
    {
        if (!BitConverter.IsLittleEndian)
        {
            throw new PlatformNotSupportedException(
                "OpenSteer assumes a little-endian host; the wire format is little-endian.");
        }

        int uplink = Unsafe.SizeOf<UplinkPacket>();
        if (uplink != UplinkPacket.Size)
        {
            throw new InvalidOperationException(
                $"UplinkPacket is {uplink} bytes, expected {UplinkPacket.Size}. Check StructLayout Pack = 1.");
        }

        int downlink = Unsafe.SizeOf<DownlinkPacket>();
        if (downlink != DownlinkPacket.Size)
        {
            throw new InvalidOperationException(
                $"DownlinkPacket is {downlink} bytes, expected {DownlinkPacket.Size}. Check StructLayout Pack = 1.");
        }
    }
}
