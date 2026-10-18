using System.Runtime.InteropServices;

namespace OpenSteer.Server.Interop;

[StructLayout(LayoutKind.Sequential)]
internal struct ProcessPowerThrottlingState
{
    internal uint Version;
    internal uint ControlMask;
    internal uint StateMask;

    internal const uint CurrentVersion = 1;
    internal const uint IgnoreTimerResolution = 0x4;
}

internal static partial class Kernel32
{
    internal const int ProcessPowerThrottling = 4;

    [LibraryImport("kernel32.dll")]
    internal static partial nint GetCurrentProcess();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetProcessInformation(
        nint process,
        int informationClass,
        ref ProcessPowerThrottlingState information,
        uint informationSize);

    /// <summary>
    /// Windows 11 quietly revokes a process's timer-resolution request once its
    /// window is occluded or minimized, which is this daemon's normal state behind a
    /// fullscreen game. Opting out of that throttling keeps the 0.5 ms resolution we
    /// just asked for.
    /// </summary>
    /// <remarks>
    /// StateMask 0 means "do not throttle". Passing IgnoreTimerResolution in
    /// StateMask as well would opt in, the opposite of what is wanted.
    /// </remarks>
    internal static bool TryDisableTimerResolutionThrottling(out int lastError)
    {
        var state = new ProcessPowerThrottlingState
        {
            Version = ProcessPowerThrottlingState.CurrentVersion,
            ControlMask = ProcessPowerThrottlingState.IgnoreTimerResolution,
            StateMask = 0,
        };

        bool ok = SetProcessInformation(
            GetCurrentProcess(), ProcessPowerThrottling, ref state, 12);

        lastError = ok ? 0 : Marshal.GetLastPInvokeError();
        return ok;
    }

    internal const uint CreateWaitableTimerHighResolution = 0x00000002;
    internal const uint TimerAllAccess = 0x1F0003;
    internal const uint WaitObject0 = 0;

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nint CreateWaitableTimerExW(
        nint attributes, nint name, uint flags, uint desiredAccess);

    /// <param name="dueTime">100 ns units. Negative means relative to now.</param>
    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetWaitableTimer(
        nint timer, in long dueTime, int period, nint completionRoutine,
        nint argToCompletionRoutine, [MarshalAs(UnmanagedType.Bool)] bool resume);

    [LibraryImport("kernel32.dll")]
    internal static partial uint WaitForSingleObject(nint handle, uint milliseconds);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CloseHandle(nint handle);
}
