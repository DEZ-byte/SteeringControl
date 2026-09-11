using System.Buffers.Binary;
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime;
using System.Runtime.InteropServices;
using OpenSteer.Core;
using OpenSteer.Core.Protocol;
using OpenSteer.Server.Diagnostics;
using OpenSteer.Server.Interop;
using OpenSteer.Server.Net;
using OpenSteer.Server.Output;
using OpenSteer.Server.Telemetry;

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

        WarmUpHotPath();

        Console.Out.WriteLine($"UDP {config.Bind}:{config.Port} listening");

        var counters = new HotCounters();
        var lease = new LeaseSlot();
        var log = new LogRing();
        var watchdog = new Watchdog(Stopwatch.Frequency);
        var loop = new UdpHotLoop(socket, sink, watchdog, lease, counters, log,
                                  config.TakeoverImmediate, config.TraceInject);
        var stats = new StatsPrinter(loop, counters, lease, log, config.StatsJson);

        var reader = new AcSharedMemoryReader(config.SlipFull);
        using var downlink = new DownlinkSender(socket, lease, reader, counters, config.EchoRtt);
        stats.Downlink = downlink;
        loop.Downlink = downlink;

        if (config.EchoRtt)
        {
            // The hot thread takes over sending so a round-trip measurement is not
            // padded by however long a frame would wait for the next 60 Hz slot.
            loop.EchoSender = downlink;
        }

        Console.Out.WriteLine($"telemetry: {AcSharedMemoryReader.MapName} slip_full={config.SlipFull}"
                            + (config.EchoRtt ? " echo_rtt=on" : string.Empty));

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

        var telemetryThread = new Thread(() => downlink.Run(cancellation.Token))
        {
            Name = "telemetry-60hz",
            IsBackground = true,
            Priority = ThreadPriority.Normal,
        };

        hotThread.Start();
        telemetryThread.Start();
        statsThread.Start();

        hotThread.Join();
        telemetryThread.Join(2000);
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

    /// <summary>
    /// Runs a synthetic frame through the whole decode path before the socket opens.
    /// </summary>
    /// <remarks>
    /// Tiered compilation starts every method in a slow tier-0 form and only promotes
    /// it after roughly thirty calls. Left alone, that promotion happens during the
    /// first second of real steering. Measured: the opening one-second window showed
    /// a receive-to-inject p99 of 3200 us, against 300 us or less for every window
    /// after it. Warming the driver alone took it to 1700 us; the remainder was the
    /// validator, the checksum and the watchdog being cold. This costs a few
    /// milliseconds of startup and buys a first corner that behaves like the rest.
    /// <para>
    /// The watchdog used here is a throwaway instance: warming the real one would
    /// leave it holding a fabricated packet.
    /// </para>
    /// </remarks>
    private static void WarmUpHotPath()
    {
        Span<byte> frame = stackalloc byte[UplinkPacket.Size];
        var seed = new UplinkPacket(1, 1000, 2000, 3000, 4000, 0x5u, 0UL, 0u);
        MemoryMarshal.Write(frame, in seed);
        BinaryPrimitives.WriteUInt32LittleEndian(frame[28..], Xxh32.Hash28(frame));

        var scratchWatchdog = new Watchdog(Stopwatch.Frequency);
        var scratchState = default(ControllerState);
        var scratchValidator = new PacketValidator();
        long clock = Stopwatch.GetTimestamp();
        long step = Stopwatch.Frequency / 120;
        int accepted = 0;

        for (int i = 0; i < 4096; i++)
        {
            if (PacketValidator.CheckFrame(frame) != Verdict.Ok)
            {
                // The frame is built right here, so this cannot happen unless the
                // checksum or the struct layout has regressed. Better to know now.
                throw new InvalidOperationException("warm-up frame failed its own validation");
            }

            UplinkPacket decoded = MemoryMarshal.Read<UplinkPacket>(frame);

            if (scratchValidator.CheckSequence((ushort)i, out _) == SequenceVerdict.Accepted)
            {
                accepted++;
            }

            scratchWatchdog.OnPacket(clock, in decoded);
            scratchWatchdog.Evaluate(clock, ref scratchState);
            scratchWatchdog.TryDequeueEvent(out _);
            clock += step;
        }

        Console.Out.WriteLine($"warmup=ok frames={accepted}");
    }

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
