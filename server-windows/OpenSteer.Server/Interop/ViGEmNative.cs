using System.Reflection;
using System.Runtime.InteropServices;

// No native import in this assembly may fall through to the current directory or
// PATH, where a planted DLL of the same name would be loaded instead (CWE-427).
// SafeDirectories is the application folder plus System32: kernel32 and ntdll are
// found there, and ViGEmClient.dll is loaded by the resolver below or not at all.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]

namespace OpenSteer.Server.Interop;

/// <summary>XUSB_REPORT from ViGEm/Common.h. 12 bytes, passed by value.</summary>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct XusbReport
{
    internal ushort Buttons;
    internal byte LeftTrigger;
    internal byte RightTrigger;
    internal short ThumbLX;
    internal short ThumbLY;
    internal short ThumbRX;
    internal short ThumbRY;

    internal const ushort DpadUp = 0x0001;
    internal const ushort DpadDown = 0x0002;
    internal const ushort DpadLeft = 0x0004;
    internal const ushort DpadRight = 0x0008;
    internal const ushort Start = 0x0010;
    internal const ushort Back = 0x0020;
    internal const ushort LeftThumb = 0x0040;
    internal const ushort RightThumb = 0x0080;
    internal const ushort LeftShoulder = 0x0100;
    internal const ushort RightShoulder = 0x0200;
    internal const ushort Guide = 0x0400;
    internal const ushort A = 0x1000;
    internal const ushort B = 0x2000;
    internal const ushort X = 0x4000;
    internal const ushort Y = 0x8000;
}

/// <summary>
/// Direct P/Invoke into the native ViGEmClient. The managed Nefarius.ViGEm.Client
/// wrapper is deliberately not referenced: only the native library it ships is used,
/// extracted once at setup, so there is no Costura assembly-resolve hook in the way
/// and no managed dependency on the hot path.
/// </summary>
internal static partial class ViGEmNative
{
    internal const string Library = "ViGEmClient";

    internal const uint ErrorNone = 0x20000000;
    internal const uint ErrorBusNotFound = 0xE0000001;
    internal const uint ErrorNoFreeSlot = 0xE0000002;
    internal const uint ErrorInvalidTarget = 0xE0000003;
    internal const uint ErrorBusVersionMismatch = 0xE0000005;
    internal const uint ErrorBusAccessFailed = 0xE0000006;

    private static bool _resolverInstalled;

    /// <summary>
    /// Loads ViGEmClient.dll from beside the host executable and from nowhere else.
    /// The publish keeps it a loose file there (ExcludeFromSingleFile in the csproj);
    /// without that, the single-file bundle would extract it to a temp folder this
    /// probe never looks in.
    /// </summary>
    /// <remarks>
    /// Fails closed. Returning <c>nint.Zero</c> would hand the load back to default
    /// probing, which is the search this resolver exists to avoid. The exception
    /// reaches <c>ViGEmX360Sink.Open</c>, which reports it.
    /// </remarks>
    internal static void InstallResolver()
    {
        if (_resolverInstalled)
        {
            return;
        }

        _resolverInstalled = true;

        NativeLibrary.SetDllImportResolver(
            Assembly.GetExecutingAssembly(),
            (name, assembly, searchPath) =>
            {
                if (!string.Equals(name, Library, StringComparison.OrdinalIgnoreCase))
                {
                    return nint.Zero;
                }

                string candidate = Path.Combine(AppContext.BaseDirectory, Library + ".dll");

                if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out nint handle))
                {
                    return handle;
                }

                throw new DllNotFoundException($"{candidate} is missing or failed to load.");
            });
    }

    internal static string Describe(uint error) => error switch
    {
        ErrorNone => "ok",
        ErrorBusNotFound => "ViGEmBus driver not found - install it, then reboot if it was just added",
        ErrorNoFreeSlot => "ViGEmBus has no free controller slot",
        ErrorInvalidTarget => "invalid target",
        ErrorBusVersionMismatch => "ViGEmBus version does not match this client",
        ErrorBusAccessFailed => "could not open the ViGEmBus device",
        _ => $"ViGEm error 0x{error:X8}",
    };

    [LibraryImport(Library)]
    internal static partial nint vigem_alloc();

    [LibraryImport(Library)]
    internal static partial void vigem_free(nint client);

    [LibraryImport(Library)]
    internal static partial uint vigem_connect(nint client);

    [LibraryImport(Library)]
    internal static partial void vigem_disconnect(nint client);

    [LibraryImport(Library)]
    internal static partial nint vigem_target_x360_alloc();

    [LibraryImport(Library)]
    internal static partial void vigem_target_free(nint target);

    [LibraryImport(Library)]
    internal static partial uint vigem_target_add(nint client, nint target);

    [LibraryImport(Library)]
    internal static partial uint vigem_target_remove(nint client, nint target);

    [LibraryImport(Library)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool vigem_target_is_attached(nint target);

    [LibraryImport(Library)]
    internal static partial uint vigem_target_x360_update(nint client, nint target, XusbReport report);
}
