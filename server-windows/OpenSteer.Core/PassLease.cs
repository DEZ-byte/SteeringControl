namespace OpenSteer.Core;

/// <summary>What the lease step decided for one valid packet.</summary>
public enum LeaseVerdict : byte
{
    /// <summary>Another endpoint owns the wheel. Counted as other_src and dropped.</summary>
    Rejected = 0,

    /// <summary>From the endpoint that already owns the wheel.</summary>
    Holder,

    /// <summary>Takes the wheel. The lease is published once the pass ends.</summary>
    Claim,
}

/// <summary>
/// The lease and reseed decisions for one burst-drain pass, kept free of sockets so
/// they can be tested (invariant I16). The hot loop answers "is this the same
/// endpoint" and this type decides what the answer means.
/// </summary>
/// <remarks>
/// Two rules, each of which was once broken in the hot loop:
/// <para>
/// Once a packet claims the wheel, the claimant is the authority for the rest of the
/// pass. The published lease is only written after the pass, so it is stale until
/// then, and checking it again let every later packet in the burst claim as well,
/// leaving whichever arrived last in possession.
/// </para>
/// <para>
/// The sequence is reseeded at most once per pass, plus once for each new claim. A
/// reseed accepts whatever sequence it is given, so reseeding every packet in a
/// burst turned off duplicate and out-of-order detection for the whole burst, and an
/// older packet arriving later in it could move the wheel backwards.
/// </para>
/// One instance lives as long as the hot loop and is reset per pass, so nothing here
/// allocates.
/// </remarks>
public sealed class PassLease
{
    private bool _reseeded;

    /// <summary>True once a packet has claimed the wheel in this pass.</summary>
    public bool Claimed { get; private set; }

    public void Begin()
    {
        Claimed = false;
        _reseeded = false;
    }

    /// <param name="sameEndpoint">Before a claim: does the packet come from the
    /// published lease holder. After a claim in this pass: does it come from the
    /// claimant. The caller compares against the right one; see the remarks.</param>
    /// <param name="hasHolder">Whether a lease is currently published.</param>
    /// <param name="takeoverImmediate">The --takeover-immediate flag.</param>
    /// <param name="failSafe">Whether the watchdog is in fail-safe.</param>
    public LeaseVerdict Admit(bool sameEndpoint, bool hasHolder, bool takeoverImmediate,
                              bool failSafe)
    {
        if (sameEndpoint)
        {
            return LeaseVerdict.Holder;
        }

        if (Claimed)
        {
            return LeaseVerdict.Rejected;
        }

        if (!hasHolder || takeoverImmediate || failSafe)
        {
            Claimed = true;
            return LeaseVerdict.Claim;
        }

        return LeaseVerdict.Rejected;
    }

    /// <summary>Whether this accepted-so-far packet must reseed the sequence.</summary>
    /// <param name="verdict">What <see cref="Admit"/> returned for it.</param>
    /// <param name="hasSequence">Whether the validator has a sequence at all.</param>
    /// <param name="longGap">The link was silent long enough that the phone may
    /// have restarted at sequence zero.</param>
    /// <param name="failSafe">Whether the watchdog is in fail-safe.</param>
    public bool ShouldReseed(LeaseVerdict verdict, bool hasSequence, bool longGap,
                             bool failSafe)
    {
        // longGap and failSafe describe the pass, not the packet, so they stay true
        // for every packet in it. They trigger one reseed per pass, not one per packet.
        bool reseed = verdict == LeaseVerdict.Claim
                   || !hasSequence
                   || (!_reseeded && (longGap || failSafe));

        if (reseed)
        {
            _reseeded = true;
        }

        return reseed;
    }
}
