// A connected iPhone, seen through the libimobiledevice tools, or the sample phone in demo mode (DECANT_DEMO=1).
namespace Decant.Engine;

public interface IPhone
{
    string Udid { get; }
    Task<DeviceInfo?> Info(CancellationToken ct = default);
    Task<DeviceStorage?> Storage(CancellationToken ct = default);
    Task<BatteryInfo?> Battery(CancellationToken ct = default);
    Task<List<LargeApp>> LargestApps(CancellationToken ct = default);
    Task<List<MediaItem>> CameraRoll(CancellationToken ct = default);
    /// Thumbnail bytes (JPEG) for an item, or null when the phone has none yet.
    Task<byte[]?> Thumbnail(MediaItem item, CancellationToken ct = default);
    /// Copies one item to `localPath`, returning the byte count written, or an error message.
    Task<string?> Copy(MediaItem item, string localPath, CancellationToken ct = default);
    Task<string?> Delete(MediaItem item, CancellationToken ct = default);
    Task<string?> Restart();
    Task<string?> ShutDown();
    Task<string?> Rename(string name);
}

public static class PhoneFinder
{
    public static bool Demo => Environment.GetEnvironmentVariable("DECANT_DEMO") == "1";

    /// The first iPhone on the cable, or null. Needs the Apple Mobile Device Service (from the Apple Devices app or iTunes) running.
    public static async Task<IPhone?> Find(CancellationToken ct = default)
    {
        if (Demo) return new DemoPhone();
        if (!Tools.Available) return null;
        var r = await Tools.Run("idevice_id", new[] { "-l" }, null, ct);
        var udid = r.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).FirstOrDefault(s => s.Length >= 24);
        return udid == null ? null : new UsbPhone(udid);
    }
}

public sealed class UsbPhone : IPhone
{
    public string Udid { get; }
    public UsbPhone(string udid) { Udid = udid; }

    async Task<Dictionary<string, object?>?> Lockdown(string? domain, CancellationToken ct)
    {
        var args = new List<string> { "-u", Udid, "-x" };
        if (domain != null) { args.Add("-q"); args.Add(domain); }
        var r = await Tools.Run("ideviceinfo", args, null, ct);
        return r.Code == 0 ? Plist.Parse(r.Output) : null;
    }

    public async Task<DeviceInfo?> Info(CancellationToken ct = default)
    {
        var g = await Lockdown(null, ct);
        if (g == null) return null;
        string S(string k) => Plist.Str(g.GetValueOrDefault(k));
        var jailbreak = await Task.Run(() => Engine.Jailbreak.Detect(Udid), ct);
        return new DeviceInfo
        {
            Name = S("DeviceName"), Model = S("ProductType"), Version = S("ProductVersion"), Serial = S("SerialNumber"),
            ModelNumber = S("ModelNumber"), Region = S("RegionInfo"), Udid = Udid, Hardware = S("HardwareModel"),
            Ecid = Plist.Long(g.GetValueOrDefault("UniqueChipID"))?.ToString() ?? "",
            WifiAddress = S("WiFiAddress"), BluetoothAddress = S("BluetoothAddress"),
            Activation = S("ActivationState"), Jailbreak = jailbreak,
        };
    }

    public async Task<DeviceStorage?> Storage(CancellationToken ct = default)
    {
        var d = await Lockdown("com.apple.disk_usage.factory", ct) ?? await Lockdown("com.apple.disk_usage", ct);
        if (d == null) return null;
        var cap = Plist.Long(d.GetValueOrDefault("TotalDiskCapacity")) ?? Plist.Long(d.GetValueOrDefault("TotalDataCapacity"));
        var free = Plist.Long(d.GetValueOrDefault("TotalDataAvailable"));
        if (cap == null || free == null) return null;
        var s = new DeviceStorage { Capacity = cap.Value, Free = free.Value };
        s.Photos = Plist.Long(d.GetValueOrDefault("CameraUsage")) ?? Plist.Long(d.GetValueOrDefault("PhotoUsage"));
        s.System = Plist.Long(d.GetValueOrDefault("TotalSystemCapacity"));
        if (s.Photos != null && s.System != null) s.Apps = Math.Max(0, s.Used - s.Photos.Value - s.System.Value);
        return s;
    }

    public async Task<BatteryInfo?> Battery(CancellationToken ct = default)
    {
        var b = new BatteryInfo();
        var lock_ = await Lockdown("com.apple.mobile.battery", ct);
        if (lock_ != null)
        {
            b.Level = (int?)Plist.Long(lock_.GetValueOrDefault("BatteryCurrentCapacity"));
            b.Charging = lock_.GetValueOrDefault("BatteryIsCharging") as bool? ?? false;
            b.ExternalConnected = lock_.GetValueOrDefault("ExternalConnected") as bool? ?? false;
        }
        var r = await Tools.Run("idevicediagnostics", new[] { "-u", Udid, "ioregentry", "AppleSmartBattery" }, null, ct);
        var diag = r.Code == 0 ? Plist.Parse(r.Output) : null;
        if (diag != null)
        {
            int? I(string k) => (int?)Plist.Long(Plist.Find(diag, k));
            b.CycleCount = I("CycleCount"); b.DesignCapacity = I("DesignCapacity");
            b.MaxCapacity = I("NominalChargeCapacity") ?? I("AppleRawMaxCapacity");
            if (I("Temperature") is int t) b.Temperature = t / 100.0;
            if (I("Voltage") is int v) b.Voltage = v / 1000.0;
            if ((I("InstantAmperage") ?? I("Amperage")) is int a && a > 0) b.Amperage = a / 1000.0;
            if (Plist.Find(diag, "AdapterDetails") is Dictionary<string, object?> ad)
            {
                b.AdapterWatts = (int?)Plist.Long(ad.GetValueOrDefault("Watts"));
                b.AdapterName = Plist.Str(ad.GetValueOrDefault("Description") ?? ad.GetValueOrDefault("Name"));
                if (b.AdapterName == "") b.AdapterName = null;
            }
        }
        return lock_ == null && diag == null ? null : b;
    }

    /// The Apps tab's service measures every app; the dashboard shows the nine largest from the same pass.
    public async Task<List<LargeApp>> LargestApps(CancellationToken ct = default)
    {
        var svc = Views.AppsPage.Service;
        if (svc.Apps.Count == 0 && !svc.Loading && !svc.Measuring) await svc.Load(Udid, false);
        return svc.Apps.Where(a => a.TotalSize > 0).OrderByDescending(a => a.TotalSize).Take(9)
            .Select(a => new LargeApp { Name = a.Name, Bytes = a.TotalSize }).ToList();
    }

    static readonly string[] imageExt = { ".HEIC", ".JPG", ".JPEG", ".PNG", ".DNG", ".GIF", ".WEBP" };
    static readonly string[] videoExt = { ".MOV", ".MP4", ".M4V" };

    Afc? afc;
    Afc? Session(out string? error)
    {
        error = null;
        if (afc != null) return afc;
        afc = Afc.Open(Udid, out error);
        return afc;
    }

    public Task<List<MediaItem>> CameraRoll(CancellationToken ct = default) => Task.Run(() =>
    {
        var items = new List<MediaItem>();
        var a = Session(out _);
        if (a == null) return items;
        foreach (var folder in a.List("/DCIM").Where(f => a.Stat("/DCIM/" + f)?.IsDirectory == true))
        {
            ct.ThrowIfCancellationRequested();
            var names = new HashSet<string>(a.List($"/DCIM/{folder}"));
            foreach (var name in names)
            {
                var ext = Path.GetExtension(name).ToUpperInvariant();
                bool video = videoExt.Contains(ext), image = imageExt.Contains(ext);
                if (!video && !image) continue;
                var stem = Path.GetFileNameWithoutExtension(name);
                // A .MOV beside a still with the same name is the still's Live Photo movie; it is shown with the still.
                if (video && imageExt.Any(x => names.Contains(stem + x))) continue;
                var st = a.Stat($"/DCIM/{folder}/{name}");
                if (st == null || st.IsDirectory) continue;
                items.Add(new MediaItem
                {
                    Name = name, RemotePath = $"/DCIM/{folder}/{name}", Size = st.Size, Date = st.Modified, IsVideo = video,
                    IsLivePhoto = image && names.Contains(stem + ".MOV"),
                    ThumbnailPath = $"/PhotoData/Thumbnails/V2/DCIM/{folder}/{name}/5003.JPG",
                });
            }
        }
        return items.OrderByDescending(i => i.Date ?? DateTime.MinValue).ToList();
    }, ct);

    public Task<byte[]?> Thumbnail(MediaItem item, CancellationToken ct = default) => Task.Run(() =>
    {
        if (item.ThumbnailPath == null) return null;
        var tmp = Path.Combine(Path.GetTempPath(), "Decant", "thumbs", item.Name + ".jpg");
        Directory.CreateDirectory(Path.GetDirectoryName(tmp)!);
        if (!File.Exists(tmp))
        {
            var a = Session(out _);
            if (a == null || a.Download(item.ThumbnailPath, tmp, out _, ct) < 0) { try { File.Delete(tmp); } catch { } return null; }
        }
        return File.ReadAllBytes(tmp);
    }, ct);

    public Task<string?> Copy(MediaItem item, string localPath, CancellationToken ct = default) => Task.Run(() =>
    {
        var a = Session(out var err);
        if (a == null) return err ?? "no file service";
        var n = a.Download(item.RemotePath, localPath, out err, ct);
        if (n < 0) { try { File.Delete(localPath); } catch { } return err; }
        if (n != item.Size) { try { File.Delete(localPath); } catch { } return $"size mismatch: {n} of {item.Size} bytes"; }
        return null;
    }, ct);

    public Task<string?> Delete(MediaItem item, CancellationToken ct = default) => Task.Run(() =>
    {
        var a = Session(out var err);
        if (a == null) return err ?? "no file service";
        return a.Remove(item.RemotePath) ? null : "the phone refused the delete (iCloud Photos on?)";
    }, ct);

    async Task<string?> Diagnostics(string cmd) { var r = await Tools.Run("idevicediagnostics", new[] { "-u", Udid, cmd }); return r.Code == 0 ? null : r.Error.Trim(); }
    public Task<string?> Restart() => Diagnostics("restart");
    public Task<string?> ShutDown() => Diagnostics("shutdown");
    public async Task<string?> Rename(string name) { var r = await Tools.Run("idevicename", new[] { "-u", Udid, name }); return r.Code == 0 ? null : r.Error.Trim(); }
}
