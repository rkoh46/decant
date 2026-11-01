// What the Tools tab runs: reports, crash logs, screenshots, the system log stream, recovery mode, self-tests and the
// battery history Decant keeps per phone. Mirrors Sources/Tools.swift and the DeviceManager helpers on the Mac.
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Decant.Engine;

public sealed class BatterySample
{
    public DateTime Date { get; set; }
    public int? Level { get; set; }
    public bool? Charging { get; set; }
    public int? CycleCount { get; set; }
    public int? MaxCapacity { get; set; }
    public int? DesignCapacity { get; set; }
    public double? Temperature { get; set; }
    public double? Voltage { get; set; }
    public double? Health => DesignCapacity > 0 && MaxCapacity > 0 ? 100.0 * MaxCapacity.Value / DesignCapacity.Value : null;
}

public sealed class DeviceTools
{
    readonly Session session;
    public DeviceTools(Session s)
    {
        session = s;
        s.Changed += () => { try { RecordBattery(); } catch { } };
    }

    void Log(string line) => session.Note(line);
    string Udid => session.Udid;
    bool Demo => Session.Demo;

    // MARK: Identifiers

    public sealed record Identity(string Imei, string Imei2, string Meid, string BasebandSerial);
    Identity? identity; string identityFor = "";

    /// IMEI, MEID and baseband serial are not in DeviceInfo; read them once per phone.
    public async Task<Identity> ReadIdentity()
    {
        if (identity != null && identityFor == Udid) return identity;
        if (Demo) { identity = new Identity("356728113457890", "356728113457908", "35672811345789", "4f1c0a9b"); identityFor = Udid; return identity; }
        var r = await Tools.Run("ideviceinfo", new[] { "-u", Udid, "-x" });
        var g = r.Code == 0 ? Plist.Parse(r.Output) : null;
        string S(string k) => g == null ? "" : Plist.Str(g.GetValueOrDefault(k));
        identity = new Identity(S("InternationalMobileEquipmentIdentity"), S("InternationalMobileEquipmentIdentity2"), S("MobileEquipmentIdentifier"), S("BasebandSerialNumber"));
        identityFor = Udid;
        return identity;
    }

    // MARK: Device report

    public string? LastReport;

    public async Task<bool> SaveReport(string path)
    {
        string? xml;
        if (Demo)
        {
            var i = session.Info!;
            xml = Plist.ToXml(new Dictionary<string, object?> { ["DeviceName"] = i.Name, ["ProductType"] = i.Model, ["ProductVersion"] = i.Version,
                ["SerialNumber"] = i.Serial, ["ModelNumber"] = i.ModelNumber, ["RegionInfo"] = i.Region, ["UniqueDeviceID"] = i.Udid, ["HardwareModel"] = i.Hardware });
        }
        else
        {
            var r = await Tools.Run("ideviceinfo", new[] { "-u", Udid, "-x" });
            xml = r.Code == 0 ? r.Output : null;
        }
        if (xml == null) { Log("Could not read the device report"); return false; }
        try { await File.WriteAllTextAsync(path, xml); } catch (Exception e) { Log("Could not save the device report: " + e.Message); return false; }
        LastReport = path;
        Log($"Device report saved to {path}");
        return true;
    }

    // MARK: Crash reports

    public (string Dir, int Count)? LastCrashExport;

    public async Task<bool> CopyCrashReports(string dir)
    {
        Log($"Copying crash reports to {dir}…");
        int? status;
        if (Demo) { await Task.Delay(300); status = 0; }
        else status = await ToolsStream.Stream("idevicecrashreport", new[] { "-u", Udid, "-e", "-k", dir }, _ => { });
        var count = Directory.Exists(dir) ? Directory.EnumerateFiles(dir).Count(f => f.EndsWith(".ips", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".crash", StringComparison.OrdinalIgnoreCase)) : 0;
        if (status == 0) { Log($"Crash reports copied: {count} files"); LastCrashExport = (dir, count); return true; }
        Log("Crash report copy failed");
        return false;
    }

    // MARK: Screenshot

    public string? LastScreenshot, LastScreenshotError;

    public async Task<bool> Screenshot()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Decant Screenshots");
        Directory.CreateDirectory(dir);
        var name = $"{session.Info?.Name ?? "iPhone"} {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png";
        var path = Path.Combine(dir, name);
        var output = new List<string>();
        int? status;
        if (Demo)
        {
            // The sample phone has no screen to capture: write the phone render's first wallpaper as the screenshot.
            var files = Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Web"))
                ? Directory.EnumerateFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Web"), "*.jpg", SearchOption.AllDirectories).OrderBy(p => p).ToList() : new List<string>();
            if (files.Count > 0) File.Copy(files[0], path, true);
            status = files.Count > 0 ? 0 : 1;
        }
        else status = await ToolsStream.Stream("idevicescreenshot", new[] { "-u", Udid, path }, output.Add);
        if (status == 0 && File.Exists(path))
        {
            LastScreenshot = path; LastScreenshotError = null;
            Log($"Screenshot saved to {path}");
            return true;
        }
        LastScreenshotError = $"Screenshot failed: {string.Join(" ", output).Trim()}. On iOS 17 and later, turn on Developer Mode in Settings → Privacy & Security, then try again.";
        Log(LastScreenshotError);
        return false;
    }

    // MARK: Unpair, recovery

    public async Task Unpair()
    {
        Log("Unpairing this PC");
        if (Demo) { Log("Unpairing this PC: done"); return; }
        var r = await Tools.Run("idevicepair", new[] { "-u", Udid, "unpair" });
        Log(r.Code == 0 ? "Unpairing this PC: done" : "Unpairing this PC: failed (is the iPhone unlocked and trusted?)");
    }

    public string Mode = "Normal";
    public bool Running;
    public event Action? Changed;
    void Notify() => Changed?.Invoke();

    public async Task EnterRecovery()
    {
        Log("Entering recovery mode");
        Running = true; Notify();
        if (Demo) { await Task.Delay(300); Log("Entering recovery mode: done"); }
        else await ToolsStream.Stream("ideviceenterrecovery", new[] { Udid }, Log);
        await Task.Delay(3000);
        await RefreshMode();
        Running = false; Notify();
    }

    public async Task ExitRecovery()
    {
        Log("Leaving recovery mode");
        Running = true; Notify();
        if (Demo) { await Task.Delay(300); Log("Leaving recovery mode: done"); }
        else await ToolsStream.Stream("irecovery", new[] { "-n" }, Log);
        await Task.Delay(3000);
        await RefreshMode();
        Running = false; Notify();
    }

    public async Task RefreshMode()
    {
        if (Demo) { Mode = "Normal"; Notify(); return; }
        if (!Tools.Has("irecovery")) { Mode = "–"; Notify(); return; }
        var lines = new List<string>();
        var status = await ToolsStream.Stream("irecovery", new[] { "-q" }, lines.Add);
        if (status == null) { Mode = "Normal"; Notify(); return; }
        var m = Regex.Match(string.Join("\n", lines), @"MODE:\s*(\w+)");
        if (!m.Success) Mode = "Normal";
        else
        {
            var w = m.Groups[1].Value.ToLowerInvariant();
            Mode = w.Contains("dfu") ? "DFU" : w.Contains("recovery") ? "Recovery" : "Unknown";
        }
        Notify();
    }

    // MARK: Self-tests

    public Dictionary<string, object?>? Diagnostics;
    string diagnosticsFor = "";

    public async Task RunDiagnostics(bool force = true)
    {
        if (Udid.Length == 0) return;
        if (!force && Diagnostics != null && diagnosticsFor == Udid) return;
        diagnosticsFor = Udid;
        if (Demo)
        {
            Diagnostics = new Dictionary<string, object?>
            {
                ["GasGauge"] = new Dictionary<string, object?> { ["CycleCount"] = 412L, ["DesignCapacity"] = 4685L, ["FullChargeCapacity"] = 4387L, ["Status"] = "Success" },
                ["NAND"] = new Dictionary<string, object?> { ["Status"] = "Success" },
                ["WiFi"] = new Dictionary<string, object?> { ["Active"] = "YES", ["Status"] = "Success" },
                ["HDMI"] = new Dictionary<string, object?> { ["Connection"] = "No", ["Status"] = "Success" },
                ["Status"] = "Success",
            };
            Log("Self-tests passed");
            Notify();
            return;
        }
        Log("Running the phone's self-tests");
        var r = await Tools.Run("idevicediagnostics", new[] { "-u", Udid, "diagnostics", "All" });
        Diagnostics = r.Code == 0 ? Plist.Parse(r.Output) : null;
        Log(Diagnostics == null ? "Self-tests did not answer" : "Self-tests finished");
        Notify();
    }

    /// The Mac's status(key): "Passed", the raw status, Wi-Fi activity or the video-out connection.
    public string? DiagStatus(string key)
    {
        if (Diagnostics?.GetValueOrDefault(key) is not Dictionary<string, object?> d) return null;
        var st = Plist.Str(d.GetValueOrDefault("Status"));
        if (key == "WiFi" && d.GetValueOrDefault("Active") is string active)
            return $"{(st == "Success" ? "Passed" : st)} · {(active == "YES" ? "active" : "inactive")}";
        if (key == "HDMI" && d.GetValueOrDefault("Connection") is string conn)
            return conn == "No" ? "Nothing connected" : "Connected";
        return st == "Success" ? "Passed" : st.Length == 0 ? null : st;
    }

    public long? DiagLong(string key, string sub) => Diagnostics?.GetValueOrDefault(key) is Dictionary<string, object?> d ? Plist.Long(d.GetValueOrDefault(sub)) : null;

    // MARK: System log

    public readonly List<string> Syslog = new();
    public bool SyslogRunning;
    public event Action? SyslogChanged;
    Process? syslogProcess;

    public void StartSyslog()
    {
        if (SyslogRunning || Udid.Length == 0) return;
        SyslogRunning = true; SyslogChanged?.Invoke();
        _ = Task.Run(async () =>
        {
            if (Demo)
            {
                var sample = new[]
                {
                    "kernel(AppleSmartBatteryManager)[0] <Notice>: AppleSmartBattery: charging, 78%, 2.9 A at 4.21 V",
                    "SpringBoard(FrontBoard)[58] <Notice>: Application com.apple.mobilesafari became foreground",
                    "wifid(WiFiPolicy)[42] <Notice>: Roam scan complete, staying on current BSS",
                    "locationd(CoreLocation)[76] <Notice>: Client com.apple.weather authorized: WhenInUse",
                    "backboardd(IOKit)[61] <Notice>: Display brightness set to 0.42",
                    "mediaserverd(AudioSession)[49] <Notice>: Session com.apple.Music activated, route Speaker",
                };
                for (int i = 0; SyslogRunning && i < 400; i++)
                {
                    AppendSyslog($"{DateTime.Now:MMM dd HH:mm:ss} {sample[i % sample.Length]}");
                    await Task.Delay(120);
                }
            }
            else
            {
                await ToolsStream.Stream("idevicesyslog", new[] { "-u", Udid }, AppendSyslog, register: p => syslogProcess = p);
            }
            SyslogRunning = false; syslogProcess = null; SyslogChanged?.Invoke();
        });
    }

    void AppendSyslog(string line)
    {
        lock (Syslog)
        {
            Syslog.Add(line);
            if (Syslog.Count > 5000) Syslog.RemoveRange(0, Syslog.Count - 5000);
        }
        SyslogChanged?.Invoke();
    }

    public void StopSyslog()
    {
        SyslogRunning = false;
        try { syslogProcess?.Kill(true); } catch { }
    }

    public void ClearSyslog() { lock (Syslog) Syslog.Clear(); SyslogChanged?.Invoke(); }

    // MARK: Battery history

    static string HistoryDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "Battery");
    List<BatterySample>? history; string historyFor = "";

    public List<BatterySample> History
    {
        get
        {
            if (history != null && historyFor == Udid) return history;
            historyFor = Udid;
            if (Demo) return history = DemoHistory();
            try
            {
                var f = Path.Combine(HistoryDir, Udid + ".json");
                history = File.Exists(f) ? JsonSerializer.Deserialize<List<BatterySample>>(File.ReadAllText(f)) ?? new() : new();
            }
            catch { history = new(); }
            return history;
        }
    }

    /// Notes the battery once an hour per phone, the way the Mac does, so the trend builds up over the weeks.
    void RecordBattery()
    {
        var b = session.Battery;
        if (b == null || Udid.Length == 0 || Demo) return;
        if (b.CycleCount == null && b.MaxCapacity == null) return;
        var h = History;
        if (h.Count > 0 && (DateTime.Now - h[^1].Date).TotalSeconds < 3600) return;
        h.Add(new BatterySample { Date = DateTime.Now, Level = b.Level, Charging = b.Charging, CycleCount = b.CycleCount, MaxCapacity = b.MaxCapacity,
            DesignCapacity = b.DesignCapacity, Temperature = b.Temperature, Voltage = b.Voltage });
        if (h.Count > 5000) h.RemoveRange(0, h.Count - 5000);
        try
        {
            Directory.CreateDirectory(HistoryDir);
            var f = Path.Combine(HistoryDir, Udid + ".json");
            File.WriteAllText(f + ".tmp", JsonSerializer.Serialize(h, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(f + ".tmp", f, true);
        }
        catch { }
    }

    static List<BatterySample> DemoHistory()
    {
        var levels = new[] { 100, 82, 64, 91, 47, 73 };
        var list = new List<BatterySample>();
        for (int week = 59; week >= 0; week--)
        {
            var t = (60 - week) / 60.0;
            list.Add(new BatterySample
            {
                Date = DateTime.Now.AddDays(-week * 7), Level = levels[week % 6], Charging = week % 3 == 0,
                CycleCount = (int)(412 * t), MaxCapacity = 4685 - (int)(298 * t), DesignCapacity = 4685,
                Temperature = 27 + week % 5, Voltage = 3.9 + (week % 4) * 0.1,
            });
        }
        return list;
    }

    public static string HistorySpan(List<BatterySample> s)
    {
        if (s.Count < 2) return "Builds up as the phone connects";
        var days = (int)(s[^1].Date - s[0].Date).TotalDays;
        var span = days < 1 ? "today" : days < 60 ? $"{days} days" : $"{days / 30} months";
        return $"{s.Count} readings over {span}";
    }

    public static string Clock(double s)
    {
        var t = (int)Math.Round(s);
        return t >= 3600 ? $"{t / 3600}:{t % 3600 / 60:00}:{t % 60:00}" : $"{t / 60}:{t % 60:00}";
    }
}
