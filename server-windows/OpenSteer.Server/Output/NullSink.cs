using OpenSteer.Core.Protocol;

namespace OpenSteer.Server.Output;

/// <summary>
/// Headless backend for --mode none. Every test that checks decoding, the
/// watchdog, the burst drain or idle CPU runs against this, so those tests need no
/// driver at all and stay runnable on a machine where Memory Integrity blocks one.
/// </summary>
public sealed class NullSink : IOutputSink
{
    public string Name => "none";

    public ControllerState Last { get; private set; }

    public long Updates { get; private set; }

    public bool Open(out string error)
    {
        error = string.Empty;
        return true;
    }

    public void Update(in ControllerState state)
    {
        Last = state;
        Updates++;
    }

    public void Dispose()
    {
    }
}
