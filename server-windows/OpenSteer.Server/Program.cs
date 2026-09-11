using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime;
using OpenSteer.Core;
using OpenSteer.Server.Diagnostics;
using OpenSteer.Server.Interop;
using OpenSteer.Server.Net;
using OpenSteer.Server.Output;

namespace OpenSteer.Server;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (!HostConfig.TryParse(args, out HostConfig config, out string parseError))
        {
            Console.Error.WriteLine(parseError);
            return 2;
        }

        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("OpenSteer.Server is Windows-only.");
            return 2;
        }

        ConfigureProcess();

        using IOutputSink sink = CreateSink(config);

        if (!sink.Open(out string sinkError))
        {
            Console.Error.WriteLine($"output backend '{sink.Name}' unavailable: {sinkError}");
            return 3;
        }

        Console.Out.WriteLine($"output: {sink.Name}");

        Socket socket;

        try
        {
            socket = UdpHotLoop.CreateSocket(config.Bind, config.Port);
        }
        catch (SocketException ex)
        {
            Console.Error.WriteLine($"could not bind {config.Bind}:{config.Port}: {ex.Message}");
            return 4;
        }

        Console.Out.WriteLine($"UDP {config.Bind}:{config.Port} listening");

        var counters = new HotCounters();
        var lease = new LeaseSlot();
        var log = new LogRing();
        var watchdog = new Watchdog(Stopwatch.Frequency);
        var loop = new UdpHotLoop(socket, sink, watchdog, lease, counters, log,
                                  config.TakeoverImmediate, config.TraceInject);
        var stats = new StatsPrinter(loop, counters, lease, log, config.StatsJson);

        using var cancellation = new CancellationTokenSource();
        using var stopped = new ManualResetEventSlim(false);

        Console.CancelKeyPress += (_, e) =>
        {
            // Ctrl+C and Ctrl+Break both land here. The test harness sends
            // CTRL_BREAK_EVENT, which only reaches a process in its own group.
            e.Cancel = true;
            cancellation.Cancel();
        };

        var hotThread = new Thread(() => RunHot(loop, cancellation.Token, stopped))
        {
            Name = "rx-hot",
            IsBackground = false,
            Priority = ThreadPriority.Highest,
        };

        var statsThread = new Thread(() => stats.Run(cancellation.Token))
        {
            Name = "stats-1hz",
            IsBackground = true,
            Priority = ThreadPriority.Lowest,
        };

        hotThread.Start();
        statsThread.Start();

        hotThread.Join();
        stopped.Set();
        statsThread.Join(2000);

        socket.Dispose();
        RestoreTimerResolution();

        return 0;
    }

    private static void RunHot(UdpHotLoop loop, CancellationToken token, ManualResetEventSlim stopped)
    {
        try
        {
            loop.Run(token);
        }
        finally
        {
            stopped.Set();
        }
    }

    private static IOutputSink CreateSink(HostConfig config) => config.Mode switch
    {
        OutputMode.A => new ViGEmX360Sink(config.ClutchAxis),
        OutputMode.B => new UnavailableSink(
            "vJoy",
            "Mode B is not implemented yet. Memory Integrity is enabled on "
          + "this machine and can refuse the vJoy driver, so Mode A is the supported path."),
        _ => new NullSink(),
    };

    private static void ConfigureProcess()
    {
        // 0.5 ms kernel timer. Without it the 5 ms watchdog tick gets rounded up by
        // the scheduler and the fail-safe fires late.
        int status = NtDll.NtSetTimerResolution(5000, true, out uint actual);
        Console.Out.WriteLine($"timer_res_100ns=5000 actual={actual} status=0x{status:X8}");

        bool optedOut = Kernel32.TryDisableTimerResolutionThrottling(out int lastError);
        Console.Out.WriteLine(optedOut
            ? "throttle_optout=ok"
            : $"throttle_optout=err({lastError}) - harmless on Windows 10");

        try
        {
            using var process = Process.GetCurrentProcess();
            process.PriorityClass = ProcessPriorityClass.High;
            Console.Out.WriteLine("priority=High");
        }
        catch (Exception ex) when (ex is PlatformNotSupportedException or InvalidOperationException)
        {
            Console.Out.WriteLine("priority=Normal (could not raise)");
        }

        // Never RealTime: it would starve the game's own audio and input threads,
        // which is a worse outcome than a little jitter here.
        GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
    }

    private static void RestoreTimerResolution() =>
        NtDll.NtSetTimerResolution(5000, false, out _);
}

/// <summary>A backend that reports why it is missing instead of throwing.</summary>
internal sealed class UnavailableSink : IOutputSink
{
    private readonly string _reason;

    public UnavailableSink(string name, string reason)
    {
        Name = name;
        _reason = reason;
    }

    public string Name { get; }

    public bool Open(out string error)
    {
        error = _reason;
        return false;
    }

    public void Update(in OpenSteer.Core.Protocol.ControllerState state)
    {
    }

    public void Dispose()
    {
    }
}
