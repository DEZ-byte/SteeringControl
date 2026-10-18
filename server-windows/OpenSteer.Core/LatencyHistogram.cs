namespace OpenSteer.Core;

/// <summary>
/// Fixed 1024-bucket histogram, 50 microseconds per bucket, spanning 0 to 51.2 ms.
/// Preallocated so recording a sample on the hot path allocates nothing. Samples
/// beyond the span land in the top bucket, which makes an overflow visible rather
/// than silently clamping a percentile.
/// </summary>
public sealed class LatencyHistogram
{
    public const int BucketCount = 1024;
    public const int BucketUs = 50;

    private readonly long[] _counts = new long[BucketCount];

    public long Overflow { get; private set; }

    public void Record(long microseconds)
    {
        if (microseconds < 0)
        {
            microseconds = 0;
        }

        long bucket = microseconds / BucketUs;

        if (bucket >= BucketCount)
        {
            bucket = BucketCount - 1;
            Overflow++;
        }

        _counts[bucket]++;
    }

    public void CopyTo(long[] destination) => Array.Copy(_counts, destination, BucketCount);

    /// <summary>
    /// Nearest-rank percentile over a snapshot, returned in microseconds as the
    /// upper edge of the containing bucket. Matches the Python tools exactly.
    /// </summary>
    public static long Percentile(long[] counts, double p)
    {
        long total = 0;
        for (int i = 0; i < counts.Length; i++)
        {
            total += counts[i];
        }

        if (total == 0)
        {
            return 0;
        }

        long rank = (long)Math.Ceiling(p * total);
        if (rank < 1)
        {
            rank = 1;
        }

        long seen = 0;
        for (int i = 0; i < counts.Length; i++)
        {
            seen += counts[i];
            if (seen >= rank)
            {
                return (long)(i + 1) * BucketUs;
            }
        }

        return (long)counts.Length * BucketUs;
    }

    /// <summary>Elementwise a - b, for turning cumulative snapshots into a 1 s window.</summary>
    public static void Subtract(long[] a, long[] b, long[] destination)
    {
        for (int i = 0; i < destination.Length; i++)
        {
            destination[i] = a[i] - b[i];
        }
    }
}
