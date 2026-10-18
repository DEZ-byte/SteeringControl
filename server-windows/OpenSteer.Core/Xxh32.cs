using System.Buffers.Binary;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace OpenSteer.Core;

/// <summary>
/// The OpenSteer frame checksum: XXH32 over exactly bytes [0, 28) of the uplink
/// frame, seeded with 0x4F535401 ("OST" + protocol version 1), stored as a
/// little-endian uint32 at offset 28.
/// </summary>
/// <remarks>
/// Fixed at 28 bytes: that is one 16-byte stripe plus three 4-byte lanes and no
/// 1-byte tail, so the implementation is branch-free and allocation-free and
/// is byte-identical in C#, Swift, Python and C++.
/// <para>
/// Chosen over Fletcher-16 because the field is 32 bits wide (Fletcher would waste
/// half of it), Fletcher has no seed for protocol domain separation, and Fletcher
/// cannot tell an all-0x00 run from an all-0xFF run, a corruption pattern that
/// matters for pedal and steering words.
/// </para>
/// </remarks>
public static class Xxh32
{
    private const uint P1 = 0x9E3779B1u;
    private const uint P2 = 0x85EBCA77u;
    private const uint P3 = 0xC2B2AE3Du;
    private const uint P4 = 0x27D4EB2Fu;

    /// <summary>Protocol seed. Verified against tools/golden_vectors.json.</summary>
    public const uint Seed = 0x4F535401u;

    /// <summary>Bytes covered: everything before the checksum field itself.</summary>
    public const int CoveredBytes = 28;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint Round(uint acc, uint lane) =>
        unchecked(BitOperations.RotateLeft(unchecked(acc + lane * P2), 13) * P1);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint Lane(ReadOnlySpan<byte> b, int offset) =>
        BinaryPrimitives.ReadUInt32LittleEndian(b.Slice(offset, 4));

    /// <summary>
    /// Hashes the first 28 bytes of <paramref name="frame"/>. Allocation-free.
    /// </summary>
    public static uint Hash28(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < CoveredBytes)
        {
            throw new ArgumentException(
                $"need at least {CoveredBytes} bytes, got {frame.Length}", nameof(frame));
        }

        unchecked
        {
            uint v1 = Seed + P1 + P2;
            uint v2 = Seed + P2;
            uint v3 = Seed;
            uint v4 = Seed - P1;

            v1 = Round(v1, Lane(frame, 0));
            v2 = Round(v2, Lane(frame, 4));
            v3 = Round(v3, Lane(frame, 8));
            v4 = Round(v4, Lane(frame, 12));

            uint h = BitOperations.RotateLeft(v1, 1)
                   + BitOperations.RotateLeft(v2, 7)
                   + BitOperations.RotateLeft(v3, 12)
                   + BitOperations.RotateLeft(v4, 18);
            h += CoveredBytes;

            for (int i = 16; i < CoveredBytes; i += 4)
            {
                h = BitOperations.RotateLeft(h + Lane(frame, i) * P3, 17) * P4;
            }

            h ^= h >> 15;
            h *= P2;
            h ^= h >> 13;
            h *= P3;
            h ^= h >> 16;
            return h;
        }
    }
}
