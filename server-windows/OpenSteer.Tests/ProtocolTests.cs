using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using Xunit;

namespace OpenSteer.Tests;

public class ProtocolTests
{
    [Fact]
    public void StructSizesMatchTheWireContract()
    {
        Assert.Equal(32, Unsafe.SizeOf<UplinkPacket>());
        Assert.Equal(16, Unsafe.SizeOf<DownlinkPacket>());
        Assert.Equal(32, Golden.Section("sizes").GetProperty("uplink").GetInt32());
        Assert.Equal(16, Golden.Section("sizes").GetProperty("downlink").GetInt32());
    }

    [Fact]
    public void FieldOffsetsAreExactlyAsSpecified()
    {
        Assert.Equal(0, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Magic)).ToInt32());
        Assert.Equal(4, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Sequence)).ToInt32());
        Assert.Equal(6, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Steer)).ToInt32());
        Assert.Equal(8, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Throttle)).ToInt32());
        Assert.Equal(10, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Brake)).ToInt32());
        Assert.Equal(12, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Clutch)).ToInt32());
        Assert.Equal(14, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Padding)).ToInt32());
        Assert.Equal(16, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.ButtonMask)).ToInt32());
        Assert.Equal(20, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.TimestampNs)).ToInt32());
        Assert.Equal(28, Marshal.OffsetOf<UplinkPacket>(nameof(UplinkPacket.Checksum)).ToInt32());
    }

    [Fact]
    public void MagicIsLittleEndianOnTheWire()
    {
        // The number spells "OSTR" only when printed MSB-first. What is actually
        // transmitted is 52 54 53 4F, which a hex dump shows as "RTSO". Getting this
        // backwards makes two otherwise correct endpoints reject each other's frames.
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(b, UplinkPacket.MagicValue);
        Assert.Equal(new byte[] { 0x52, 0x54, 0x53, 0x4F }, b.ToArray());

        BinaryPrimitives.WriteUInt32LittleEndian(b, DownlinkPacket.MagicValue);
        Assert.Equal(new byte[] { 0x31, 0x42, 0x46, 0x46 }, b.ToArray());

        Assert.Equal("52 54 53 4f",
            Golden.Section("magics").GetProperty("uplink_wire_bytes").GetString());
        Assert.Equal("31 42 46 46",
            Golden.Section("magics").GetProperty("downlink_wire_bytes").GetString());
    }

    [Fact]
    public void ChecksumMatchesEveryKnownAnswerTest()
    {
        foreach (var kat in Golden.Section("xxh32_28").EnumerateArray())
        {
            byte[] data = Golden.Hex(kat.GetProperty("data_hex").GetString()!);
            uint expect = Golden.HexU32(kat.GetProperty("expect").GetString()!);

            Assert.Equal(28, data.Length);
            Assert.Equal(expect, Xxh32.Hash28(data));
        }
    }

    [Fact]
    public void ChecksumSeedAndCoverageAreTheAgreedOnes()
    {
        var c = Golden.Section("checksum");
        Assert.Equal(Xxh32.Seed, Golden.HexU32(c.GetProperty("seed").GetString()!));
        Assert.Equal(Xxh32.CoveredBytes, c.GetProperty("covered_bytes").GetInt32());
    }

    [Fact]
    public void GoldenUplinkFramesDecodeToTheExpectedFields()
    {
        foreach (var v in Golden.Section("uplink").EnumerateArray())
        {
            string name = v.GetProperty("name").GetString()!;
            byte[] raw = Golden.Hex(v.GetProperty("hex").GetString()!);
            var f = v.GetProperty("fields");

            Assert.Equal(32, raw.Length);
            Assert.Equal(Verdict.Ok, PacketValidator.CheckFrame(raw));

            UplinkPacket p = MemoryMarshal.Read<UplinkPacket>(raw);

            Assert.Equal(UplinkPacket.MagicValue, p.Magic);
            Assert.Equal((ushort)f.GetProperty("seq").GetUInt32(), p.Sequence);
            Assert.Equal((short)f.GetProperty("steer").GetInt32(), p.Steer);
            Assert.Equal((ushort)f.GetProperty("throttle").GetUInt32(), p.Throttle);
            Assert.Equal((ushort)f.GetProperty("brake").GetUInt32(), p.Brake);
            Assert.Equal((ushort)f.GetProperty("clutch").GetUInt32(), p.Clutch);
            Assert.Equal(0, p.Padding);
            Assert.Equal(f.GetProperty("buttons").GetUInt32(), p.ButtonMask);
            Assert.Equal(f.GetProperty("ts_ns").GetUInt64(), p.TimestampNs);
            Assert.Equal(Golden.HexU32(v.GetProperty("checksum").GetString()!), p.Checksum);

            Assert.True(p.Steer != short.MinValue, $"{name} carried -32768 on the wire");
        }
    }

    [Fact]
    public void DownlinkEncoderProducesTheGoldenBytes()
    {
        // Hoisted out of the loop: the sender does the same thing on its hot path,
        // where a per-iteration stackalloc would grow the frame without bound.
        Span<byte> tx = stackalloc byte[DownlinkPacket.Size];

        foreach (var v in Golden.Section("downlink").EnumerateArray())
        {
            var f = v.GetProperty("fields");
            byte[] expect = Golden.Hex(v.GetProperty("hex").GetString()!);

            var pkt = new DownlinkPacket(
                (ushort)f.GetProperty("rpm").GetUInt32(),
                f.GetProperty("abs_active").GetInt32() != 0,
                f.GetProperty("tc_active").GetInt32() != 0,
                f.GetProperty("slip").GetSingle());

            MemoryMarshal.Write(tx, in pkt);

            Assert.Equal(expect, tx.ToArray());
        }
    }

    [Fact]
    public void SlipIsSanitisedBeforeItReachesTheWire()
    {
        // A NaN reaching CoreHaptics as an intensity is a crash on the phone, so it
        // is scrubbed at the source rather than trusted downstream.
        Assert.Equal(0f, DownlinkPacket.Sanitize(float.NaN));
        Assert.Equal(0f, DownlinkPacket.Sanitize(float.PositiveInfinity));
        Assert.Equal(0f, DownlinkPacket.Sanitize(float.NegativeInfinity));
        Assert.Equal(0f, DownlinkPacket.Sanitize(-5f));
        Assert.Equal(1f, DownlinkPacket.Sanitize(5f));
        Assert.Equal(0.25f, DownlinkPacket.Sanitize(0.25f));
    }

    [Fact]
    public void MalformedFramesAreRejectedWithTheRightReason()
    {
        foreach (var v in Golden.Section("reject").EnumerateArray())
        {
            string name = v.GetProperty("name").GetString()!;
            byte[] raw = Golden.Hex(v.GetProperty("hex").GetString()!);

            Verdict expect = v.GetProperty("verdict").GetString() switch
            {
                "bad_len" => Verdict.BadLen,
                "bad_magic" => Verdict.BadMagic,
                "bad_csum" => Verdict.BadCsum,
                "bad_pad" => Verdict.BadPad,
                var other => throw new InvalidOperationException($"unknown verdict {other}"),
            };

            Assert.Equal(expect, PacketValidator.CheckFrame(raw));
        }
    }

    [Fact]
    public void SequenceComparisonWrapsThroughInt16()
    {
        foreach (var v in Golden.Section("seq_wrap").EnumerateArray())
        {
            ushort seq = (ushort)v.GetProperty("seq").GetUInt32();
            ushort last = (ushort)v.GetProperty("last_seq").GetUInt32();
            bool newer = v.GetProperty("newer").GetBoolean();

            var validator = new PacketValidator();
            validator.Reseed(unchecked((ushort)(last + 1)));   // makes LastSequence == last
            Assert.Equal(last, validator.LastSequence);

            var verdict = validator.CheckSequence(seq, out int lost);

            Assert.Equal(newer, verdict == SequenceVerdict.Accepted);
            if (newer)
            {
                Assert.Equal(v.GetProperty("delta").GetInt32() - 1, lost);
            }
        }
    }

    [Fact]
    public void GapsAreCountedAndDuplicatesAreNot()
    {
        var v = new PacketValidator();

        Assert.Equal(SequenceVerdict.Accepted, v.CheckSequence(10, out int lost));
        Assert.Equal(0, lost);

        Assert.Equal(SequenceVerdict.Accepted, v.CheckSequence(11, out lost));
        Assert.Equal(0, lost);

        Assert.Equal(SequenceVerdict.Accepted, v.CheckSequence(15, out lost));
        Assert.Equal(3, lost);

        Assert.Equal(SequenceVerdict.Duplicate, v.CheckSequence(15, out lost));
        Assert.Equal(0, lost);

        Assert.Equal(SequenceVerdict.Stale, v.CheckSequence(14, out lost));
        Assert.Equal(0, lost);

        // A phone that restarts comes back at sequence 0. Without a reseed that
        // would look stale forever and the wheel would stay dead.
        Assert.Equal(SequenceVerdict.Stale, v.CheckSequence(0, out _));
        v.Reseed(0);
        Assert.Equal(SequenceVerdict.Accepted, v.CheckSequence(0, out _));
    }
}
