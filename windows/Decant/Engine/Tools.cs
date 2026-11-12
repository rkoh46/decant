// The libimobiledevice command-line tools Decant talks through, found next to the app (Tools\) or on PATH.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Decant.Engine;

public static class Tools
{
    public static readonly string[] Needed = { "idevice_id", "ideviceinfo", "idevicediagnostics", "idevicename" };

    public static readonly string[] ToolDirs =
    {
        Path.Combine(AppContext.BaseDirectory, "Tools"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "Tools"),
    };

    static readonly Dictionary<string, string?> cache = new();

    public static string? Find(string name)
    {
        lock (cache)
        {
            if (cache.TryGetValue(name, out var c)) return c;
            var exe = name + ".exe";
            var candidates = ToolDirs.Select(d => Path.Combine(d, exe)).ToList();
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
                candidates.Add(Path.Combine(dir.Trim(), exe));
            var found = candidates.FirstOrDefault(File.Exists);
            cache[name] = found;
            return found;
        }
    }

    public static bool Has(string name) => Find(name) != null;
    public static bool Available => Needed.All(Has) && Afc.LibraryPresent;
    public static IEnumerable<string> Missing => Needed.Where(n => !Has(n)).Concat(Afc.LibraryPresent ? Array.Empty<string>() : new[] { "imobiledevice-1.0.dll" });

    public sealed record Result(int Code, string Output, string Error);

    // Every tool Decant starts goes into one Windows job object that kills its members when the job's last handle
    // closes, which happens when Decant exits for any reason (quit, crash, Task Manager). Without it a child keeps
    // running: an idevicebackup2 left behind when its phone was unplugged spins at 100% CPU for as long as it lives.
    static readonly IntPtr job = CreateKillOnCloseJob();

    internal static void Adopt(Process p)
    {
        if (job == IntPtr.Zero) return;
        try { AssignProcessToJobObject(job, p.Handle); } catch { }
    }

    static IntPtr CreateKillOnCloseJob()
    {
        try
        {
            var h = CreateJobObject(IntPtr.Zero, null);
            if (h == IntPtr.Zero) return IntPtr.Zero;
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            var ptr = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, ptr, false);
                if (!SetInformationJobObject(h, 9 /* JobObjectExtendedLimitInformation */, ptr, (uint)size)) return IntPtr.Zero;
            }
            finally { Marshal.FreeHGlobal(ptr); }
            return h;
        }
        catch { return IntPtr.Zero; }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    /// Whether usbmuxd still lists the phone with this UDID (USB, or Wi-Fi when `network`). True when it cannot tell,
    /// so a job is never stopped on a guess.
    public static async Task<bool> DeviceListed(string udid, bool network)
    {
        if (!Has("idevice_id")) return true;
        var r = await Run("idevice_id", new[] { network ? "-n" : "-l" });
        return r.Code != 0 && r.Code != 255 ? true : r.Output.Contains(udid, StringComparison.OrdinalIgnoreCase);
    }

    /// Runs a tool to completion. `input` is written to stdin (afcclient reads its commands there).
    public static async Task<Result> Run(string tool, IEnumerable<string> args, string? input = null, CancellationToken ct = default)
    {
        var path = Find(tool);
        if (path == null) return new Result(127, "", $"{tool} not found");
        var psi = new ProcessStartInfo(path)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input != null,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["TERM"] = "dumb";
        using var p = new Process { StartInfo = psi };
        try { p.Start(); } catch (Exception e) { return new Result(126, "", e.Message); }
        Adopt(p);
        if (input != null)
        {
            await p.StandardInput.WriteAsync(input);
            p.StandardInput.Close();
        }
        var outTask = p.StandardOutput.ReadToEndAsync(ct);
        var errTask = p.StandardError.ReadToEndAsync(ct);
        try { await p.WaitForExitAsync(ct); }
        catch (OperationCanceledException) { try { p.Kill(true); } catch { } throw; }
        return new Result(p.ExitCode, await outTask, await errTask);
    }

}

public static partial class ToolsStream
{
    /// Runs a tool and reports its output line by line (stdout and stderr merged; \r and \n both end a line, so
    /// progress bars come through). Returns the exit code, or null when the tool is missing or could not start.
    /// `input` is written to stdin and stdin closed. `register` receives the process so the caller can kill it.
    /// `alive`, when given, is asked every 5 s whether the job can still make progress (the phone is still there);
    /// after `graceSeconds` of "no" the tool is killed and `onGiveUp` runs. idevicebackup2 does not exit when the
    /// phone is unplugged: it retries in a tight loop at 100% CPU forever.
    public static async Task<int?> Stream(string tool, IEnumerable<string> args, Action<string> line, string? input = null,
        Action<Process>? register = null, CancellationToken ct = default,
        Func<Task<bool>>? alive = null, double graceSeconds = 20, Action? onGiveUp = null)
    {
        var path = Tools.Find(tool);
        if (path == null) { line($"{tool} is not installed"); return null; }
        var psi = new ProcessStartInfo(path)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input != null,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["TERM"] = "dumb";
        using var p = new Process { StartInfo = psi };
        try { p.Start(); } catch (Exception e) { line($"could not start {tool}: {e.Message}"); return null; }
        Tools.Adopt(p);
        register?.Invoke(p);
        if (alive != null) _ = Watch(p, alive, graceSeconds, onGiveUp);
        if (input != null) { await p.StandardInput.WriteAsync(input); p.StandardInput.Close(); }
        var gate = new object();
        async Task Pump(StreamReader r)
        {
            var buf = new char[4096]; var sb = new StringBuilder();
            while (true)
            {
                int n;
                try { n = await r.ReadAsync(buf, 0, buf.Length); } catch { break; }
                if (n <= 0) break;
                for (int i = 0; i < n; i++)
                {
                    var c = buf[i];
                    if (c == '\n' || c == '\r') { var s = sb.ToString(); sb.Clear(); if (s.Trim().Length > 0) lock (gate) line(s); }
                    else sb.Append(c);
                }
            }
            if (sb.ToString().Trim().Length > 0) lock (gate) line(sb.ToString());
        }
        var pumps = Task.WhenAll(Pump(p.StandardOutput), Pump(p.StandardError));
        try { await p.WaitForExitAsync(ct); }
        catch (OperationCanceledException) { try { p.Kill(true); } catch { } throw; }
        await pumps;
        return p.ExitCode;
    }

    static async Task Watch(Process p, Func<Task<bool>> alive, double grace, Action? onGiveUp)
    {
        DateTime? goneSince = null;
        while (true)
        {
            await Task.Delay(5000);
            try { if (p.HasExited) return; } catch { return; }
            bool ok;
            try { ok = await alive(); } catch { ok = true; }
            if (ok) { goneSince = null; continue; }
            goneSince ??= DateTime.Now;
            if ((DateTime.Now - goneSince.Value).TotalSeconds < grace) continue;
            onGiveUp?.Invoke();
            try { p.Kill(true); } catch { }
            return;
        }
    }

    /// The first "NN%" in a line, as 0..1, or null.
    public static double? Percent(string s)
    {
        var m = Regex.Match(s, @"(\d{1,3})%");
        return m.Success ? int.Parse(m.Groups[1].Value) / 100.0 : null;
    }
}
