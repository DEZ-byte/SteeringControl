namespace OpenSteer.Core.Protocol;

/// <summary>
/// The post-watchdog, pre-driver-scaling value that gets injected. Mode A and Mode B
/// both consume exactly this, which is why the INJ diagnostic trace is identical
/// whichever backend is loaded.
/// </summary>
public struct ControllerState : IEquatable<ControllerState>
{
    public short Steer;
    public ushort Throttle;
    public ushort Brake;
    public ushort Clutch;
    public uint Buttons;

    /// <summary>
    /// The fail-safe coasts. Brake is 0, NOT 65535. Injecting a full brake while the
    /// link is down destabilises the tyre model and can spin a car mid-corner;
    /// coasting with the wheel centred is recoverable.
    /// </summary>
    public static readonly ControllerState FailSafe = default;

    public bool Equals(ControllerState other) =>
        Steer == other.Steer && Throttle == other.Throttle && Brake == other.Brake
        && Clutch == other.Clutch && Buttons == other.Buttons;

    public override bool Equals(object? obj) => obj is ControllerState o && Equals(o);

    public override int GetHashCode() => HashCode.Combine(Steer, Throttle, Brake, Clutch, Buttons);

    public static bool operator ==(ControllerState a, ControllerState b) => a.Equals(b);

    public static bool operator !=(ControllerState a, ControllerState b) => !a.Equals(b);

    public override string ToString() =>
        $"steer={Steer} thr={Throttle} brk={Brake} clu={Clutch} btn=0x{Buttons:X8}";
}
