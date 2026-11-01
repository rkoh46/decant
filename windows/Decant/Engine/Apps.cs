// The Apps tab's engine: the app list in two passes (names fast, sizes slow), icons, install and uninstall.
// Mirrors AppsService in Sources/AppsFiles.swift; talks to the phone through InstallProxy and SpringBoard.
using System.Globalization;

namespace Decant.Engine;

public sealed class InstalledApp
{
    public string BundleId = "", Name = "", Version = "", Developer = "";
    public long StaticSize, DynamicSize;
    public bool FileSharing, System;
    public DateTime? Purchased;
    public long TotalSize => StaticSize + DynamicSize;
}

public sealed class AppsService
{
    public List<InstalledApp> Apps = new();
    public bool Loading, Measuring, Running;
    public string Phase = "";
    public double? Progress;
    public readonly Dictionary<string, string> Icons = new();      // bundle id -> cached PNG path
    public Action<string> Log = _ => { };
    public event Action? Changed;
    void Notify() => Changed?.Invoke();

    static readonly string[] NameAttributes = { "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion", "ApplicationType", "UIFileSharingEnabled", "iTunesMetadata" };
    static readonly string[] SizeAttributes = { "CFBundleIdentifier", "StaticDiskUsage", "DynamicDiskUsage" };

    static List<InstalledApp> Sorted(IEnumerable<InstalledApp> apps) => apps.OrderByDescending(a => a.TotalSize).ThenBy(a => a.Name, Natural.Comparer).ToList();

    public async Task Load(string udid, bool includeSystem)
    {
        if (udid.Length == 0) return;
        Loading = true; Notify();
        if (Session.Demo)
        {
            Apps = Sorted(DemoApps());
            Loading = false; Notify();
            return;
        }
        var previous = Apps.ToDictionary(a => a.BundleId);
        var records = await Task.Run(() =>
        {
            using var ip = InstallProxy.Open(udid, out var err);
            if (ip == null) { Log("Could not read the app list: " + err); return null; }
            return ip.Browse(includeSystem, NameAttributes);
        });
        if (records == null) { Loading = false; Notify(); return; }
        var apps = new List<InstalledApp>();
        foreach (var r in records)
        {
            if (r.GetValueOrDefault("CFBundleIdentifier") is not string id || id.Length == 0) continue;
            var a = new InstalledApp
            {
                BundleId = id,
                Name = r.GetValueOrDefault("CFBundleDisplayName") as string ?? r.GetValueOrDefault("CFBundleName") as string ?? id,
                Version = r.GetValueOrDefault("CFBundleShortVersionString") as string ?? r.GetValueOrDefault("CFBundleVersion") as string ?? "",
                FileSharing = r.GetValueOrDefault("UIFileSharingEnabled") as bool? ?? false,
                System = r.GetValueOrDefault("ApplicationType") as string == "System",
            };
            if (previous.TryGetValue(id, out var old)) { a.StaticSize = old.StaticSize; a.DynamicSize = old.DynamicSize; }
            if (r.GetValueOrDefault("iTunesMetadata") is byte[] blob && BinaryPlist.ParseAny(blob) is Dictionary<string, object?> m)
            {
                a.Developer = m.GetValueOrDefault("artistName") as string ?? "";
                if (m.GetValueOrDefault("com.apple.iTunesStore.downloadInfo") is Dictionary<string, object?> di && di.GetValueOrDefault("purchaseDate") is string pd
                    && DateTime.TryParse(pd, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var dt))
                    a.Purchased = dt.ToLocalTime();
            }
            apps.Add(a);
        }
        Apps = Sorted(apps);
        Loading = false; Notify();
        var icons = LoadIcons(udid);
        Measuring = true; Notify();
        var sizes = await Task.Run(() =>
        {
            using var ip = InstallProxy.Open(udid, out _);
            return ip?.Browse(includeSystem, SizeAttributes);
        });
        if (sizes != null)
        {
            var byId = sizes.Where(s => s.GetValueOrDefault("CFBundleIdentifier") is string).ToDictionary(s => (string)s["CFBundleIdentifier"]!);
            foreach (var a in Apps)
                if (byId.TryGetValue(a.BundleId, out var s))
                {
                    a.StaticSize = Plist.Long(s.GetValueOrDefault("StaticDiskUsage")) ?? 0;
                    a.DynamicSize = Plist.Long(s.GetValueOrDefault("DynamicDiskUsage")) ?? 0;
                }
            Apps = Sorted(Apps);
        }
        Measuring = false; Notify();
        await icons;
    }

    /// Cached icons first, then the missing ones from the phone in chunks of 24.
    async Task LoadIcons(string udid)
    {
        foreach (var a in Apps)
            if (!Icons.ContainsKey(a.BundleId) && File.Exists(SpringBoard.CachePath(a.BundleId))) Icons[a.BundleId] = SpringBoard.CachePath(a.BundleId);
        Notify();
        var missing = Apps.Where(a => !Icons.ContainsKey(a.BundleId)).Select(a => a.BundleId).ToList();
        if (missing.Count == 0 || Session.Demo) return;
        await Task.Run(() =>
        {
            using var sb = SpringBoard.Open(udid, out var err);
            if (sb == null) { Log("App icons: " + err); return; }
            foreach (var chunk in missing.Chunk(24))
            {
                foreach (var id in chunk) if (sb.Save(id)) lock (Icons) Icons[id] = SpringBoard.CachePath(id);
                Notify();
            }
        });
    }

    public async Task Uninstall(string udid, InstalledApp app)
    {
        if (Running) return;
        Running = true; Phase = $"Uninstalling {app.Name}"; Progress = null; Log(Phase); Notify();
        bool ok;
        if (Session.Demo) { await Task.Delay(600); ok = true; }
        else
        {
            ok = await Task.Run(async () =>
            {
                using var ip = InstallProxy.Open(udid, out var err);
                if (ip == null) { Log("Uninstall: " + err); return false; }
                return await ip.Run(false, app.BundleId, line =>
                {
                    if (ToolsStream.Percent(line) is double p) Progress = p;
                    else if (line.Contains("Complete") || line.Contains("ERROR")) Log(line);
                    Notify();
                });
            });
        }
        if (ok) { Phase = $"Uninstalled {app.Name}"; Apps = Apps.Where(a => a.BundleId != app.BundleId).ToList(); }
        else Phase = $"Could not uninstall {app.Name}";
        Log(Phase); Running = false; Notify();
    }

    public async Task Install(string udid, string ipaPath)
    {
        if (Running) return;
        var file = Path.GetFileName(ipaPath);
        Running = true; Phase = $"Installing {file}"; Progress = 0; Log(Phase); Notify();
        string? lastError = null; bool ok;
        if (Session.Demo) { for (int i = 1; i <= 5; i++) { await Task.Delay(200); Progress = i / 5.0; Notify(); } ok = true; }
        else
        {
            ok = await Task.Run(async () =>
            {
                // The package goes to PublicStaging over AFC first; the phone checks the signature itself.
                using var afc = Afc.Open(udid, out var err);
                if (afc == null) { lastError = err; return false; }
                afc.MakeDirectory("/PublicStaging");
                var remote = "/PublicStaging/" + file;
                var up = afc.Upload(ipaPath, remote);
                if (up != null) { lastError = up; return false; }
                using var ip = InstallProxy.Open(udid, out err);
                if (ip == null) { lastError = err; return false; }
                var r = await ip.Run(true, remote, line =>
                {
                    if (ToolsStream.Percent(line) is double p) Progress = p;
                    else if (line.Contains("ERROR") || line.Contains("Error")) { lastError = line; Log(line); }
                    Notify();
                });
                afc.Remove(remote);
                return r;
            });
        }
        Phase = ok ? $"Installed {file}" : $"Install failed: {lastError ?? "the phone refused the package"}";
        Log(Phase); Running = false; Notify();
        await Load(udid, false);
    }

    // Sample apps (the Mac's Demo.apps table); sizes in MB.
    static readonly (string id, string name, int app, int data, bool share)[] DemoTable =
    {
        ("com.apple.mobilesafari", "Safari", 410, 2900, false), ("com.apple.MobileSMS", "Messages", 120, 8200, false), ("com.apple.mobilemail", "Mail", 140, 2100, false),
        ("com.apple.Maps", "Maps", 380, 640, false), ("com.apple.Music", "Music", 290, 19400, false), ("com.apple.mobilenotes", "Notes", 150, 1300, false),
        ("com.apple.podcasts", "Podcasts", 180, 4400, false), ("com.apple.reminders", "Reminders", 60, 12, false), ("com.apple.stocks", "Stocks", 40, 8, false),
        ("com.apple.tv", "TV", 210, 3100, false), ("com.apple.weather", "Weather", 70, 24, false), ("com.apple.iBooks", "Books", 160, 2600, true),
        ("com.apple.mobilecal", "Calendar", 50, 30, false), ("com.apple.MobileAddressBook", "Contacts", 30, 18, false), ("com.apple.facetime", "FaceTime", 40, 6, false),
        ("com.apple.freeform", "Freeform", 120, 410, false), ("com.apple.Home", "Home", 90, 44, false), ("com.apple.news", "News", 130, 980, false),
        ("com.apple.shortcuts", "Shortcuts", 110, 60, false), ("com.apple.VoiceMemos", "Voice Memos", 30, 720, true), ("com.apple.findmy", "Find My", 60, 10, false),
        ("com.apple.calculator", "Calculator", 10, 1, false), ("com.apple.Keynote", "Keynote", 690, 1200, true), ("com.apple.Numbers", "Numbers", 540, 300, true),
        ("com.apple.Pages", "Pages", 580, 860, true), ("com.apple.garageband", "GarageBand", 1700, 2400, true), ("com.apple.iMovie", "iMovie", 720, 5100, true),
        ("com.apple.PhotoBooth", "Photo Booth", 90, 300, false),
    };

    static IEnumerable<InstalledApp> DemoApps() => DemoTable.Select((t, i) => new InstalledApp
    {
        BundleId = t.id, Name = t.name, Version = $"{18 + i % 9}.{i % 4}", StaticSize = t.app * 1_000_000L, DynamicSize = t.data * 1_000_000L,
        FileSharing = t.share, Developer = "Apple", Purchased = DateTime.Now.AddDays(-(40 + i * 37)),
    });
}
