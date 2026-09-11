using System.Diagnostics;
using System.IO.MemoryMappedFiles;

namespace OpenSteer.Server.Telemetry;

public enum ShmState : byte
{
    /// <summary>No mapping open. The game is not running, or not yet.</summary>
    None = 0,

    /// <summary>Mapping open and the packet counter is advancing.</summary>
    Attached,

    /// <summary>Mapping open but frozen. The game exited or paused.</summary>
    Stale,
}

/// <summary>One physics sample, already normalised for the wire.</summary>
public readonly record struct AcTelemetry(
    ushort EngineRpm,
    bool AbsActive,
    bool TcActive,
    float TireSlipRatio);

/// <summary>
/// Reads Assetto Corsa's physics page out of shared memory.
/// </summary>
/// <remarks>
/// Offsets are into SPageFilePhysics, which is 4-byte packed and made entirely of
/// 4-byte members, so every field sits where the field order says it does. They were
/// cross-checked against two independent third-party bindings rather than taken from
/// one source.
/// <para>
/// The game writes this page while we read it, with no lock of any kind. The packet
/// counter at offset 0 is used as a seqlock: read it, read the fields, read it again,
/// and retry if it moved. Without that you eventually get an RPM from one frame and a
/// slip value from the next, which shows up as a haptic glitch nobody can reproduce.
/// </para>
/// </remarks>
public sealed class AcSharedMemoryReader : IDisposable
{
    public const string MapName = "Local\\acpmf_physics";

    private const int OffsetPacketId = 0;
    private const int OffsetRpms = 20;
    private const int OffsetWheelSlip = 56;   // four floats, FL FR RL RR
    private const int OffsetTc = 204;
    private const int OffsetAbs = 252;

    /// <summary>Enough to cover every offset we touch, with room to spare.</summary>
    private const int MinimumCapacity = 256;

    private const double ProbeIntervalMs = 1000.0;
    private const double StaleAfterMs = 2000.0;
    private const int MaxSeqlockRetries = 8;

    private static readonly double TicksPerMs = Stopwatch.Frequency / 1000.0;

    private readonly float _slipFull;

    private MemoryMappedFile? _file;
    private MemoryMappedViewAccessor? _view;
    private int _lastPacketId = -1;
    private long _lastChangeTicks;
    private long _lastProbeTicks;
    private bool _loggedMissing;

    public AcSharedMemoryReader(float slipFull) =>
        _slipFull = slipFull <= 0f ? 1f : slipFull;

    public ShmState State { get; private set; } = ShmState.None;

    public long Capacity { get; private set; }

    /// <summary>Set once whenever State changes, so the caller can log the edge.</summary>
    public bool StateChanged { get; private set; }

    public void ClearStateChanged() => StateChanged = false;

    /// <summary>
    /// Reads one sample. Returns false when the game is absent or frozen, in which
    /// case the caller should send zeros rather than the last known values: a stale
    /// RPM rumbling away after the game exits is worse than silence.
    /// </summary>
    public bool TryRead(long nowTicks, out AcTelemetry telemetry)
    {
        telemetry = default;

        if (_view is null)
        {
            Probe(nowTicks);

            if (_view is null)
            {
                return false;
            }
        }

        int packetId = 0;
        int rpms = 0;
        float tc = 0f;
        float abs = 0f;
        float slip = 0f;
        bool consistent = false;

        for (int attempt = 0; attempt < MaxSeqlockRetries; attempt++)
        {
            packetId = _view.ReadInt32(OffsetPacketId);

            rpms = _view.ReadInt32(OffsetRpms);
            tc = _view.ReadSingle(OffsetTc);
            abs = _view.ReadSingle(OffsetAbs);

            slip = 0f;
            for (int wheel = 0; wheel < 4; wheel++)
            {
                float value = Math.Abs(_view.ReadSingle(OffsetWheelSlip + (wheel * 4)));

                if (value > slip)
                {
                    slip = value;
                }
            }

            if (_view.ReadInt32(OffsetPacketId) == packetId)
            {
                consistent = true;
                break;
            }
        }

        if (!consistent)
        {
            // The page is being rewritten faster than we can read it. Skipping one
            // 60 Hz frame is invisible; publishing a torn one is not.
            return false;
        }

        if (packetId != _lastPacketId)
        {
            _lastPacketId = packetId;
            _lastChangeTicks = nowTicks;
            SetState(ShmState.Attached);
        }
        else if (_lastChangeTicks != 0
                 && (nowTicks - _lastChangeTicks) / TicksPerMs > StaleAfterMs)
        {
            // Frozen for longer than the window. The mapping is still closed here,
            // because a game that has exited leaves its section alive for as long
            // as anyone holds a handle to it, and closing is the only way to find
            // out that it is gone. The rate limit in Probe keeps that to once a
            // second, and _lastPacketId now survives the round trip, so this no
            // longer oscillates back to Attached on the way.
            SetState(ShmState.Stale);
            Close();
            return false;
        }

        telemetry = new AcTelemetry(
            EngineRpm: (ushort)Math.Clamp(rpms, 0, 65535),
            AbsActive: abs > 0.5f,
            TcActive: tc > 0.5f,
            TireSlipRatio: Math.Clamp(slip / _slipFull, 0f, 1f));

        return true;
    }

    private void Probe(long nowTicks)
    {
        if (_lastProbeTicks != 0
            && (nowTicks - _lastProbeTicks) / TicksPerMs < ProbeIntervalMs)
        {
            return;
        }

        _lastProbeTicks = nowTicks;

        try
        {
            _file = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read);
            _view = _file.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
            Capacity = _view.Capacity;

            if (Capacity < MinimumCapacity)
            {
                // Something else owns this name, or the layout changed. Reading it
                // would be guesswork, so treat it as absent.
                Close();
                return;
            }

            // Deliberately does NOT reset _lastPacketId or _lastChangeTicks.
            //
            // A paused game leaves its counter frozen. Forgetting the counter here
            // made the very next read see that frozen value as brand new, so the
            // page was declared Attached, held for the two-second staleness window,
            // dropped, re-probed and declared Attached again: a loop that rumbled
            // the phone with a fixed engine speed for as long as the driver sat in
            // a menu. Carrying the counter across means a frozen page stays
            // recognisably frozen however many times it is re-opened.
            //
            // The state is not set here either. Whether this page is live is
            // decided by whether its counter moves, which only TryRead can see.
            _loggedMissing = false;
        }
        catch (FileNotFoundException)
        {
            // The normal idle path: the game simply is not running. Logged once, not
            // once per second.
            if (!_loggedMissing)
            {
                _loggedMissing = true;
            }

            Close();
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
        {
            Close();
        }
    }

    private void SetState(ShmState state)
    {
        if (State != state)
        {
            State = state;
            StateChanged = true;
        }
    }

    private void Close()
    {
        _view?.Dispose();
        _view = null;
        _file?.Dispose();
        _file = null;
        Capacity = 0;

        // Stale is a more precise answer than None and is preserved: None means
        // nothing is publishing, Stale means something is but has stopped moving.
        // The driver's next question differs completely between the two.
        if (State == ShmState.Attached)
        {
            SetState(ShmState.None);
        }
    }

    public void Dispose()
    {
        Close();
        SetState(ShmState.None);
    }
}
