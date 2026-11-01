// Backups: the folders on disk, and idevicebackup2 for making, restoring and encrypting them. Mirrors BackupService in
// the Mac's Toolkit.swift. Decant's own backups live in Documents\Decant\Backups\<yyyy-MM-dd HHmm>\<UDID>; iTunes and
// the Apple Devices app keep theirs under MobileSync\Backup.
using System.Diagnostics;

namespace Decant.Engine;

public sealed record BackupInfo(string Path, DateTime Date, long Size, string DeviceName, string Version, bool Encrypted)
{
    public string Id => Path;
}

public sealed class BackupService
{
    public static string DefaultRoot => System.IO.Path.Combine(Prefs.Documents, "Decant", "Backups");
    public static readonly string[] ItunesRoots =
    {
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Apple Computer", "MobileSync", "Backup"),
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Apple", "MobileSync", "Backup"),
    };

    public List<BackupInfo> Backups = new();
    public List<BackupInfo> ItunesBackups = new();
    public bool ItunesReadable = true;
    public bool Running;
    public string Phase = "";
    public double? Progress;
    public bool? WillEncrypt, WifiSync;
    public string SettingsFor = "";
    public Action<string> Log = _ => { };
    public event Action? Changed;
    Process? process;

    void Notify() => Changed?.Invoke();

    // MARK: Folders

    static IEnumerable<string> BackupDirs(string root)
    {
        if (!Directory.Exists(root)) yield break;
        foreach (var child in Directory.EnumerateDirectories(root))
        {
            if (File.Exists(System.IO.Path.Combine(child, "Info.plist"))) { yield return child; continue; }
            IEnumerable<string> grand;
            try { grand = Directory.EnumerateDirectories(child).ToList(); } catch { continue; }
            foreach (var g in grand) if (File.Exists(System.IO.Path.Combine(g, "Info.plist"))) yield return g;
        }
    }

    static long FolderSize(string dir)
    {
        long total = 0;
        try { foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)) { try { total += new FileInfo(f).Length; } catch { } } } catch { }
        return total;
    }

    /// The backup in `folder` (or in its first subfolder that has an Info.plist), or null when it is not one.
    public static BackupInfo? Info(string folder)
    {
        var dir = folder;
        if (!File.Exists(System.IO.Path.Combine(dir, "Info.plist")))
        {
            try { dir = Directory.EnumerateDirectories(folder).FirstOrDefault(d => File.Exists(System.IO.Path.Combine(d, "Info.plist"))) ?? ""; } catch { return null; }
            if (dir == "") return null;
        }
        Dictionary<string, object?>? info;
        try { info = BinaryPlist.ParseAny(File.ReadAllBytes(System.IO.Path.Combine(dir, "Info.plist"))) as Dictionary<string, object?>; } catch { return null; }
        if (info == null) return null;
        var date = info.GetValueOrDefault("Last Backup Date") is DateTime dt ? dt.ToLocalTime() : Directory.GetLastWriteTime(dir);
        var name = Plist.Str(info.GetValueOrDefault("Device Name"));
        if (name == "") name = System.IO.Path.GetFileName(dir);
        var version = Plist.Str(info.GetValueOrDefault("Product Version"));
        var encrypted = false;
        try
        {
            var mp = System.IO.Path.Combine(dir, "Manifest.plist");
            if (File.Exists(mp) && BinaryPlist.ParseAny(File.ReadAllBytes(mp)) is Dictionary<string, object?> m) encrypted = m.GetValueOrDefault("IsEncrypted") as bool? ?? false;
        }
        catch { }
        return new BackupInfo(dir, date, FolderSize(dir), name, version, encrypted);
    }

    public void Scan(string root)
    {
        if (Session.Demo)
        {
            Backups = DemoBackups.Backups(); ItunesBackups = DemoBackups.ItunesBackups(); ItunesReadable = true;
            Notify(); return;
        }
        var itunes = new List<BackupInfo>();
        ItunesReadable = true;
        foreach (var r in ItunesRoots)
        {
            if (!Directory.Exists(r)) continue;
            try { foreach (var d in Directory.EnumerateDirectories(r)) if (Info(d) is BackupInfo b) itunes.Add(b); }
            catch { ItunesReadable = false; }
        }
        ItunesBackups = itunes.OrderByDescending(b => b.Date).ToList();
        var own = new List<BackupInfo>();
        foreach (var d in BackupDirs(root)) if (Info(d) is BackupInfo b) own.Add(b);
        Backups = own.OrderByDescending(b => b.Date).ToList();
        Notify();
    }

    // MARK: Settings on the phone

    public async Task ReadSettings(string udid)
    {
        if (Session.Demo) { WillEncrypt = true; WifiSync = true; SettingsFor = udid; Notify(); return; }
        bool? Flag(Tools.Result r) => r.Code != 0 ? null : r.Output.Trim().ToLowerInvariant() switch { "true" => true, "false" => false, _ => null };
        WillEncrypt = Flag(await Tools.Run("ideviceinfo", new[] { "-u", udid, "-q", "com.apple.mobile.backup", "-k", "WillEncrypt" }));
        WifiSync = Flag(await Tools.Run("ideviceinfo", new[] { "-u", udid, "-q", "com.apple.mobile.wireless_lockdown", "-k", "EnableWifiConnections" }));
        SettingsFor = udid;
        Notify();
    }

    async Task<bool> RunLogged(string tool, string[] args)
    {
        var failed = false;
        var code = await ToolsStream.Stream(tool, args, line =>
        {
            Log(line);
            var l = line.ToLowerInvariant();
            if (l.Contains("error") || l.Contains("fail")) failed = true;
        }, register: p => process = p);
        process = null;
        return code == 0 && !failed;
    }

    public async Task SetEncryption(bool on, string password, string udid)
    {
        if (Running) return;
        Running = true; Progress = null; Phase = on ? "Turning on backup encryption" : "Turning off backup encryption"; Notify();
        bool ok;
        if (Session.Demo) { await Task.Delay(600); WillEncrypt = on; ok = true; }
        else
        {
            ok = await RunLogged("idevicebackup2", new[] { "-u", udid, "encryption", on ? "on" : "off", password });
            await ReadSettings(udid);
            ok = ok && WillEncrypt == on;
        }
        Phase = ok ? "" : on ? "Could not turn encryption on" : "Could not turn encryption off (wrong password?)";
        Running = false; Notify();
    }

    public async Task ChangePassword(string oldPw, string newPw, string udid)
    {
        if (Running) return;
        Running = true; Progress = null; Phase = "Changing the backup password"; Notify();
        var ok = Session.Demo ? true : await RunLogged("idevicebackup2", new[] { "-u", udid, "changepw", oldPw, newPw });
        if (Session.Demo) await Task.Delay(600);
        Phase = ok ? "" : "Could not change the password (wrong current password?)";
        Running = false; Notify();
    }

    public async Task SetWifiSync(bool on, string udid)
    {
        if (Running) return;
        Running = true; Progress = null; Phase = on ? "Allowing backups over Wi-Fi" : "Turning Wi-Fi backups off"; Notify();
        bool ok;
        if (Session.Demo) { await Task.Delay(400); WifiSync = on; ok = true; }
        else
        {
            var code = await ToolsStream.Stream("idevicepair", new[] { "-u", udid, "wifi", on ? "on" : "off" }, Log);
            await ReadSettings(udid);
            ok = code == 0;
        }
        Phase = ok ? "" : "The phone did not accept the change";
        Running = false; Notify();
    }

    // MARK: Backup and restore

    public async Task Backup(string udid, string root, bool network)
    {
        if (Running) return;
        Running = true; Progress = 0; Phase = "Preparing"; Notify();
        if (Session.Demo)
        {
            Phase = network ? "Backing up over Wi-Fi" : "Backing up";
            for (int i = 0; i <= 20; i++) { Progress = i / 20.0; Notify(); await Task.Delay(150); }
            Phase = "Backup finished"; Log(Phase); Running = false; Notify();
            return;
        }
        var dest = System.IO.Path.Combine(root, DateTime.Now.ToString("yyyy-MM-dd HHmm"));
        Directory.CreateDirectory(dest);
        Log($"Backup to {dest}" + (network ? " over Wi-Fi" : ""));
        Phase = network ? "Backing up over Wi-Fi" : "Backing up"; Notify();
        var args = new List<string>();
        if (network) args.Add("-n");
        args.AddRange(new[] { "-u", udid, "backup", "--full", dest });
        var code = await ToolsStream.Stream("idevicebackup2", args, line =>
        {
            if (ToolsStream.Percent(line) is double p) { Progress = p; Notify(); } else Log(line);
        }, register: p => process = p);
        process = null;
        Phase = code == 0 ? "Backup finished" : "Backup failed";
        Log(Phase);
        Running = false; Notify();
        Scan(root);
    }

    public async Task Restore(BackupInfo backup, string udid, string? password)
    {
        if (Running) return;
        Running = true; Progress = 0; Phase = "Restoring"; Notify();
        Log($"Restore from {backup.Path}");
        var args = new List<string> { "-u", udid, "restore", "--system", "--settings", "--reboot" };
        if (password != null) { args.Add("--password"); args.Add(password); }
        args.Add(System.IO.Path.GetDirectoryName(backup.Path) ?? backup.Path);
        var code = await ToolsStream.Stream("idevicebackup2", args, line =>
        {
            if (ToolsStream.Percent(line) is double p) { Progress = p; Notify(); } else Log(line);
        }, register: p => process = p);
        process = null;
        Phase = code == 0 ? "Restore finished, the iPhone is rebooting" : "Restore failed";
        Log(Phase);
        Running = false; Notify();
    }

    public void Cancel() { try { process?.Kill(true); } catch { } }

    /// Moves a Decant backup (its dated folder) to the Recycle Bin.
    public void Delete(BackupInfo backup, string root)
    {
        var target = backup.Path;
        var parent = System.IO.Path.GetDirectoryName(target);
        if (parent != null && !string.Equals(System.IO.Path.GetFullPath(parent).TrimEnd('\\'), System.IO.Path.GetFullPath(root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            target = parent;
        try
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(target, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            Log($"Moved {target} to the Recycle Bin");
        }
        catch (Exception e) { Log($"Could not delete {target}: {e.Message}"); }
        Scan(root);
    }
}

/// The sample backups the Mac demo shows.
public static class DemoBackups
{
    static DateTime DaysAgo(double n) => DateTime.Now.AddDays(-n);
    const string Udid = "00008140-000A1C2E3F4G5H6I";
    static string Root => Path.Combine(Prefs.Documents, "Decant", "Backups");

    public static List<BackupInfo> Backups() => new()
    {
        new(Path.Combine(Root, "2026-10-28 2210", Udid), DaysAgo(2.2), 61_400_000_000, DemoPhone.Name, "26.1", true),
        new(Path.Combine(Root, "2026-09-30 0905", Udid), DaysAgo(30.6), 58_900_000_000, DemoPhone.Name, "26.0.1", true),
    };

    public static List<BackupInfo> ItunesBackups() => new()
    {
        new(Path.Combine(BackupService.ItunesRoots[1], Udid), DaysAgo(74), 52_100_000_000, DemoPhone.Name, "18.6.2", false),
    };

    public static BackupSummary Summary() => new()
    {
        Messages = 48_212, Conversations = 163, Contacts = 412, Calls = 2_874, Notes = 231, VoiceMemos = 38,
        SafariHistory = 19_440, WhatsappChats = 57, WhatsappMessages = 31_905,
    };
}
