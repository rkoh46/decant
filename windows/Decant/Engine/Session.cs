// Everything the window shows, in one place: the phone, what it reported, the camera roll, the log, and the copy in progress.
namespace Decant.Engine;

public sealed class Session
{
    public Settings Settings = Settings.Load();
    public IPhone? Phone;
    public DeviceInfo? Info;
    public DeviceStorage? Storage;
    public BatteryInfo? Battery;
    public List<LargeApp> Apps = new();
    public List<MediaItem> Items = new();
    public List<string> Log = new();
    public string Status = "Looking for an iPhone";
    public bool Loading;
    public OffloadProgress? Progress;
    public CancellationTokenSource? OffloadCts;

    public event Action? Changed;
    public event Action<string>? Logged;

    public bool Ready => Phone != null && Info != null;
    public string Udid => Phone?.Udid ?? "";
    public static bool Demo => PhoneFinder.Demo;
    public int PhotoCount => Items.Count(i => !i.IsVideo);
    public int VideoCount => Items.Count(i => i.IsVideo);
    public int LiveCount => Items.Count(i => i.IsLivePhoto);
    public long TotalBytes => Items.Sum(i => i.Size);

    public void Note(string line)
    {
        var s = $"{DateTime.Now:HH:mm:ss}  {line}";
        Log.Add(s);
        App.Trace(line);
        if (Log.Count > 2000) Log.RemoveAt(0);
        Logged?.Invoke(s);
    }

    CancellationTokenSource? refreshCts;

    /// Finds the phone and reads everything it shows. Safe to call again at any time; a running refresh is cancelled.
    public async Task Refresh(bool full = true)
    {
        refreshCts?.Cancel();
        var cts = refreshCts = new CancellationTokenSource();
        var ct = cts.Token;
        Loading = true; Changed?.Invoke();
        try
        {
            if (!PhoneFinder.Demo && !Tools.Available)
            {
                Phone = null; Info = null; Status = "Device tools not found";
                return;
            }
            var phone = await PhoneFinder.Find(ct);
            if (phone == null)
            {
                if (Phone != null) Note("The iPhone was disconnected");
                Phone = null; Info = null; Storage = null; Battery = null; Items.Clear(); Apps.Clear();
                Status = "No iPhone connected";
                return;
            }
            var isNew = Phone?.Udid != phone.Udid;
            Phone = phone;
            Status = "Reading";
            Changed?.Invoke();
            var info = await phone.Info(ct);
            if (info == null) { Status = "Locked"; Note("The iPhone did not answer: unlock it and tap Trust"); return; }
            Info = info;
            if (isNew) Note($"Connected to {info.Name} ({info.MarketingName}, iOS {info.Version})");
            Battery = await phone.Battery(ct);
            Storage = await phone.Storage(ct);
            Changed?.Invoke();
            if (full || isNew)
            {
                Apps = await phone.LargestApps(ct);
                Items = await phone.CameraRoll(ct);
                Note($"Camera roll: {PhotoCount:N0} photos, {VideoCount:N0} videos, {Format.Gb(TotalBytes)}");
            }
            Status = "Ready";
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Status = "Error"; Note(e.Message); }
        finally
        {
            if (!ct.IsCancellationRequested) { Loading = false; Changed?.Invoke(); }
        }
    }

    public bool Busy => OffloadCts != null;

    public async Task<OffloadProgress?> Offload(IEnumerable<MediaItem> items, bool move)
    {
        if (Phone == null || Busy) return null;
        var cts = OffloadCts = new CancellationTokenSource();
        var root = Settings.PhotosFolder;
        Note($"{(move ? "Moving" : "Copying")} {items.Count():N0} items to {root}");
        try
        {
            var p = await Offloader.Run(Phone, items, root, move, pr => { Progress = pr; Changed?.Invoke(); }, Note, cts.Token);
            Note($"Done: {p.Done - p.Failed - p.Skipped:N0} copied ({Format.Gb(p.Bytes)}), {p.Skipped:N0} already there, {p.Failed:N0} failed");
            if (move) await Refresh(true);
            return p;
        }
        catch (OperationCanceledException) { Note("Stopped"); return Progress; }
        finally { OffloadCts = null; Progress = null; Changed?.Invoke(); }
    }

    public void CancelOffload() => OffloadCts?.Cancel();
}
