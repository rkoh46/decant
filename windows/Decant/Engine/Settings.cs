// Where photos go. Stored in %LOCALAPPDATA%\Decant\settings.json; nothing is tied to a drive.
using System.Text.Json;

namespace Decant.Engine;

public sealed class Settings
{
    public string PhotosFolder { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
    public string AppsSort { get; set; } = "size";          // Apps tab order: size, data, name or date

    static readonly string file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "settings.json");
    public static Settings Load()
    {
        try { if (File.Exists(file)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(file)) ?? new(); } catch { }
        return new();
    }
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public static long? FreeSpace(string path)
    {
        try
        {
            var p = path;
            while (!Directory.Exists(p)) { var parent = Path.GetDirectoryName(p); if (parent == null || parent == p) break; p = parent; }
            var root = Path.GetPathRoot(p);
            return root == null ? null : new DriveInfo(root).AvailableFreeSpace;
        }
        catch { return null; }
    }

    /// Photos are filed by year and month of capture, like the Mac app: Pictures\2025\03\IMG_0001.HEIC.
    public static string DateFolder(string root, DateTime? date) =>
        date == null ? Path.Combine(root, "Undated") : Path.Combine(root, date.Value.ToString("yyyy"), date.Value.ToString("MM"));
}
