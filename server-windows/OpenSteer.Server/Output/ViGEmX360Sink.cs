using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using OpenSteer.Server.Interop;

namespace OpenSteer.Server.Output;

/// <summary>
/// Mode A: an emulated Xbox 360 pad on ViGEmBus. The default backend.
/// </summary>
/// <remarks>
/// The pedals lose eight bits here because XInput triggers are bytes. That is the
/// XInput contract, not a shortcut, and it is the reason Mode B exists for people
/// who want load-cell resolution. Steering keeps its full 16 bits on the left stick.
/// <para>
/// When reading joy.cpl, note that DirectInput combines the two triggers
/// onto a single axis, one pushing it positive and the other negative. So throttle
/// and brake move the same Z axis in opposite directions there, and a centered Z means
/// both are released. Independent trigger values are only visible through XInput.
/// </para>
/// </remarks>
public sealed class ViGEmX360Sink : IOutputSink
{
    private readonly bool _clutchOnRightStick;

    private nint _client;
    private nint _target;
    private bool _added;

    public ViGEmX360Sink(bool clutchOnRightStick = false) =>
        _clutchOnRightStick = clutchOnRightStick;

    public string Name => "ViGEm Xbox 360";

    public bool Open(out string error)
    {
        ViGEmNative.InstallResolver();

        try
        {
            _client = ViGEmNative.vigem_alloc();
        }
        catch (DllNotFoundException)
        {
            // The resolver loads it from beside the exe or not at all, so this is
            // the only place a missing or unloadable DLL surfaces.
            error = "ViGEmClient.dll is missing beside the executable or failed to load. "
                  + "It ships in third_party/vigem; rebuild or republish so it is copied there.";
            return false;
        }

        if (_client == nint.Zero)
        {
            error = "vigem_alloc returned null (out of memory)";
            return false;
        }

        uint rc = ViGEmNative.vigem_connect(_client);
        if (rc != ViGEmNative.ErrorNone)
        {
            error = ViGEmNative.Describe(rc);
            Dispose();
            return false;
        }

        _target = ViGEmNative.vigem_target_x360_alloc();
        if (_target == nint.Zero)
        {
            error = "vigem_target_x360_alloc returned null";
            Dispose();
            return false;
        }

        rc = ViGEmNative.vigem_target_add(_client, _target);
        if (rc != ViGEmNative.ErrorNone)
        {
            error = ViGEmNative.Describe(rc);
            Dispose();
            return false;
        }

        _added = true;
        WarmUp();
        error = string.Empty;
        return true;
    }

    /// <summary>
    /// Pushes neutral reports before the first real packet arrives.
    /// </summary>
    /// <remarks>
    /// Measured over a 150 second soak: without this, the first one-second window
    /// showed a receive-to-inject p99 of 3200 us while all 149 later windows sat at
    /// or under 300 us. The cost lands on the first input the driver sees. Paying it
    /// here takes about 25 ms of startup and gets both the driver IOCTL path and the
    /// tiered JIT hot before anyone is steering.
    /// </remarks>
    private void WarmUp()
    {
        var neutral = default(XusbReport);

        for (int i = 0; i < 256; i++)
        {
            ViGEmNative.vigem_target_x360_update(_client, _target, neutral);
        }
    }

    public bool IsAttached => _added && ViGEmNative.vigem_target_is_attached(_target);

    /// <summary>Called only by the hot thread. Allocation-free: the report is a
    /// 12-byte blittable struct built on the stack and passed by value.</summary>
    public void Update(in ControllerState state)
    {
        var report = new XusbReport
        {
            ThumbLX = state.Steer,
            RightTrigger = AxisMath.ToXInputTrigger(state.Throttle),
            LeftTrigger = AxisMath.ToXInputTrigger(state.Brake),
            Buttons = MapButtons(state.Buttons),
        };

        if (_clutchOnRightStick)
        {
            report.ThumbRY = (short)(state.Clutch - 32768);
        }

        ViGEmNative.vigem_target_x360_update(_client, _target, report);
    }

    internal static ushort MapButtons(uint mask)
    {
        ushort buttons = 0;

        if ((mask & UplinkPacket.ButtonUpShift) != 0)
        {
            buttons |= XusbReport.RightShoulder;
        }

        if ((mask & UplinkPacket.ButtonDownShift) != 0)
        {
            buttons |= XusbReport.LeftShoulder;
        }

        if ((mask & UplinkPacket.ButtonHandbrake) != 0)
        {
            buttons |= XusbReport.B;
        }

        if ((mask & (1u << 3)) != 0)
        {
            buttons |= XusbReport.A;
        }

        return buttons;
    }

    public void Dispose()
    {
        if (_added)
        {
            ViGEmNative.vigem_target_remove(_client, _target);
            _added = false;
        }

        if (_target != nint.Zero)
        {
            ViGEmNative.vigem_target_free(_target);
            _target = nint.Zero;
        }

        if (_client != nint.Zero)
        {
            ViGEmNative.vigem_disconnect(_client);
            ViGEmNative.vigem_free(_client);
            _client = nint.Zero;
        }
    }
}
