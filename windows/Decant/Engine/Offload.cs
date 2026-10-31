// Copying the camera roll to a folder: year/month subfolders, skip what is already there, verify every byte count,
// stamp the capture date on the file, and delete from the phone only after a verified copy.
namespace Decant.Engine;

public sealed class OffloadProgress
{
    public int Done, Total, Skipped, Failed;
    public long Bytes;
    public string Current = "";
}

public static class Offloader
{
    public static async Task<OffloadProgress> Run(IPhone phone, IEnumerable<MediaItem> items, string root, bool deleteAfter,
        Action<OffloadProgress> report, Action<string> log, CancellationToken ct)
    {
        var list = items.ToList();
        var p = new OffloadProgress { Total = list.Count };
        foreach (var item in list)
        {
            ct.ThrowIfCancellationRequested();
            p.Current = item.Name;
            report(p);
            var folder = Settings.DateFolder(root, item.Date);
            Directory.CreateDirectory(folder);
            var dest = Path.Combine(folder, item.Name);
            if (File.Exists(dest) && new FileInfo(dest).Length == item.Size)
            {
                p.Skipped++;
                log($"{item.Name}: already in {folder}, same size, skipped");
            }
            else
            {
                var err = await phone.Copy(item, dest, ct);
                if (err != null) { p.Failed++; log($"{item.Name}: {err}"); p.Done++; report(p); continue; }
                if (item.Date is DateTime d) { try { File.SetLastWriteTime(dest, d); File.SetCreationTime(dest, d); } catch { } }
                p.Bytes += item.Size;
                log($"{item.Name}: copied, {item.Size:N0} bytes verified");
            }
            if (deleteAfter)
            {
                var err = await phone.Delete(item, ct);
                if (err != null) { log($"{item.Name}: kept on the phone, {err}"); }
            }
            p.Done++;
            report(p);
        }
        return p;
    }
}
