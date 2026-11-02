// The things Decant knows about a phone. Mirrors Sources/Device.swift on the Mac.
namespace Decant.Engine;

public sealed class DeviceInfo
{
    public string Name = "", Model = "", Version = "", Serial = "", ModelNumber = "", Region = "", Udid = "", Hardware = "", Ecid = "";
    public string WifiAddress = "", BluetoothAddress = "";
    public string Activation = "";          // lockdown ActivationState: Activated / Unactivated
    public string? Jailbreak;               // null: not checked; "": none found; otherwise the jailbreak's name
    public string MarketingName => Names.TryGetValue(Model, out var n) ? n : Model;

    public static readonly Dictionary<string, string> Names = new()
    {
        ["iPhone12,1"] = "iPhone 11", ["iPhone12,3"] = "iPhone 11 Pro", ["iPhone12,5"] = "iPhone 11 Pro Max", ["iPhone12,8"] = "iPhone SE (2nd gen)",
        ["iPhone13,1"] = "iPhone 12 mini", ["iPhone13,2"] = "iPhone 12", ["iPhone13,3"] = "iPhone 12 Pro", ["iPhone13,4"] = "iPhone 12 Pro Max",
        ["iPhone14,4"] = "iPhone 13 mini", ["iPhone14,5"] = "iPhone 13", ["iPhone14,2"] = "iPhone 13 Pro", ["iPhone14,3"] = "iPhone 13 Pro Max",
        ["iPhone14,6"] = "iPhone SE (3rd gen)", ["iPhone14,7"] = "iPhone 14", ["iPhone14,8"] = "iPhone 14 Plus",
        ["iPhone15,2"] = "iPhone 14 Pro", ["iPhone15,3"] = "iPhone 14 Pro Max", ["iPhone15,4"] = "iPhone 15", ["iPhone15,5"] = "iPhone 15 Plus",
        ["iPhone16,1"] = "iPhone 15 Pro", ["iPhone16,2"] = "iPhone 15 Pro Max", ["iPhone17,3"] = "iPhone 16", ["iPhone17,4"] = "iPhone 16 Plus",
        ["iPhone17,1"] = "iPhone 16 Pro", ["iPhone17,2"] = "iPhone 16 Pro Max", ["iPhone17,5"] = "iPhone 16e", ["iPhone18,3"] = "iPhone 17",
    };

    /// What the model looks like from the front: notch or island, by identifier generation.
    public bool HasIsland
    {
        get
        {
            var m = Model.Replace("iPhone", "");
            var major = int.TryParse(m.Split(',')[0], out var v) ? v : 0;
            if (Model is "iPhone15,2" or "iPhone15,3") return true;          // 14 Pro
            return major >= 16;                                              // 15 and newer
        }
    }
}

public sealed class DeviceStorage
{
    public long Capacity, Free;
    public long? Photos, Apps, System, Music, Messages, Mail;
    public long Used => Capacity - Free;
}

public sealed class BatteryInfo
{
    public int? Level;
    public bool Charging, ExternalConnected;
    public int? CycleCount, DesignCapacity, MaxCapacity, AdapterWatts;
    public double? Temperature, Voltage, Amperage;
    public string? AdapterName;
    public int? Health => DesignCapacity > 0 && MaxCapacity > 0 ? (int)Math.Round(100.0 * MaxCapacity.Value / DesignCapacity.Value) : null;
    public double? Watts => Voltage > 0 && Amperage > 0 ? Voltage * Amperage : null;
}

public sealed class LargeApp
{
    public string Name = "";
    public long Bytes;
}

public sealed class MediaItem
{
    public string Name = "";           // IMG_0001.HEIC
    public string RemotePath = "";     // /DCIM/100APPLE/IMG_0001.HEIC on the phone, or a local file in demo mode
    public long Size;
    public DateTime? Date;
    public bool IsVideo, IsLivePhoto;
    public double Duration;
    public int Width, Height;
    public string? ThumbnailPath;      // demo: local file; phone: /PhotoData thumbnail path
    public int? ThumbnailCrop;         // demo: which of nine windows into the image
    public string Format => Path.GetExtension(Name).TrimStart('.').ToUpperInvariant();
}

public static class Format
{
    public static string Gb(long bytes) => bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.##} GB" : bytes >= 1_000_000 ? $"{bytes / 1e6:0.#} MB" : $"{bytes / 1e3:0} KB";
    public static string Count(int n) => n.ToString("N0");
    public static string Duration(double s) => s >= 3600 ? $"{(int)s / 3600}:{(int)s % 3600 / 60:00}:{(int)s % 60:00}" : $"{(int)s / 60}:{(int)s % 60:00}";
}
