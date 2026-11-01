// The Backup tab: the phone's backup settings and actions on the left-hand "Device" row, and each backup's details
// and content exports when one is selected. Mirrors BackupPane in the Mac's BackupFirmware.swift.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Decant.Engine;

namespace Decant.Views;

public sealed class SidebarRow
{
    public string Glyph = "", Title = "", Subtitle = "", Detail = "";
    public object? Tag;
    public bool IsHeader;
    public Visibility RowVisible => IsHeader ? Visibility.Collapsed : Visibility.Visible;
    public Visibility HeaderVisible => IsHeader ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SubVisible => Subtitle == "" ? Visibility.Collapsed : Visibility.Visible;
}

public sealed partial class BackupPage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;
    readonly BackupService backups = new();
    string Root { get => Prefs.Get("backupRoot", BackupService.DefaultRoot); set => Prefs.Set("backupRoot", value); }
    string LastUdid { get => Prefs.Get("lastUDID", ""); set => Prefs.Set("lastUDID", value); }
    object selection = "phone";
    List<string> networkUdids = new();
    DateTime lastNetworkPoll = DateTime.MinValue;
    bool rendering;

    // The open backup (BackupBrowserModel on the Mac)
    BackupInfo? openBackup;
    BackupReader? reader;
    BackupSummary? summary;
    bool needsPassword, busy;
    string phase = "", error = "";
    (string dir, int count)? lastExport;

    public BackupPage() { InitializeComponent(); }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        backups.Log = line => s.Note(line);
        backups.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { RememberPhone(); Render(); });
        backups.Scan(Root);
        RememberPhone();
        var sel = Environment.GetEnvironmentVariable("DECANT_SELECT");
        if (sel != null && sel.StartsWith("backup:") && int.TryParse(sel[7..], out var n) && n < backups.Backups.Count) Select(backups.Backups[n]);
        Render();
    }

    public void Shown() { RememberPhone(); Render(); }

    // MARK: Which phone

    string UsbUdid => session.Info != null ? session.Udid : "";
    string? WifiUdid
    {
        get
        {
            if (UsbUdid != "") return null;
            var last = LastUdid;
            if (last == "") return networkUdids.FirstOrDefault();
            return networkUdids.Contains(last) ? last : null;
        }
    }
    string Udid => UsbUdid != "" ? UsbUdid : WifiUdid ?? "";
    bool OverWifi => UsbUdid == "" && WifiUdid != null;
    bool Ready => Udid != "" && (Session.Demo || Tools.Has("ideviceinfo")) && !backups.Running;
    BackupInfo? SelectedBackup => selection as BackupInfo;
    BackupInfo? Latest => backups.Backups.Concat(backups.ItunesBackups).OrderByDescending(b => b.Date).FirstOrDefault();

    void RememberPhone()
    {
        if (UsbUdid != "") LastUdid = UsbUdid;
        if (Session.Demo) networkUdids = new List<string> { session.Udid };
        else if ((DateTime.Now - lastNetworkPoll).TotalSeconds > 3 && Tools.Has("idevice_id"))
        {
            lastNetworkPoll = DateTime.Now;
            _ = Task.Run(async () =>
            {
                var r = await Tools.Run("idevice_id", new[] { "-n" });
                var list = r.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x != "").ToList();
                DispatcherQueue.TryEnqueue(() => { if (!list.SequenceEqual(networkUdids)) { networkUdids = list; Render(); } });
            });
        }
        var u = Udid;
        if (u != "" && backups.SettingsFor != u) _ = backups.ReadSettings(u);
    }

    string StatusText => session.Info == null ? (session.Status == "Locked" ? "Locked: unlock and tap Trust" : session.Phone != null ? "Connecting…" : "No iPhone connected")
        : session.Loading ? $"Reading library… {session.Items.Count:N0} items" : "Ready";

    // MARK: Sidebar

    void Render()
    {
        if (rendering) return;
        rendering = true;
        try
        {
            var rows = new List<SidebarRow>();
            rows.Add(new SidebarRow { Title = "Device", IsHeader = true });
            rows.Add(new SidebarRow { Glyph = OverWifi ? "\uE701" : "\uE8EA", Title = session.Info?.Name ?? (OverWifi ? "iPhone over Wi-Fi" : "This iPhone"), Tag = "phone" });
            rows.Add(new SidebarRow { Title = "Decant backups", IsHeader = true });
            if (backups.Backups.Count == 0) rows.Add(new SidebarRow { Title = "None yet", Tag = "none" });
            foreach (var b in backups.Backups) rows.Add(RowFor(b));
            rows.Add(new SidebarRow { Title = "iTunes backups", IsHeader = true });
            if (!backups.ItunesReadable) rows.Add(new SidebarRow { Title = "Folder not readable", Tag = "none" });
            else if (backups.ItunesBackups.Count == 0) rows.Add(new SidebarRow { Title = "None on this PC", Tag = "none" });
            foreach (var b in backups.ItunesBackups) rows.Add(RowFor(b));
            Sidebar.Items.Clear();
            foreach (var r in rows) Sidebar.Items.Add(SidebarItem(r));
            Sidebar.SelectedItem = Sidebar.Items.Cast<FrameworkElement>().FirstOrDefault(e => e.Tag is SidebarRow r && (selection is BackupInfo b ? r.Tag is BackupInfo rb && rb.Id == b.Id : r.Tag is "phone"));
        }
        finally { rendering = false; }
        RenderDetail();
    }

    /// One sidebar line, built in code: a section header, or an icon, title, date and size.
    static FrameworkElement SidebarItem(SidebarRow r)
    {
        if (r.IsHeader)
            return new TextBlock { Text = r.Title, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = Rows.Res("TextFillColorSecondaryBrush"),
                Margin = new Thickness(-4, 8, 0, 0), VerticalAlignment = VerticalAlignment.Bottom, Tag = r, IsHitTestVisible = false };
        var g = new Grid { Tag = r };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (r.Glyph != "") g.Children.Add(new FontIcon { Glyph = r.Glyph, FontSize = 14, Foreground = Rows.Res("TextFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Width = 16 });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 4, 0, 4) };
        text.Children.Add(new TextBlock { Text = r.Title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = r.Tag is "none" ? Rows.Res("TextFillColorSecondaryBrush") : Rows.Res("TextFillColorPrimaryBrush") });
        if (r.Subtitle != "") text.Children.Add(new TextBlock { Text = r.Subtitle, FontSize = 11, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(text, 1); g.Children.Add(text);
        if (r.Detail != "")
        {
            var d = new TextBlock { Text = r.Detail, FontSize = 11, Foreground = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
            Grid.SetColumn(d, 2); g.Children.Add(d);
        }
        return g;
    }

    static SidebarRow RowFor(BackupInfo b) => new()
    {
        Glyph = b.Encrypted ? "" : "", Title = b.DeviceName, Subtitle = Prefs.Abbrev(b.Date), Detail = Prefs.Gb(b.Size), Tag = b,
    };

    void Sidebar_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (rendering) return;
        if (Sidebar.SelectedItem is not FrameworkElement el || el.Tag is not SidebarRow row || row.IsHeader || row.Tag is "none") { Render(); return; }
        if (row.Tag is BackupInfo b) Select(b); else { selection = "phone"; RenderDetail(); }
    }

    void Select(BackupInfo b)
    {
        selection = b;
        Open(b);
        RenderDetail();
    }

    // MARK: Opening a backup

    void CloseReader()
    {
        reader?.Dispose(); reader = null;
        openBackup = null; summary = null; needsPassword = false; busy = false; phase = ""; error = ""; lastExport = null;
    }

    void Open(BackupInfo b)
    {
        if (openBackup?.Id == b.Id) return;
        CloseReader();
        openBackup = b;
        if (Session.Demo) { summary = DemoBackups.Summary(); return; }
        busy = true; phase = "Reading the backup";
        _ = Task.Run(() =>
        {
            BackupReader? r = null; BackupSummary? s = null; string err = "";
            try { r = new BackupReader(b.Path); if (r.IsUnlocked) s = r.Summary(); }
            catch (Exception e) { err = e.Message; }
            DispatcherQueue.TryEnqueue(() =>
            {
                if (openBackup?.Id != b.Id) { r?.Dispose(); return; }
                reader = r; summary = s; needsPassword = r != null && !r.IsUnlocked; error = err; busy = false; phase = "";
                RenderDetail();
            });
        });
    }

    void Unlock(string password)
    {
        if (reader == null || password == "") return;
        busy = true; phase = "Unlocking"; error = ""; RenderDetail();
        var r = reader;
        _ = Task.Run(() =>
        {
            BackupSummary? s = null; string err = "";
            try { r.Unlock(password); s = r.Summary(); } catch (Exception e) { err = e.Message; }
            DispatcherQueue.TryEnqueue(() => { if (reader != r) return; busy = false; phase = ""; error = err; if (s != null) { summary = s; needsPassword = false; } RenderDetail(); });
        });
    }

    async void Export(BackupExport[] kinds)
    {
        var b = openBackup;
        if (b == null || busy) return;
        var picker = new Windows.Storage.Pickers.FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        picker.FileTypeFilter.Add("*");
        picker.CommitButtonText = "Export here";
        var chosen = await picker.PickSingleFolderAsync();
        if (chosen == null) return;
        var folder = Path.Combine(chosen.Path, $"{b.DeviceName} {b.Date:yyyy-MM-dd}");
        busy = true; phase = "Exporting"; error = ""; RenderDetail();
        if (Session.Demo)
        {
            await Task.Delay(1200);
            lastExport = (folder, kinds.Length * 120); busy = false; phase = ""; RenderDetail();
            return;
        }
        var r = reader;
        if (r == null) { busy = false; RenderDetail(); return; }
        await Task.Run(() =>
        {
            try
            {
                var counts = r.Export(kinds, folder, p => DispatcherQueue.TryEnqueue(() => { phase = p; RenderDetail(); }));
                var total = counts.Values.Sum();
                var line = $"Exported {string.Join(", ", counts.OrderBy(kv => kv.Key.Title()).Select(kv => $"{kv.Key.Title()} {kv.Value:N0}"))} to {folder}";
                DispatcherQueue.TryEnqueue(() => { lastExport = (folder, total); session.Note(line); });
            }
            catch (Exception e) { DispatcherQueue.TryEnqueue(() => error = e.Message); }
        });
        busy = false; phase = ""; RenderDetail();
    }

    // MARK: Detail

    void RenderDetail()
    {
        Detail.Children.Clear();
        if (SelectedBackup is BackupInfo b) BackupDetail(b); else PhoneDetail();
    }

    StackPanel Header(string title, string subtitle)
    {
        var p = new StackPanel { Spacing = 4 };
        p.Children.Add(new TextBlock { Text = title, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        p.Children.Add(Rows.Secondary(subtitle));
        return p;
    }

    void PhoneDetail()
    {
        var udid = Udid;
        var title = session.Info?.Name ?? (OverWifi ? "iPhone over Wi-Fi" : "No iPhone");
        var subtitle = Latest is BackupInfo l ? $"Last backed up {Prefs.Relative(l.Date)} · {Prefs.Gb(l.Size)}" : udid == "" ? StatusText : "Never backed up with this PC";
        Detail.Children.Add(Header(title, subtitle));

        var grid = new StackPanel();
        var free = Settings.FreeSpace(Root);
        grid.Children.Add(Rows.Row("Backups go to", Rows.H(8, Rows.Value(Prefs.ShortPath(Root)), Rows.Link("Change…", ChangeRoot), Rows.Link("Show in Explorer", () => Rows.Reveal(Root)),
            Rows.Secondary(free is long f ? $"{Prefs.Gb(f)} free" : ""))));
        grid.Children.Add(Rows.Row("Size on iPhone", session.Storage is DeviceStorage st ? $"{Prefs.Gb(st.Used)} used" : "–"));
        var connection = UsbUdid != "" ? (networkUdids.Contains(UsbUdid) ? "USB · also reachable over Wi-Fi" : "USB") : OverWifi ? "Wi-Fi, no cable" : "–";
        grid.Children.Add(Rows.Row("Connection", connection));
        var encButtons = new List<UIElement>();
        if (backups.WillEncrypt == true)
        {
            encButtons.Add(Rows.Small("Change Password…", () => Password(PasswordMode.Change), udid != ""));
            encButtons.Add(Rows.Small("Turn Off…", () => Password(PasswordMode.TurnOff), udid != ""));
        }
        else if (backups.WillEncrypt == false) encButtons.Add(Rows.Small("Turn On…", () => Password(PasswordMode.TurnOn), udid != ""));
        grid.Children.Add(Rows.Row("Encryption", SettingRow(backups.WillEncrypt, "On · Health, passwords and Wi-Fi included", "Off · Health, passwords and Wi-Fi left out", encButtons)));
        var wifiButtons = new List<UIElement>();
        if (backups.WifiSync is bool ws)
        {
            var btn = Rows.Small(ws ? "Turn Off" : "Turn On", () => _ = backups.SetWifiSync(!ws, udid), UsbUdid != "");
            if (UsbUdid == "") ToolTipService.SetToolTip(btn, "Connect the cable to change this");
            wifiButtons.Add(btn);
        }
        var wifiOn = networkUdids.Contains(udid) ? "On · reachable on this network now" : "On · backs up without the cable on this network";
        grid.Children.Add(Rows.Row("Wi-Fi backups", SettingRow(backups.WifiSync, wifiOn, "Off · a cable is needed to back up", wifiButtons), last: true));
        grid.IsHitTestVisible = !backups.Running;
        Detail.Children.Add(grid);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        if (backups.Running)
        {
            if (backups.Progress is double p) actions.Children.Add(new ProgressBar { Width = 360, Minimum = 0, Maximum = 1, Value = p, VerticalAlignment = VerticalAlignment.Center });
            else actions.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            actions.Children.Add(Rows.Secondary(backups.Phase + (backups.Progress is double pp ? $" {(int)(pp * 100)}%" : "")));
            var stop = new Button { Content = "Stop" }; stop.Click += (_, _) => backups.Cancel(); actions.Children.Add(stop);
        }
        else
        {
            var back = new Button { Content = OverWifi ? "Back Up Now over Wi-Fi" : "Back Up Now", Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = Ready };
            back.Click += (_, _) => _ = backups.Backup(udid, Root, OverWifi);
            actions.Children.Add(back);
            var restore = new Button { Content = "Restore from Folder…", IsEnabled = Ready && !OverWifi && !Session.Demo };
            restore.Click += (_, _) => RestoreFromFolder();
            actions.Children.Add(restore);
            if (backups.Phase != "") actions.Children.Add(Rows.Secondary(backups.Phase));
        }
        Detail.Children.Add(actions);

        Detail.Children.Add(Rows.Divider());
        var what = new StackPanel { Spacing = 8 };
        what.Children.Add(new TextBlock { Text = "What a backup holds", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        var bullets = new Grid { ColumnSpacing = 24, RowSpacing = 6 };
        bullets.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bullets.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var items = new[]
        {
            ("Messages, call history, notes, voice memos", "App data and documents"),
            ("Home screen layout and settings", "Photos and videos, unless iCloud Photos keeps them"),
            ("Health, passwords, Wi-Fi: encrypted backups only", "Not included: apps themselves, Face ID, Apple Pay cards"),
        };
        for (int i = 0; i < items.Length; i++)
        {
            bullets.RowDefinitions.Add(new RowDefinition());
            foreach (var (text, col) in new[] { (items[i].Item1, 0), (items[i].Item2, 1) })
            {
                var row = Rows.H(8, new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 4, Height = 4, Fill = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center }, Rows.Secondary(text, 12));
                Grid.SetRow(row, i); Grid.SetColumn(row, col); bullets.Children.Add(row);
            }
        }
        what.Children.Add(bullets);
        what.Children.Add(new TextBlock
        {
            Text = "Select a backup on the left to read its messages, contacts, call history, notes, voice memos, Safari history and WhatsApp chats, or to export them as files. A restore replaces everything on the iPhone with the backup and reboots it; Decant asks twice and never restores on its own.",
            FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });
        Detail.Children.Add(what);
    }

    UIElement SettingRow(bool? state, string on, string off, List<UIElement> buttons)
    {
        var text = state == null ? (Udid == "" ? "–" : "Reading…") : state == true ? on : off;
        var p = Rows.H(8, Rows.Dot(state == true), Rows.Value(text));
        if (state != null) foreach (var b in buttons) p.Children.Add(b);
        return p;
    }

    void BackupDetail(BackupInfo b)
    {
        var isDecant = backups.Backups.Any(x => x.Id == b.Id);
        Detail.Children.Add(Header(b.DeviceName, Prefs.Complete(b.Date)));
        var grid = new StackPanel();
        grid.Children.Add(Rows.Row("iOS version", b.Version));
        grid.Children.Add(Rows.Row("Size", Prefs.Gb(b.Size)));
        grid.Children.Add(Rows.Row("Encrypted", b.Encrypted ? "Yes" : "No"));
        grid.Children.Add(Rows.Row("Made with", isDecant ? "Decant" : "iTunes or Apple Devices"));
        grid.Children.Add(Rows.Row("Location", Rows.H(8, Rows.Value(Prefs.ShortPath(b.Path)), Rows.Link("Show in Explorer", () => Rows.Reveal(b.Path))), last: true));
        Detail.Children.Add(grid);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var restore = new Button { Content = "Restore to iPhone…", IsEnabled = Ready && !OverWifi && !Session.Demo };
        restore.Click += (_, _) => RestoreBackup(b);
        buttons.Children.Add(restore);
        if (isDecant)
        {
            var del = new Button { Content = "Delete…", IsEnabled = !backups.Running && !Session.Demo };
            del.Click += async (_, _) =>
            {
                if (await Rows.Confirm(XamlRoot, "Move this backup to the Recycle Bin?", $"{b.DeviceName}, {Prefs.Abbrev(b.Date)}, {Prefs.Gb(b.Size)}", "Move to Recycle Bin"))
                { CloseReader(); backups.Delete(b, Root); selection = "phone"; Render(); }
            };
            buttons.Children.Add(del);
        }
        Detail.Children.Add(buttons);
        Detail.Children.Add(Rows.Secondary(Ready && !OverWifi ? $"Restoring puts this backup on {session.Info?.Name ?? "the connected iPhone"} and reboots it." : "Connect and unlock an iPhone over USB to restore this backup.", 12));

        Detail.Children.Add(Rows.Divider());
        var contents = new StackPanel { Spacing = 8 };
        var head = new Grid();
        head.Children.Add(new TextBlock { Text = "Contents", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center });
        if (summary != null)
        {
            var all = Rows.Small("Export All…", () => Export(BackupExportInfo.All), !busy);
            all.HorizontalAlignment = HorizontalAlignment.Right;
            head.Children.Add(all);
        }
        contents.Children.Add(head);
        if (needsPassword)
        {
            var pw = new PasswordBox { PlaceholderText = "Backup password", Width = 240 };
            var unlock = new Button { Content = "Unlock", IsEnabled = false };
            pw.PasswordChanged += (_, _) => unlock.IsEnabled = pw.Password != "" && !busy;
            pw.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter && pw.Password != "") Unlock(pw.Password); };
            unlock.Click += (_, _) => Unlock(pw.Password);
            var row = Rows.H(8, new FontIcon { Glyph = "", FontSize = 14, Foreground = Rows.Res("TextFillColorSecondaryBrush") }, pw, unlock);
            if (busy) row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            contents.Children.Add(row);
            contents.Children.Add(new TextBlock { Text = "This backup is encrypted. The password stays on this PC for as long as the backup is open and is not stored.", FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
        }
        else if (summary is BackupSummary s)
        {
            var kinds = new (BackupExport kind, string glyph, int count, string detail)[]
            {
                (BackupExport.Messages, "", s.Messages, $"{N(s.Messages, "message", "messages")} in {N(s.Conversations, "conversation", "conversations")}"),
                (BackupExport.Contacts, "", s.Contacts, N(s.Contacts, "contact", "contacts")),
                (BackupExport.Calls, "", s.Calls, N(s.Calls, "call", "calls")),
                (BackupExport.Notes, "", s.Notes, N(s.Notes, "note", "notes")),
                (BackupExport.VoiceMemos, "", s.VoiceMemos, N(s.VoiceMemos, "recording", "recordings")),
                (BackupExport.Safari, "", s.SafariHistory, N(s.SafariHistory, "page visit", "page visits")),
                (BackupExport.Whatsapp, "", s.WhatsappMessages, s.WhatsappChats == 0 ? "" : $"{N(s.WhatsappMessages, "message", "messages")} in {N(s.WhatsappChats, "chat", "chats")}"),
            };
            foreach (var (kind, glyph, count, detail) in kinds)
            {
                var g = new Grid { Height = 36, ColumnSpacing = 0 };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(128) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var icon = new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
                var t = new TextBlock { Text = kind.Title(), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
                var d = count == 0 ? Rows.Tertiary("None") : Rows.Secondary(detail);
                var ex = Rows.Small("Export…", () => Export(new[] { kind }), count > 0 && !busy);
                Grid.SetColumn(t, 1); Grid.SetColumn(d, 2); Grid.SetColumn(ex, 3);
                g.Children.Add(icon); g.Children.Add(t); g.Children.Add(d); g.Children.Add(ex);
                var wrap = new Grid();
                wrap.Children.Add(g);
                var line = new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Rows.Res("DividerStrokeColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(36, 0, 0, 0) };
                wrap.Children.Add(line);
                contents.Children.Add(wrap);
            }
            contents.Children.Add(new TextBlock
            {
                Text = "Exports are plain files: HTML and text for conversations, vCard for contacts, CSV for calls and history, the original audio for voice memos. Nothing is sent anywhere.",
                FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
            });
            if (busy) contents.Children.Add(Rows.H(8, new ProgressRing { IsActive = true, Width = 16, Height = 16 }, Rows.Secondary(phase)));
        }
        else if (busy) contents.Children.Add(Rows.H(8, new ProgressRing { IsActive = true, Width = 16, Height = 16 }, Rows.Secondary(phase)));
        if (lastExport is (string dir, int n)) contents.Children.Add(Rows.H(8, Rows.Secondary($"{n:N0} items exported to {Prefs.ShortPath(dir)}", 12), Rows.Link("Show in Explorer", () => Rows.Reveal(dir), 12)));
        if (error != "") contents.Children.Add(new TextBlock { Text = error, FontSize = 12, Foreground = new SolidColorBrush(Tone.Warning), TextWrapping = TextWrapping.Wrap });
        Detail.Children.Add(contents);
    }

    static string N(int v, string one, string many) => $"{v:N0} {(v == 1 ? one : many)}";

    // MARK: Actions

    async void ChangeRoot()
    {
        var p = await Rows.PickFolder(window.Hwnd, Root);
        if (p == null) return;
        Root = p; backups.Scan(Root); Render();
    }

    async void Password(PasswordMode mode)
    {
        var r = await PasswordSheet.Show(XamlRoot, mode);
        if (r == null) return;
        var udid = Udid;
        switch (mode)
        {
            case PasswordMode.TurnOn: await backups.SetEncryption(true, r.New, udid); break;
            case PasswordMode.TurnOff: await backups.SetEncryption(false, r.Current, udid); break;
            default: await backups.ChangePassword(r.Current, r.New, udid); break;
        }
    }

    async void RestoreFromFolder()
    {
        var p = await Rows.PickFolder(window.Hwnd);
        if (p == null) return;
        var info = BackupService.Info(p);
        if (info == null) { await Rows.Info(XamlRoot, "That folder is not an iPhone backup", "Pick the backup folder itself (it contains Info.plist and Manifest.plist) or the folder that holds it."); return; }
        RestoreBackup(info);
    }

    async void RestoreBackup(BackupInfo b)
    {
        if (!await Rows.Confirm(XamlRoot, "Restore this backup?", $"{b.DeviceName}, iOS {b.Version}, {Prefs.Abbrev(b.Date)}. Everything currently on the iPhone will be replaced.", "Continue")) return;
        PasswordBox? pw = b.Encrypted ? new PasswordBox { PlaceholderText = "Backup password", Width = 260 } : null;
        var message = b.Encrypted ? "This backup is encrypted. Enter its password to continue." : "The iPhone will restart when the restore finishes.";
        if (!await Rows.Confirm(XamlRoot, "Last check", message, "Restore and Reboot", pw)) return;
        if (b.Encrypted && (pw?.Password ?? "") == "") return;
        await backups.Restore(b, Udid, b.Encrypted ? pw!.Password : null);
    }
}
