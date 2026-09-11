using System.Buffers.Binary;
using OpenSteer.Core.Protocol;

namespace OpenSteer.Core;

/// <summary>Structural outcome of one received datagram. Exactly one per datagram.</summary>
public enum Verdict : byte
{
    Ok = 0,
    BadLen,
    BadMagic,
    BadCsum,
    BadPad,
}

/// <summary>Sequence-number outcome, evaluated only after the frame is structurally sound.</summary>
public enum SequenceVerdict : byte
{
    Accepted = 0,
    Duplicate,
    Stale,
}

/// <summary>
/// Steps 1-4, 6 and 7 of receive validation. Deliberately socket-free: step 5, the
/// lease/endpoint check, is socket-typed and therefore lives in the Server project.
/// Keeping this class pure is what lets the whole accept/reject matrix be tested
/// with no network, no driver and no Win32.
/// </summary>
public sealed class PacketValidator
{
    private ushort _lastSeq;
    private bool _haveSeq;

    /// <summary>Steps 1-4, in order. Stateless, so it is safe to call from anywhere.</summary>
    public static Verdict CheckFrame(ReadOnlySpan<byte> frame)
    {
        // 1. exact size. The caller receives into an oversized buffer so that an
        //    oversized datagram is observable rather than silently truncated.
        if (frame.Length != UplinkPacket.Size)
        {
            return Verdict.BadLen;
        }

        // 2. magic
        if (BinaryPrimitives.ReadUInt32LittleEndian(frame) != UplinkPacket.MagicValue)
        {
            return Verdict.BadMagic;
        }

        // 3. checksum BEFORE anything reads the sequence number, so a corrupted
        //    sequence can never poison the reseed state.
        uint want = BinaryPrimitives.ReadUInt32LittleEndian(frame.Slice(28, 4));
        if (Xxh32.Hash28(frame) != want)
        {
            return Verdict.BadCsum;
        }

        // 4. reserved padding must be zero
        if (BinaryPrimitives.ReadUInt16LittleEndian(frame.Slice(14, 2)) != 0)
        {
            return Verdict.BadPad;
        }

        return Verdict.Ok;
    }

    /// <summary>
    /// Arms the sequence gate so the next packet is accepted whatever its number.
    /// Called on lease acquisition, endpoint change, fail-safe entry, and after any
    /// silence longer than the soft watchdog threshold (a phone that restarts comes
    /// back at sequence 0).
    /// </summary>
    public void Reseed(ushort nextSeq)
    {
        _lastSeq = unchecked((ushort)(nextSeq - 1));
        _haveSeq = true;
    }

    public void Forget() => _haveSeq = false;

    /// <summary>
    /// int16 wrap-around comparison. Newer wins, equal is a duplicate, older is
    /// stale. The acceptance window is +/-32767 packets, about 4.5 minutes at 120 Hz.
    /// </summary>
    public SequenceVerdict CheckSequence(ushort seq, out int lost)
    {
        lost = 0;

        if (!_haveSeq)
        {
            _lastSeq = seq;
            _haveSeq = true;
            return SequenceVerdict.Accepted;
        }

        int delta = unchecked((short)(seq - _lastSeq));

        if (delta == 0)
        {
            return SequenceVerdict.Duplicate;
        }

        if (delta < 0)
        {
            // Out of order. Packets carry absolute state, so an older one is simply
            // discarded: there is no reassembly and no retransmit. Loss is the
            // watchdog's problem, not the protocol's.
            return SequenceVerdict.Stale;
        }

        lost = delta - 1;
        _lastSeq = seq;
        return SequenceVerdict.Accepted;
    }

    public ushort LastSequence => _lastSeq;

    public bool HasSequence => _haveSeq;
}
