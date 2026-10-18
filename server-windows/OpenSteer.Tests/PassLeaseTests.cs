using OpenSteer.Core;
using Xunit;

namespace OpenSteer.Tests;

/// <summary>
/// The lease and reseed rules for one burst-drain pass. Each test replays a burst
/// the way the hot loop does: the lease step, then the sequence step against a real
/// PacketValidator.
/// </summary>
public class PassLeaseTests
{
    /// <summary>One packet through steps 5 and 6. Null when step 5 rejects it.</summary>
    private static SequenceVerdict? Step(PassLease pass, PacketValidator validator,
                                         ushort seq, bool sameEndpoint, bool hasHolder,
                                         bool takeoverImmediate = false, bool failSafe = false,
                                         bool longGap = false)
    {
        LeaseVerdict lease = pass.Admit(sameEndpoint, hasHolder, takeoverImmediate, failSafe);

        if (lease == LeaseVerdict.Rejected)
        {
            return null;
        }

        if (pass.ShouldReseed(lease, validator.HasSequence, longGap, failSafe))
        {
            validator.Reseed(seq);
        }

        return validator.CheckSequence(seq, out _);
    }

    [Fact]
    public void ASecondSenderInTheClaimingBurstCannotTakeTheWheel()
    {
        // Nobody holds the wheel. Phone A's packet claims it; a valid packet from C
        // lands later in the same burst. The published lease is still empty until
        // the pass ends, so judging C against it would let C claim too, and the
        // last claimant would win.
        var pass = new PassLease();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Claim, pass.Admit(false, false, false, false));
        Assert.Equal(LeaseVerdict.Rejected, pass.Admit(false, false, false, false));
        Assert.True(pass.Claimed);
    }

    [Fact]
    public void TheClaimantKeepsTheWheelForTheRestOfThePass()
    {
        var pass = new PassLease();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Claim, pass.Admit(false, false, false, false));
        Assert.Equal(LeaseVerdict.Holder, pass.Admit(true, false, false, false));
    }

    [Fact]
    public void TakeoverImmediateStillAllowsOnlyOneClaimPerPass()
    {
        var pass = new PassLease();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Holder, pass.Admit(true, true, true, false));
        Assert.Equal(LeaseVerdict.Claim, pass.Admit(false, true, true, false));
        Assert.Equal(LeaseVerdict.Rejected, pass.Admit(false, true, true, false));
    }

    [Fact]
    public void ALiveHolderIsNotDisplaced()
    {
        var pass = new PassLease();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Rejected, pass.Admit(false, true, false, false));
        Assert.False(pass.Claimed);
    }

    [Fact]
    public void FailSafeLetsANewPhoneClaim()
    {
        var pass = new PassLease();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Claim, pass.Admit(false, true, false, true));
    }

    [Fact]
    public void AnOlderPacketLaterInTheClaimingBurstIsStale()
    {
        // Burst [11, 10] from the phone that claims. Reseeding the second packet
        // too would accept 10 and move the wheel back to an older sample.
        var pass = new PassLease();
        var validator = new PacketValidator();
        pass.Begin();

        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 11, false, false));
        Assert.Equal(SequenceVerdict.Stale, Step(pass, validator, 10, true, false));
    }

    [Fact]
    public void ADuplicateLaterInTheClaimingBurstIsADuplicate()
    {
        var pass = new PassLease();
        var validator = new PacketValidator();
        pass.Begin();

        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 11, false, false));
        Assert.Equal(SequenceVerdict.Duplicate, Step(pass, validator, 11, true, false));
    }

    [Fact]
    public void ALongGapReseedsOncePerPassNotOncePerPacket()
    {
        var pass = new PassLease();
        var validator = new PacketValidator();
        validator.Reseed(100);
        pass.Begin();

        // The phone restarted and came back at 5, well behind 100.
        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 5, true, true, longGap: true));
        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 6, true, true, longGap: true));
        Assert.Equal(SequenceVerdict.Stale, Step(pass, validator, 4, true, true, longGap: true));
    }

    [Fact]
    public void AFailSafePassReseedsOnce()
    {
        var pass = new PassLease();
        var validator = new PacketValidator();
        pass.Begin();

        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 40, false, false, failSafe: true));
        Assert.Equal(SequenceVerdict.Duplicate, Step(pass, validator, 40, true, false, failSafe: true));
    }

    [Fact]
    public void EveryPassStartsClean()
    {
        var pass = new PassLease();
        var validator = new PacketValidator();
        pass.Begin();

        Assert.Equal(LeaseVerdict.Claim, pass.Admit(false, false, false, false));
        Assert.Equal(SequenceVerdict.Accepted, Step(pass, validator, 9, true, false, longGap: true));

        pass.Begin();

        Assert.False(pass.Claimed);
        Assert.True(pass.ShouldReseed(LeaseVerdict.Holder, true, true, false));
    }
}
