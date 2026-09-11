using OpenSteer.Core.Protocol;

namespace OpenSteer.Server.Output;

/// <summary>
/// A virtual controller backend. Open and Dispose run on the main thread; Update is
/// called by the hot thread and by nothing else, which is why no lock guards it.
/// </summary>
public interface IOutputSink : IDisposable
{
    string Name { get; }

    /// <summary>Returns false with a readable reason rather than throwing, so a
    /// missing or blocked driver degrades instead of killing the daemon.</summary>
    bool Open(out string error);

    void Update(in ControllerState state);
}
