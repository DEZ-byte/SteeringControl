using System.Runtime.InteropServices;

namespace OpenSteer.Server.Interop;

/// <summary>
/// Undocumented but universally used timer-resolution control. The documented
/// timeBeginPeriod tops out at 1 ms; this reaches 0.5 ms, which keeps the 5 ms
/// watchdog tick from being rounded up by the scheduler.
/// </summary>
internal static partial class NtDll
{
    /// <param name="desiredTime">100 ns units. 5000 = 0.5 ms.</param>
    [LibraryImport("ntdll.dll")]
    internal static partial int NtSetTimerResolution(
        uint desiredTime,
        [MarshalAs(UnmanagedType.U1)] bool setResolution,
        out uint actualTime);

    [LibraryImport("ntdll.dll")]
    internal static partial int NtQueryTimerResolution(
        out uint maximumTime,
        out uint minimumTime,
        out uint currentTime);
}
