namespace OpenSteer.Core;

/// <summary>
/// Plain 64-bit counters written by the hot thread and read by the 1 Hz stats
/// thread. Not Interlocked: on x64 an aligned 64-bit load or store is atomic, the
/// stats are approximate anyway, and keeping the hot path free of
/// lock-prefixed instructions matters more than a perfectly consistent snapshot.
/// </summary>
public sealed class HotCounters
{
    public long Accepted;
    public long Coalesced;     // valid packets superseded inside one burst drain
    public long DrainCap;      // passes that hit the drain cap and left work queued
    public long Dropped;       // inferred from sequence gaps
    public long Duplicate;
    public long Stale;
    public long BadLen;
    public long BadMagic;
    public long BadCsum;
    public long BadPad;
    public long OtherSource;   // datagram from an endpoint that does not hold the lease
    public long Reseeds;
    public long SocketErrors;
    public long DownlinkSent;

    public Snapshot Read()
    {
        return new Snapshot
        {
            Accepted = Volatile.Read(ref Accepted),
            Coalesced = Volatile.Read(ref Coalesced),
            DrainCap = Volatile.Read(ref DrainCap),
            Dropped = Volatile.Read(ref Dropped),
            Duplicate = Volatile.Read(ref Duplicate),
            Stale = Volatile.Read(ref Stale),
            BadLen = Volatile.Read(ref BadLen),
            BadMagic = Volatile.Read(ref BadMagic),
            BadCsum = Volatile.Read(ref BadCsum),
            BadPad = Volatile.Read(ref BadPad),
            OtherSource = Volatile.Read(ref OtherSource),
            Reseeds = Volatile.Read(ref Reseeds),
            SocketErrors = Volatile.Read(ref SocketErrors),
            DownlinkSent = Volatile.Read(ref DownlinkSent),
        };
    }

    public struct Snapshot
    {
        public long Accepted;
        public long Coalesced;
        public long DrainCap;
        public long Dropped;
        public long Duplicate;
        public long Stale;
        public long BadLen;
        public long BadMagic;
        public long BadCsum;
        public long BadPad;
        public long OtherSource;
        public long Reseeds;
        public long SocketErrors;
        public long DownlinkSent;

        public static Snapshot operator -(Snapshot a, Snapshot b) => new Snapshot
        {
            Accepted = a.Accepted - b.Accepted,
            Coalesced = a.Coalesced - b.Coalesced,
            DrainCap = a.DrainCap - b.DrainCap,
            Dropped = a.Dropped - b.Dropped,
            Duplicate = a.Duplicate - b.Duplicate,
            Stale = a.Stale - b.Stale,
            BadLen = a.BadLen - b.BadLen,
            BadMagic = a.BadMagic - b.BadMagic,
            BadCsum = a.BadCsum - b.BadCsum,
            BadPad = a.BadPad - b.BadPad,
            OtherSource = a.OtherSource - b.OtherSource,
            Reseeds = a.Reseeds - b.Reseeds,
            SocketErrors = a.SocketErrors - b.SocketErrors,
            DownlinkSent = a.DownlinkSent - b.DownlinkSent,
        };
    }
}
