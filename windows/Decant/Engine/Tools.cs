// The libimobiledevice command-line tools Decant talks through, found next to the app (Tools\) or on PATH.
using System.Diagnostics;
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
    public static async Task<int?> Stream(string tool, IEnumerable<string> args, Action<string> line, string? input = null,
        Action<Process>? register = null, CancellationToken ct = default)
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
        register?.Invoke(p);
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

    /// The first "NN%" in a line, as 0..1, or null.
    public static double? Percent(string s)
    {
        var m = Regex.Match(s, @"(\d{1,3})%");
        return m.Success ? int.Parse(m.Groups[1].Value) / 100.0 : null;
    }
}
