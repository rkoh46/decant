// Custom ringtones: files in /iTunes_Control/Ringtones plus the entries in /iTunes_Control/iTunes/Ringtones.plist.
// Mirrors RingtoneService in Sources/Ringtones.swift; conversion uses Windows' MediaTranscoder (AAC in .m4a).
using System.Globalization;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace Decant.Engine;

public sealed class Ringtone
{
    public string File = "", Name = "";
    public double Duration;
    public long Pid;
}

public sealed class RingtoneService
{
    public const string Dir = "/iTunes_Control/Ringtones";
    public const string PlistPath = "/iTunes_Control/iTunes/Ringtones.plist";

    public List<Ringtone> Tones = new();
    public bool Loaded, Loading, Running;
    public string Phase = "";
    public Action<string> Log = _ => { };
    public event Action? Changed;
    void Notify() => Changed?.Invoke();


    static Dictionary<string, object?> ReadPlist(Afc afc)
    {
        var bytes = afc.ReadAll(PlistPath);
        return bytes != null && BinaryPlist.ParseAny(bytes) is Dictionary<string, object?> d ? d : new();
    }

    bool WritePlist(Afc afc, Dictionary<string, object?> p)
    {
        afc.MakeDirectory("/iTunes_Control/iTunes");
        var err = afc.WriteAll(PlistPath, System.Text.Encoding.UTF8.GetBytes(Plist.ToXml(p)));
        if (err != null) Log($"Ringtones.plist: {err}");
        return err == null;
    }

    public async Task Load(string udid)
    {
        Loading = true; Notify();
        if (Session.Demo)
        {
            if (!Loaded) Tones = new()
            {
                new() { File = "Morning Light.m4r", Name = "Morning Light", Duration = 30, Pid = 1 },
                new() { File = "Bell Tower.m4r", Name = "Bell Tower", Duration = 24, Pid = 2 },
                new() { File = "Front Desk.m4r", Name = "Front Desk", Duration = 30, Pid = 3 },
            };
            Loaded = true; Loading = false; Notify(); return;
        }
        var tones = await Task.Run(() =>
        {
            using var afc = Afc.Open(udid, out var err);
            if (afc == null) { Log($"Ringtones: {err}"); return null; }
            var list = new List<Ringtone>();
            if (ReadPlist(afc).GetValueOrDefault("Ringtones") is Dictionary<string, object?> rt)
                foreach (var (file, v) in rt)
                    if (v is Dictionary<string, object?> d)
                        list.Add(new Ringtone
                        {
                            File = file, Name = d.GetValueOrDefault("Name") as string ?? Path.GetFileNameWithoutExtension(file),
                            Duration = (Plist.Long(d.GetValueOrDefault("Total Time")) ?? 0) / 1000.0, Pid = Plist.Long(d.GetValueOrDefault("PID")) ?? 0,
                        });
            foreach (var n in afc.List(Dir))
                if (n.EndsWith(".m4r", StringComparison.OrdinalIgnoreCase) && !list.Any(t => t.File == n))
                    list.Add(new Ringtone { File = n, Name = Path.GetFileNameWithoutExtension(n) });
            return list;
        });
        if (tones != null) Tones = tones.OrderBy(t => t.Name, Natural.Comparer).ToList();
        Loaded = true; Loading = false; Notify();
    }

    static string Guid16() { var r = new Random(); const string hex = "0123456789ABCDEF"; return new string(Enumerable.Range(0, 16).Select(_ => hex[r.Next(16)]).ToArray()); }

    /// Converts `source` to AAC (start..start+length), uploads it and registers it in Ringtones.plist.
    public async Task Add(string udid, string source, string name, double start, double length)
    {
        Running = true; Phase = $"Converting {Path.GetFileName(source)}"; Notify();
        var guid = Guid16();
        var tmpDir = Path.Combine(Path.GetTempPath(), "Decant", "Ringtones");
        Directory.CreateDirectory(tmpDir);
        var local = Path.Combine(tmpDir, guid + ".m4r");
        try
        {
            var inFile = await StorageFile.GetFileFromPathAsync(source);
            var outFile = await (await StorageFolder.GetFolderFromPathAsync(tmpDir)).CreateFileAsync(guid + ".m4a", CreationCollisionOption.ReplaceExisting);
            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
            var t = new MediaTranscoder { TrimStartTime = TimeSpan.FromSeconds(start), TrimStopTime = TimeSpan.FromSeconds(start + length) };
            var prep = await t.PrepareFileTranscodeAsync(inFile, outFile, profile);
            if (!prep.CanTranscode) throw new Exception(prep.FailureReason == TranscodeFailureReason.InvalidProfile ? "This file has no audio that can be converted" : prep.FailureReason.ToString());
            await prep.TranscodeAsync();
            File.Move(outFile.Path, local, true);
        }
        catch (Exception e)
        {
            Log($"Ringtone conversion failed: {e.Message}"); Phase = "Conversion failed"; Running = false; Notify(); return;
        }
        Phase = $"Uploading {name}"; Notify();
        if (Session.Demo)
        {
            Tones.Add(new Ringtone { File = guid + ".m4r", Name = name, Duration = length, Pid = Tones.Count + 1 });
            Tones = Tones.OrderBy(t => t.Name, Natural.Comparer).ToList();
        }
        else
        {
            var ok = await Task.Run(() =>
            {
                using var afc = Afc.Open(udid, out var err);
                if (afc == null) { Log($"Ringtone upload: {err}"); return false; }
                afc.MakeDirectory(Dir);
                var up = afc.Upload(local, $"{Dir}/{guid}.m4r");
                if (up != null) { Log($"Ringtone upload: {up}"); return false; }
                var p = ReadPlist(afc);
                var list = p.GetValueOrDefault("Ringtones") as Dictionary<string, object?> ?? new();
                var pid = (long)new Random().Next(1_000_000_000, int.MaxValue);
                list[$"{guid}.m4r"] = new Dictionary<string, object?> { ["GUID"] = guid, ["Name"] = name, ["PID"] = pid, ["Protected Content"] = false, ["Total Time"] = (long)(length * 1000) };
                p["Ringtones"] = list;
                return WritePlist(afc, p);
            });
            if (!ok) { Phase = Phase.StartsWith("Uploading") ? "Upload failed" : "Could not update the tone list"; Running = false; Notify(); return; }
        }
        Log($"Ringtone added: {name} ({(int)length} s)");
        Phase = $"Added {name}"; Running = false; Notify();
        if (!Session.Demo) await Load(udid);
    }

    public async Task Remove(string udid, Ringtone t)
    {
        Running = true; Phase = $"Removing {t.Name}"; Notify();
        if (Session.Demo) Tones = Tones.Where(x => x != t).ToList();
        else await Task.Run(() =>
        {
            using var afc = Afc.Open(udid, out var err);
            if (afc == null) { Log($"Remove ringtone: {err}"); return; }
            if (!afc.Remove($"{Dir}/{t.File}")) Log($"Remove ringtone: the phone refused to delete {t.File}");
            var p = ReadPlist(afc);
            if (p.GetValueOrDefault("Ringtones") is Dictionary<string, object?> list) { list.Remove(t.File); p["Ringtones"] = list; WritePlist(afc, p); }
        });
        Log($"Ringtone removed: {t.Name}");
        Phase = ""; Running = false; Notify();
        if (!Session.Demo) await Load(udid);
    }

    public static string Clock(double s)
    {
        var n = (int)Math.Round(s);
        return n >= 3600 ? $"{n / 3600}:{n % 3600 / 60:00}:{n % 60:00}" : $"{n / 60}:{n % 60:00}";
    }
}
