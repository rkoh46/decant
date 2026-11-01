// The Files tab's engine: the Media folder or one app's documents over AFC. Mirrors FilesService in AppsFiles.swift.
using System.Globalization;

namespace Decant.Engine;

public sealed class RemoteEntry
{
    public string Name = "";
    public bool IsDirectory;
    public long Size;
    public DateTime? Modified;
}

public abstract record FileRoot(string Title)
{
    public sealed record Media() : FileRoot("Media");
    public sealed record Ringtones() : FileRoot("Ringtones");
    public sealed record AppDocuments(string BundleId, string DisplayName) : FileRoot(DisplayName);
}

public sealed class FilesService
{
    public List<RemoteEntry> Entries = new();
    public string Path_ = "/";
    public FileRoot Root = new FileRoot.Media();
    public bool Loading, Running;
    public string Phase = "";
    public Action<string> Log = _ => { };
    public event Action? Changed;
    void Notify() => Changed?.Invoke();

    /// house_arrest exposes the app container; its Documents folder is the part the user may touch.
    public string HomePath => Root is FileRoot.AppDocuments ? "/Documents" : "/";

    public static string Join(string path, string name) => path.TrimEnd('/') + "/" + name;

    Afc? Open(string udid, out string? error)
    {
        error = null;
        return Root is FileRoot.AppDocuments ad ? Afc.OpenHouseArrest(udid, ad.BundleId, out error) : Afc.Open(udid, out error);
    }

    public async Task List(string udid)
    {
        Loading = true; Notify();
        if (Session.Demo) { Entries = DemoFiles(Root, Path_); Loading = false; Notify(); return; }
        var path = Path_;
        var result = await Task.Run(() =>
        {
            using var afc = Open(udid, out var err);
            if (afc == null) return (null, err);
            var names = afc.TryList(path);
            if (names == null) return (null, "could not read the folder");
            var list = new List<RemoteEntry>();
            foreach (var n in names)
            {
                var st = afc.Stat(Join(path, n));
                if (st == null) continue;
                list.Add(new RemoteEntry { Name = n, IsDirectory = st.IsDirectory, Size = st.IsDirectory ? 0 : st.Size, Modified = st.Modified });
            }
            return ((List<RemoteEntry>?)list, (string?)null);
        });
        if (result.Item1 == null) { Log($"{Root.Title}{path}: {result.Item2}"); Entries = new(); }
        else Entries = result.Item1.OrderByDescending(e => e.IsDirectory).ThenBy(e => e.Name, Natural.Comparer).ToList();
        Loading = false; Notify();
    }

    public async Task Open(string udid, RemoteEntry e)
    {
        if (!e.IsDirectory) return;
        Path_ = Join(Path_, e.Name);
        await List(udid);
    }

    public async Task Up(string udid)
    {
        if (Path_ == HomePath) return;
        var parent = Path_.Contains('/') ? Path_[..Path_.LastIndexOf('/')] : "";
        if (parent.Length == 0 || parent.Length < HomePath.Length) parent = HomePath;
        Path_ = parent;
        await List(udid);
    }

    static string Plural(int n) => n == 1 ? "item" : "items";

    public async Task Download(string udid, IList<RemoteEntry> entries, string localDir)
    {
        Running = true; Phase = $"Downloading {entries.Count} {Plural(entries.Count)}"; Notify();
        var path = Path_;
        if (Session.Demo) await Task.Delay(500);
        else await Task.Run(() =>
        {
            using var afc = Open(udid, out var err);
            if (afc == null) { Log($"Download: {err}"); return; }
            foreach (var e in entries)
            {
                var r = afc.DownloadTree(Join(path, e.Name), Path.Combine(localDir, e.Name));
                if (r != null) Log($"{e.Name}: {r}");
            }
        });
        Phase = $"Downloaded to {Path.GetFileName(localDir.TrimEnd('\\'))}";
        Log($"Downloaded {entries.Count} items from {Root.Title}{path} to {localDir}");
        Running = false; Notify();
    }

    public async Task Upload(string udid, IList<string> localPaths)
    {
        Running = true; Phase = $"Uploading {localPaths.Count} {Plural(localPaths.Count)}"; Notify();
        var path = Path_;
        if (Session.Demo)
        {
            await Task.Delay(400);
            foreach (var p in localPaths)
            {
                var fi = new FileInfo(p);
                Entries.Add(new RemoteEntry { Name = Path.GetFileName(p), IsDirectory = Directory.Exists(p), Size = fi.Exists ? fi.Length : 0, Modified = DateTime.Now });
            }
        }
        else await Task.Run(() =>
        {
            using var afc = Open(udid, out var err);
            if (afc == null) { Log($"Upload: {err}"); return; }
            foreach (var p in localPaths)
            {
                var r = afc.UploadTree(p, Join(path, Path.GetFileName(p)));
                if (r != null) Log($"{Path.GetFileName(p)}: {r}");
            }
        });
        Phase = "Uploaded";
        Log($"Uploaded {localPaths.Count} items to {Root.Title}{path}");
        Running = false; Notify();
        if (!Session.Demo) await List(udid); else Notify();
    }

    public async Task Delete(string udid, IList<RemoteEntry> entries)
    {
        Running = true; Phase = "Deleting"; Notify();
        var path = Path_;
        if (Session.Demo) { await Task.Delay(300); Entries = Entries.Where(e => !entries.Contains(e)).ToList(); }
        else await Task.Run(() =>
        {
            using var afc = Open(udid, out var err);
            if (afc == null) { Log($"Delete: {err}"); return; }
            foreach (var e in entries)
                if (!afc.RemoveTree(Join(path, e.Name))) Log($"{e.Name}: the phone refused the delete");
        });
        Log($"Deleted {entries.Count} items in {Root.Title}{path}");
        Running = false; Notify();
        if (!Session.Demo) await List(udid); else Notify();
    }

    public async Task NewFolder(string udid, string name)
    {
        var path = Path_;
        if (Session.Demo) { Entries.Insert(0, new RemoteEntry { Name = name, IsDirectory = true, Modified = DateTime.Now }); Notify(); return; }
        await Task.Run(() => { using var afc = Open(udid, out _); afc?.MakeDirectory(Join(path, name)); });
        await List(udid);
    }

    // Sample folders (the Mac's Demo.files).
    static RemoteEntry D(string n, int days) => new() { Name = n, IsDirectory = true, Modified = DateTime.Now.AddDays(-days) };
    static RemoteEntry F(string n, long size, int days) => new() { Name = n, Size = size, Modified = DateTime.Now.AddDays(-days) };

    static List<RemoteEntry> DemoFiles(FileRoot root, string path)
    {
        switch (root)
        {
            case FileRoot.Media:
                return path switch
                {
                    "/" => new() { D("Books", 40), D("DCIM", 1), D("Downloads", 3), D("iTunes_Control", 2), D("PhotoData", 1), D("Podcasts", 5), D("Purchases", 30), D("Recordings", 12), D("Ringtones", 90) },
                    "/DCIM" => new() { D("100APPLE", 400), D("101APPLE", 200), D("102APPLE", 60), D("103APPLE", 1) },
                    "/Downloads" => new() { F("Flight itinerary.pdf", 184_000, 3), F("Receipt 2026-10-12.pdf", 92_000, 18), F("Lease.pdf", 1_240_000, 160) },
                    "/Recordings" => new() { F("20261019 143022.m4a", 4_200_000, 12), F("20260903 091500.m4a", 12_400_000, 58), F("CloudRecordings.db", 98_304, 12) },
                    _ => new(),
                };
            case FileRoot.AppDocuments ad:
                return ad.DisplayName == "Books"
                    ? new() { F("Dune.epub", 1_900_000, 40), F("Project Hail Mary.epub", 1_300_000, 120) }
                    : new() { D("Projects", 4), F("Untitled.key", 2_400_000, 4), F("Budget 2026.numbers", 310_000, 22) };
            default: return new();
        }
    }
}
