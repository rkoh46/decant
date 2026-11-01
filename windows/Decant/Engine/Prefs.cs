// Small persisted preferences for the Backup and Firmware tabs (the Mac keeps these in AppStorage).
// Stored in %LOCALAPPDATA%\Decant\prefs.json as plain key/value strings.
using System.Text.Json;

namespace Decant.Engine;

public static class Prefs
{
    static readonly string file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "prefs.json");
    static Dictionary<string, string>? values;

    static Dictionary<string, string> Values
    {
        get
        {
            if (values != null) return values;
            try { values = File.Exists(file) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)) : null; } catch { }
            return values ??= new();
        }
    }

    public static string Get(string key, string fallback) => Values.TryGetValue(key, out var v) ? v : fallback;
    public static bool GetBool(string key, bool fallback) => Values.TryGetValue(key, out var v) ? v == "true" : fallback;

    public static void Set(string key, string value)
    {
        Values[key] = value;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, JsonSerializer.Serialize(Values, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
    public static void Set(string key, bool value) => Set(key, value ? "true" : "false");

    public static string Documents => Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    /// "Documents › Decant › Backups": the last three path parts, without the drive and "Users".
    public static string ShortPath(string path)
    {
        var parts = path.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(p => !p.EndsWith(":") && p != "Users").ToList();
        return string.Join(" › ", parts.TakeLast(3));
    }

    public static string Gb(long bytes) => bytes == 0 ? "0 KB" : Format.Gb(bytes);

    /// "2 days ago", "yesterday", "last month": what the Mac's relative date formatter says.
    public static string Relative(DateTime date)
    {
        var span = DateTime.Now - date;
        if (span.TotalMinutes < 1) return "now";
        if (span.TotalHours < 1) { var m = (int)span.TotalMinutes; return m == 1 ? "1 minute ago" : $"{m} minutes ago"; }
        if (span.TotalDays < 1) { var h = (int)span.TotalHours; return h == 1 ? "1 hour ago" : $"{h} hours ago"; }
        if (span.TotalDays < 2) return "yesterday";
        if (span.TotalDays < 7) return $"{(int)span.TotalDays} days ago";
        if (span.TotalDays < 14) return "last week";
        if (span.TotalDays < 30) return $"{(int)(span.TotalDays / 7)} weeks ago";
        if (span.TotalDays < 60) return "last month";
        if (span.TotalDays < 365) return $"{(int)(span.TotalDays / 30)} months ago";
        if (span.TotalDays < 730) return "last year";
        return $"{(int)(span.TotalDays / 365)} years ago";
    }

    public static string Abbrev(DateTime d) => d.ToString("MMM d, yyyy 'at' h:mm tt");
    public static string Complete(DateTime d) => d.ToString("dddd, MMMM d, yyyy 'at' h:mm tt");
}
