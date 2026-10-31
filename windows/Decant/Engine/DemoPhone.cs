// Sample data for screenshots and demos: DECANT_DEMO=1 shows a complete iPhone that does not exist, so the app can be
// photographed without anyone's photos or serial numbers on screen. Photos come from Windows' own wallpapers.
namespace Decant.Engine;

public sealed class DemoPhone : IPhone
{
    public string Udid => "00008140-000A1C2E3F4G5H6I";
    public const string Name = "Sam's iPhone";
    static string name = Name;

    public Task<DeviceInfo?> Info(CancellationToken ct = default) => Task.FromResult<DeviceInfo?>(new DeviceInfo
    {
        Name = name, Model = "iPhone17,2", Version = "26.1", Serial = "F2LXK9Q1P7M3", ModelNumber = "MYWX3LL/A", Region = "LL/A",
        Udid = Udid, Hardware = "D94AP", Ecid = "1234567890123456", WifiAddress = "a4:83:e7:2b:91:0c", BluetoothAddress = "a4:83:e7:2b:91:0d",
    });

    public Task<DeviceStorage?> Storage(CancellationToken ct = default)
    {
        const long gb = 1_000_000_000;
        return Task.FromResult<DeviceStorage?>(new DeviceStorage
        {
            Capacity = 512 * gb, Free = 182 * gb, Photos = 96 * gb, Apps = 118 * gb, System = 14 * gb, Music = 19 * gb, Messages = 8 * gb, Mail = 2 * gb,
        });
    }

    public Task<BatteryInfo?> Battery(CancellationToken ct = default) => Task.FromResult<BatteryInfo?>(new BatteryInfo
    {
        Level = 78, Charging = true, ExternalConnected = true, CycleCount = 412, DesignCapacity = 4685, MaxCapacity = 4387,
        Temperature = 29.4, Voltage = 4.21, Amperage = 2.9, AdapterWatts = 20, AdapterName = "USB-C PD",
    });

    public Task<List<LargeApp>> LargestApps(CancellationToken ct = default) => Task.FromResult(new List<LargeApp>
    {
        new() { Name = "Music", Bytes = 19_690_000_000 }, new() { Name = "Messages", Bytes = 8_320_000_000 }, new() { Name = "iMovie", Bytes = 5_820_000_000 },
        new() { Name = "Podcasts", Bytes = 4_580_000_000 }, new() { Name = "Safari", Bytes = 3_310_000_000 }, new() { Name = "TV", Bytes = 3_310_000_000 },
        new() { Name = "Books", Bytes = 2_760_000_000 }, new() { Name = "Mail", Bytes = 2_240_000_000 },
    });

    static List<string> Wallpapers()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Web");
        var all = Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*.jpg", SearchOption.AllDirectories).OrderBy(p => p).ToList() : new List<string>();
        var custom = Environment.GetEnvironmentVariable("DECANT_DEMO_PHOTOS");
        if (custom != null && Directory.Exists(custom)) all = Directory.EnumerateFiles(custom).Where(p => p.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".png", StringComparison.OrdinalIgnoreCase)).OrderBy(p => p).ToList();
        return all;
    }

    public Task<List<MediaItem>> CameraRoll(CancellationToken ct = default)
    {
        var files = Wallpapers();
        var items = new List<MediaItem>();
        if (files.Count == 0) return Task.FromResult(items);
        ulong seed = 7;
        int Rnd(int n) { seed = seed * 6364136223846793005UL + 1442695040888963407UL; return (int)((seed >> 33) % (ulong)n); }
        for (int n = 0; n < 120; n++)
        {
            var src = files[n % files.Count];
            var age = n * 21 + Rnd(20);
            var video = n % 9 == 4;
            items.Add(new MediaItem
            {
                Name = string.Format(video ? "IMG_{0:0000}.MOV" : "IMG_{0:0000}.HEIC", 4821 - n),
                RemotePath = src, Size = video ? 48_000_000 + Rnd(200_000_000) : 1_800_000 + Rnd(4_000_000),
                Date = DateTime.Now.AddDays(-age).AddHours(-Rnd(14)), IsVideo = video, IsLivePhoto = !video && n % 4 == 1,
                Duration = video ? 8 + Rnd(90) : 0, Width = video ? 3840 : 4032, Height = video ? 2160 : 3024,
                ThumbnailPath = src, ThumbnailCrop = n % 9,
            });
        }
        return Task.FromResult(items);
    }

    public Task<byte[]?> Thumbnail(MediaItem item, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);   // the view crops the file itself

    public async Task<string?> Copy(MediaItem item, string localPath, CancellationToken ct = default)
    {
        try { await Task.Run(() => File.Copy(item.RemotePath, localPath, true), ct); return null; } catch (Exception e) { return e.Message; }
    }
    public Task<string?> Delete(MediaItem item, CancellationToken ct = default) => Task.FromResult<string?>(null);
    public Task<string?> Restart() => Task.FromResult<string?>(null);
    public Task<string?> ShutDown() => Task.FromResult<string?>(null);
    public Task<string?> Rename(string n) { name = n; return Task.FromResult<string?>(null); }
}
