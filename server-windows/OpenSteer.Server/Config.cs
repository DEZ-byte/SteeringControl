using System.Net;

namespace OpenSteer.Server;

public enum OutputMode
{
    /// <summary>ViGEmBus Xbox 360. The default and the only required backend.</summary>
    A,

    /// <summary>vJoy DirectInput. Optional and not implemented yet.</summary>
    B,

    /// <summary>No driver at all: decode, validate and run the watchdog only.</summary>
    None,
}

public sealed class HostConfig
{
    public IPAddress Bind { get; private set; } = IPAddress.Any;

    public int Port { get; private set; } = 9999;

    public OutputMode Mode { get; private set; } = OutputMode.A;

    public bool StatsJson { get; private set; }

    public int TraceInject { get; private set; }

    public bool ClutchAxis { get; private set; }

    public bool TakeoverImmediate { get; private set; }

    public bool EchoRtt { get; private set; }

    /// <summary>Wheel-slip value treated as 100%. AC reports raw scrub, so the
    /// normalisation point is a tuning knob rather than a constant.</summary>
    public float SlipFull { get; private set; } = 1.0f;

    public static bool TryParse(string[] args, out HostConfig config, out string error)
    {
        config = new HostConfig();
        error = string.Empty;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            string? Next() => i + 1 < args.Length ? args[++i] : null;

            switch (arg)
            {
                case "--bind":
                    if (!IPAddress.TryParse(Next(), out IPAddress? bind))
                    {
                        error = "--bind needs an IPv4 address";
                        return false;
                    }

                    config.Bind = bind;
                    break;

                case "--port":
                    if (!int.TryParse(Next(), out int port) || port is < 1 or > 65535)
                    {
                        error = "--port needs a number between 1 and 65535";
                        return false;
                    }

                    config.Port = port;
                    break;

                case "--mode":
                    switch (Next())
                    {
                        case "a": config.Mode = OutputMode.A; break;
                        case "b": config.Mode = OutputMode.B; break;
                        case "none": config.Mode = OutputMode.None; break;
                        default:
                            error = "--mode must be a, b or none";
                            return false;
                    }

                    break;

                case "--stats-json":
                    config.StatsJson = Next() != "0";
                    break;

                case "--trace-inject":
                    if (!int.TryParse(Next(), out int trace) || trace < 0)
                    {
                        error = "--trace-inject needs a non-negative number";
                        return false;
                    }

                    config.TraceInject = trace;
                    break;

                case "--echo-rtt":
                    config.EchoRtt = true;
                    break;

                case "--slip-full":
                    if (!float.TryParse(Next(), System.Globalization.NumberStyles.Float,
                                        System.Globalization.CultureInfo.InvariantCulture,
                                        out float slip) || slip <= 0f)
                    {
                        error = "--slip-full needs a positive number";
                        return false;
                    }

                    config.SlipFull = slip;
                    break;

                case "--clutch-axis":
                    config.ClutchAxis = true;
                    break;

                case "--takeover":
                    config.TakeoverImmediate = Next() == "immediate";
                    break;

                case "--help":
                case "-h":
                    error = Usage;
                    return false;

                default:
                    error = $"unknown option {arg}\n\n{Usage}";
                    return false;
            }
        }

        return true;
    }

    public const string Usage = """
        OpenSteer host daemon

          --bind <ip>            interface to listen on (default 0.0.0.0)
          --port <n>             UDP port (default 9999)
          --mode a|b|none        a = ViGEmBus Xbox 360 (default)
                                 b = vJoy, optional, not implemented yet
                                 none = headless, no driver needed
          --stats-json 0|1       emit one JSON status line per second
          --trace-inject <n>     log every nth injected frame
          --slip-full <f>        wheel slip treated as 100% (default 1.0)
          --echo-rtt             echo the phone's timestamp for round-trip timing
          --clutch-axis          map clutch to the right stick in mode a
          --takeover immediate   let any sender seize the lease (test harness only)
        """;
}
