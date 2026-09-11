using System.Globalization;
using System.Text;
using OpenSteer.Core;
using OpenSteer.Server.Net;
using OpenSteer.Server.Telemetry;

namespace OpenSteer.Server.Diagnostics;

/// <summary>
/// The 1 Hz reporting thread. Everything that allocates - string building, JSON,
/// console writes - happens here and nowhere near the hot path.
/// </summary>
public sealed class StatsPrinter
{
    private readonly UdpHotLoop _loop;
    private readonly HotCounters _counters;
    private readonly LeaseSlot _lease;
    private readonly LogRing _log;
    private readonly bool _json;
    private DownlinkSender? _downlink;

    private readonly long[] _iaNow = new long[LatencyHistogram.BucketCount];
    private readonly long[] _iaPrev = new long[LatencyHistogram.BucketCount];
    private readonly long[] _iaWindow = new long[LatencyHistogram.BucketCount];
    private readonly long[] _pipeNow = new long[LatencyHistogram.BucketCount];
    private readonly long[] _pipePrev = new long[LatencyHistogram.BucketCount];
    private readonly long[] _pipeWindow = new long[LatencyHistogram.BucketCount];
    private readonly long[] _jitNow = new long[LatencyHistogram.BucketCount];
    private readonly long[] _jitPrev = new long[LatencyHistogram.BucketCount];
    private readonly long[] _jitWindow = new long[LatencyHistogram.BucketCount];

    private readonly StringBuilder _builder = new(768);

    private HotCounters.Snapshot _previous;
    private int _gen0Baseline;
    private bool _first = true;

    public StatsPrinter(UdpHotLoop loop, HotCounters counters, LeaseSlot lease,
                        LogRing log, bool json)
    {
        _loop = loop;
        _counters = counters;
        _lease = lease;
        _log = log;
        _json = json;
    }

    /// <summary>Attached after construction: the sender needs the socket the hot
    /// loop owns, so it is built later than this printer.</summary>
    public DownlinkSender? Downlink
    {
        get => _downlink;
        set => _downlink = value;
    }

    public void Run(CancellationToken cancellation)
    {
        _previous = _counters.Read();
        _gen0Baseline = GC.CollectionCount(0);

        while (!cancellation.IsCancellationRequested)
        {
            if (cancellation.WaitHandle.WaitOne(1000))
            {
                break;
            }

            DrainEvents();
            PrintStats();
        }

        DrainEvents();
        PrintStats();
        Emit(Begin().Key("ev", "EXIT").End());
    }

    public void DrainEvents()
    {
        while (_log.TryPop(out LogEvent evt))
        {
            switch (evt.Kind)
            {
                case LogKind.Watchdog:
                    Emit(Begin()
                        .Key("ev", "WD")
                        .Key("t", evt.TimestampNs)
                        .Key("from", evt.From.ToString())
                        .Key("to", evt.To.ToString())
                        .Key("silence_us", evt.SilenceUs)
                        .Key("slew_us", evt.SlewUs)
                        .End());
                    break;

                case LogKind.Inject:
                    Emit(Begin()
                        .Key("ev", "INJ")
                        .Key("t", evt.TimestampNs)
                        .Key("steer", evt.State.Steer)
                        .Key("thr", evt.State.Throttle)
                        .Key("brk", evt.State.Brake)
                        .Key("clu", evt.State.Clutch)
                        .Key("btn", evt.State.Buttons)
                        .End());
                    break;

                case LogKind.Alert:
                    Emit(Begin()
                        .Key("ev", "ALERT")
                        .Key("t", evt.TimestampNs)
                        .Key("reason", "link lost - wheel centred, pedals released")
                        .End());
                    break;

                default:
                    break;
            }
        }
    }

    private void PrintStats()
    {
        HotCounters.Snapshot now = _counters.Read();
        HotCounters.Snapshot delta = now - _previous;
        _previous = now;

        _loop.InterArrival.CopyTo(_iaNow);
        LatencyHistogram.Subtract(_iaNow, _iaPrev, _iaWindow);
        Array.Copy(_iaNow, _iaPrev, _iaNow.Length);

        _loop.Pipeline.CopyTo(_pipeNow);
        LatencyHistogram.Subtract(_pipeNow, _pipePrev, _pipeWindow);
        Array.Copy(_pipeNow, _pipePrev, _pipeNow.Length);

        _loop.Jitter.CopyTo(_jitNow);
        LatencyHistogram.Subtract(_jitNow, _jitPrev, _jitWindow);
        Array.Copy(_jitNow, _jitPrev, _jitNow.Length);

        long iaP50 = LatencyHistogram.Percentile(_iaWindow, 0.50);
        long iaP99 = LatencyHistogram.Percentile(_iaWindow, 0.99);
        long pipeP99 = LatencyHistogram.Percentile(_pipeWindow, 0.99);
        long jitP99 = LatencyHistogram.Percentile(_jitWindow, 0.99);

        // Counted from a baseline taken at startup, so warm-up collections do not
        // pollute the zero-allocation check on the hot path.
        int gen0 = GC.CollectionCount(0) - _gen0Baseline;

        if (_first)
        {
            _first = false;
        }

        Emit(Begin()
            .Key("ev", "STATS")
            .Key("t", UdpHotLoop.NowNs())
            .Key("state", _loop.State.ToString())
            .Key("src", _lease.Describe())
            .Key("pps", delta.Accepted)
            .Key("acc", delta.Accepted)
            .Key("coalesced", delta.Coalesced)
            .Key("drain_cap", delta.DrainCap)
            .Key("drop", delta.Dropped)
            // dup and stale are CUMULATIVE, matching the bad_* family. They are
            // reject counters, and a test asserting "50 duplicates were rejected"
            // needs a total, not whatever happened to land in the last second.
            .Key("dup", now.Duplicate)
            .Key("stale", now.Stale)
            .Key("dup_window", delta.Duplicate)
            .Key("stale_window", delta.Stale)
            .Key("bad_len", now.BadLen)
            .Key("bad_magic", now.BadMagic)
            .Key("bad_csum", now.BadCsum)
            .Key("bad_pad", now.BadPad)
            .Key("other_src", now.OtherSource)
            .Key("reseeds", now.Reseeds)
            .Key("sock_err", now.SocketErrors)
            .Key("acc_total", now.Accepted)
            .Key("drop_total", now.Dropped)
            .Key("ia_p50_us", iaP50)
            .Key("ia_p99_us", iaP99)
            .Key("ipdv_p99_us", jitP99)
            .Key("pipe_p99_us", pipeP99)
            .Key("gc0", gen0)
            .Key("dl_pps", delta.DownlinkSent)
            .Key("dl_total", now.DownlinkSent)
            .Key("shm", (_downlink?.ShmState ?? ShmState.None).ToString())
            .End());
    }

    private void Emit(string line)
    {
        Console.Out.WriteLine(line);
        Console.Out.Flush();
    }

    private JsonLine Begin() => new(_builder, _json);

    /// <summary>
    /// Tiny writer for one flat object. Built by hand rather than with a serializer
    /// because the output is a stable machine contract for scripts to parse, and
    /// because reflection-based serialization is the wrong dependency for a daemon
    /// that wants a small, predictable footprint.
    /// </summary>
    private readonly struct JsonLine
    {
        private readonly StringBuilder _sb;
        private readonly bool _json;

        internal JsonLine(StringBuilder sb, bool json)
        {
            _sb = sb;
            _json = json;
            sb.Clear();

            if (json)
            {
                sb.Append('{');
            }
        }

        private void Separate()
        {
            char last = _sb.Length == 0 ? '\0' : _sb[^1];

            if (last is not ('{' or '\0'))
            {
                _sb.Append(_json ? "," : " ");
            }
        }

        internal JsonLine Key(string key, long value)
        {
            Separate();

            if (_json)
            {
                _sb.Append('"').Append(key).Append("\":");
            }
            else
            {
                _sb.Append(key).Append('=');
            }

            _sb.Append(value.ToString(CultureInfo.InvariantCulture));
            return this;
        }

        internal JsonLine Key(string key, string value)
        {
            Separate();

            if (_json)
            {
                _sb.Append('"').Append(key).Append("\":\"").Append(value).Append('"');
            }
            else
            {
                _sb.Append(key).Append('=').Append(value);
            }

            return this;
        }

        internal string End()
        {
            if (_json)
            {
                _sb.Append('}');
            }

            return _sb.ToString();
        }
    }
}
