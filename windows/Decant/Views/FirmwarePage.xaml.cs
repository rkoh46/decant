// The Firmware tab: what Apple signs for this model, the SHSH blobs saved for the phone, IPSW downloads and
// restores. Mirrors FirmwarePane in the Mac's BackupFirmware.swift.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Decant.Engine;

namespace Decant.Views;

public sealed partial class FirmwarePage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;
    readonly FirmwareService firmware = new();
    string Root { get => Prefs.Get("firmwareRoot", FirmwareService.DefaultRoot); set => Prefs.Set("firmwareRoot", value); }
    bool AutoSave { get => Prefs.GetBool("autoSaveBlobs", true); set => Prefs.Set("autoSaveBlobs", value); }
    string ExtraGenerator { get => Prefs.Get("extraGenerator", ""); set => Prefs.Set("extraGenerator", value); }
    bool revealEcid;
    string loadedModel = "";
    string basebandSerial = "", basebandCert = "";

    public FirmwarePage() { InitializeComponent(); }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        firmware.Log = line => s.Note(line);
        firmware.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { _ = Refresh(); Render(); });
        _ = Refresh();
        Render();
    }

    public void Shown() { _ = Refresh(); Render(); }

    string Ecid => session.Info?.Ecid ?? "";
    string Board => session.Info?.Hardware ?? "";
    string Model => session.Info?.Model ?? "";
    bool Connected => session.Info != null && Ecid != "";

    async Task Refresh()
    {
        var model = Model;
        if (model == "" || model == loadedModel) return;
        loadedModel = model;
        if (Session.Demo) { basebandSerial = "4f1c0a9b"; basebandCert = "3095460737"; }
        else
        {
            var r = await Tools.Run("ideviceinfo", new[] { "-u", session.Udid, "-x" });
            if (r.Code == 0 && Plist.Parse(r.Output) is Dictionary<string, object?> g)
            {
                basebandSerial = Plist.Str(g.GetValueOrDefault("BasebandSerialNumber"));
                basebandCert = Plist.Long(g.GetValueOrDefault("BasebandGoldCertId"))?.ToString() ?? "";
            }
        }
        await firmware.LoadSigning(model);
        firmware.ScanBlobs(Root, Ecid);
        await firmware.RefreshMode();
        if (AutoSave && Ecid != "" && Board != "" && FirmwareService.HasBlobSaver) await SaveAll();
    }

    async Task SaveAll()
    {
        await firmware.SaveBlobs(Ecid, Model, Board, basebandSerial, basebandCert, Root, FirmwareService.Generator);
        var extra = ExtraGenerator;
        if (FirmwareService.ValidGenerator(extra) && !string.Equals(extra, FirmwareService.Generator, StringComparison.OrdinalIgnoreCase))
            await firmware.SaveBlobs(Ecid, Model, Board, basebandSerial, basebandCert, Root, extra);
    }

    // MARK: Layout

    void Render()
    {
        Page.Children.Clear();
        Page.Children.Add(StatusCard());
        Page.Children.Add(BlobsSection());
        Page.Children.Add(FirmwareSection());
        Page.Children.Add(RecoveryRow());
        Page.Children.Add(RestoreReadiness());
        Page.Children.Add(new TextBlock
        {
            Text = "Signed versions can be restored or updated any time. An unsigned version needs a blob saved for it, and the phone's nonce set to the blob's generator (0x1111111111111111), which on A12 and newer chips only a jailbreak can do. Decant saves blobs with that generator so the restore is possible later.",
            FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap,
        });
    }

    Border Card(UIElement content, double padding = 20) => new() { Style = (Style)Application.Current.Resources["Card"], Padding = new Thickness(padding), Child = content };

    static TextBlock SectionTitle(string text) => new() { Text = text, FontSize = 13, Foreground = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };

    Border StatusCard()
    {
        var p = new StackPanel { Spacing = 12 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        if (Connected)
        {
            title.Children.Add(new TextBlock { Text = $"iOS {session.Info!.Version}", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
            title.Children.Add(new TextBlock { Text = $"{session.Info.MarketingName} · {Model} · {Board}", FontSize = 13, Foreground = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 4) });
        }
        else title.Children.Add(new TextBlock { Text = "No iPhone connected", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        p.Children.Add(title);

        var grid = new Grid { ColumnSpacing = 32 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = new StackPanel(); var right = new StackPanel();
        var ecidValue = Connected ? (revealEcid ? Ecid : new string('•', Math.Max(Ecid.Length, 8))) : "–";
        var eye = new Button { Content = new FontIcon { Glyph = revealEcid ? "" : "", FontSize = 12 }, Padding = new Thickness(4), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Foreground = Rows.Res("TextFillColorSecondaryBrush"), Visibility = Connected ? Visibility.Visible : Visibility.Collapsed };
        eye.Click += (_, _) => { revealEcid = !revealEcid; Render(); };
        left.Children.Add(Rows.Row("ECID", Rows.H(8, Rows.Value(ecidValue, mono: true), eye), 112));
        left.Children.Add(Rows.Row("Signed now", string.Join(", ", firmware.Firmwares.Where(firmware.IsSigned).Select(f => f.Version)), 112, last: true));
        right.Children.Add(Rows.Row("Mode", Connected ? firmware.Mode.Text() : "–", 112));
        right.Children.Add(Rows.Row("Blobs saved", Connected ? firmware.Blobs.Count.ToString() : "–", 112, last: true));
        Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right);
        p.Children.Add(grid);

        var auto = new Grid();
        var check = new CheckBox { Content = "Save blobs automatically when the iPhone connects", IsChecked = AutoSave, FontSize = 13, MinHeight = 0 };
        check.Checked += (_, _) => AutoSave = true; check.Unchecked += (_, _) => AutoSave = false;
        auto.Children.Add(check);
        var files = Rows.H(4, Rows.Secondary($"Files go to {Prefs.ShortPath(Root)}"), Rows.Link("Change…", ChangeRoot));
        files.HorizontalAlignment = HorizontalAlignment.Right;
        auto.Children.Add(files);
        p.Children.Add(auto);

        var gen = new Grid();
        var genLeft = Rows.H(12, Rows.Secondary("Generator"), Rows.Value(FirmwareService.Generator, mono: true), Rows.Secondary("The convention every guide and tool uses"));
        ((FrameworkElement)genLeft.Children[0]).Width = 112;
        gen.Children.Add(genLeft);
        var extra = ExtraGenerator;
        var genRight = extra == ""
            ? Rows.H(4, Rows.Link("Also save for a custom generator…", AddGenerator))
            : Rows.H(8, Rows.Value($"also {extra}", mono: true), Rows.Link("Remove", () => { ExtraGenerator = ""; Render(); }));
        genRight.HorizontalAlignment = HorizontalAlignment.Right;
        gen.Children.Add(genRight);
        p.Children.Add(gen);

        if (firmware.Running)
        {
            var run = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            if (firmware.Progress is double pr) run.Children.Add(new ProgressBar { Width = 360, Minimum = 0, Maximum = 1, Value = pr, VerticalAlignment = VerticalAlignment.Center });
            else run.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            run.Children.Add(Rows.Secondary(firmware.Phase));
            var stop = new Button { Content = "Stop" }; stop.Click += (_, _) => firmware.Cancel(); run.Children.Add(stop);
            p.Children.Add(run);
        }
        return Card(p);
    }

    StackPanel BlobsSection()
    {
        var s = new StackPanel { Spacing = 8 };
        var head = new Grid();
        head.Children.Add(SectionTitle("SHSH blobs"));
        var buttons = Rows.H(8, Rows.Small("Save Blobs Now", () => _ = SaveAll(), Connected && !firmware.Running && FirmwareService.HasBlobSaver),
            Rows.Small("Reveal", () => Rows.Reveal(FirmwareService.BlobDir(Root, Ecid)), Connected));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        head.Children.Add(buttons);
        s.Children.Add(head);
        s.Children.Add(new TextBlock { Text = "Saved blobs are never replaced or deleted by Decant: Save Blobs Now only adds versions that are missing, and each file is locked read-only on disk.", FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
        var list = new StackPanel();
        if (firmware.Blobs.Count == 0)
            list.Children.Add(new TextBlock { Text = Connected ? "No blobs saved for this iPhone yet" : "Connect an iPhone", FontSize = 13, Foreground = Rows.Res("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 48, VerticalAlignment = VerticalAlignment.Center });
        else
            for (int i = 0; i < firmware.Blobs.Count; i++)
            {
                var b = firmware.Blobs[i];
                var g = new Grid { Height = 40, Padding = new Thickness(8, 0, 8, 0) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var icon = new FontIcon { Glyph = "", FontSize = 14, Foreground = Rows.Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
                var t = new TextBlock { Text = $"iOS {b.Version} ({b.Build})", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
                var gtext = new TextBlock { Text = b.Generator != null ? $"generator {b.Generator}" : "no generator", FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
                var d = Rows.Secondary(Prefs.Abbrev(b.Date), 12);
                Grid.SetColumn(t, 1); Grid.SetColumn(gtext, 2); Grid.SetColumn(d, 3);
                g.Children.Add(icon); g.Children.Add(t); g.Children.Add(gtext); g.Children.Add(d);
                var wrap = new Grid(); wrap.Children.Add(g);
                if (i < firmware.Blobs.Count - 1) wrap.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Rows.Res("DividerStrokeColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(44, 0, 0, 0) });
                list.Children.Add(wrap);
            }
        s.Children.Add(Card(list, 12));
        return s;
    }

    StackPanel FirmwareSection()
    {
        var s = new StackPanel { Spacing = 8 };
        s.Children.Add(SectionTitle($"Firmware for {session.Info?.MarketingName ?? "this model"}"));
        var list = new StackPanel();
        if (firmware.Firmwares.Count == 0)
            list.Children.Add(new TextBlock { Text = Connected ? "Loading signing status…" : "Connect an iPhone", FontSize = 13, Foreground = Rows.Res("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 48, VerticalAlignment = VerticalAlignment.Center });
        var shown = firmware.Firmwares.Take(12).ToList();
        for (int i = 0; i < shown.Count; i++)
        {
            var fw = shown[i];
            var signed = firmware.IsSigned(fw);
            var downloaded = File.Exists(FirmwareService.IpswPath(Root, fw));
            var blob = firmware.Blobs.FirstOrDefault(b => b.Build == fw.BuildId);
            var g = new Grid { Height = 56, Padding = new Thickness(8, 0, 8, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var dot = Rows.Dot(signed); dot.HorizontalAlignment = HorizontalAlignment.Left;
            var lines = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            var l1 = Rows.H(6, new TextBlock { Text = $"iOS {fw.Version}", FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
            if (fw.Version == session.Info?.Version) l1.Children.Add(Rows.Secondary("installed", 11));
            lines.Children.Add(l1);
            var rel = fw.ReleaseDate.Length >= 10 ? fw.ReleaseDate[..10] : fw.ReleaseDate;
            lines.Children.Add(Rows.Secondary($"{fw.BuildId} · {Prefs.Gb(fw.FileSize)} · {rel} · {(signed ? "signed" : "unsigned")}{(blob != null ? " · blob saved" : "")}", 12));
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            if (downloaded) buttons.Children.Add(Rows.Secondary("downloaded", 12));
            else buttons.Children.Add(Rows.Small("Download", () => _ = firmware.DownloadIpsw(fw, Root), !firmware.Running));
            if (signed)
            {
                var can = Connected && downloaded && !firmware.Running && Requirements.RestoreBlocker() == null;
                buttons.Children.Add(Rows.Small("Update…", () => ConfirmRestore(fw, false, false), can));
                buttons.Children.Add(Rows.Small("Restore…", () => ConfirmRestore(fw, true, false), can));
            }
            else if (Tools.Has("futurerestore"))   // futurerestore has no current Windows build; the button appears only when one is bundled
            {
                var can = Connected && downloaded && blob != null && !firmware.Running;
                var b = Rows.Small("Future Restore…", () => ConfirmRestore(fw, true, true), can);
                ToolTipService.SetToolTip(b, blob != null ? "Needs the phone's nonce set to the blob's generator" : "No blob saved for this version");
                buttons.Children.Add(b);
            }
            Grid.SetColumn(lines, 1); Grid.SetColumn(buttons, 2);
            g.Children.Add(dot); g.Children.Add(lines); g.Children.Add(buttons);
            var wrap = new Grid(); wrap.Children.Add(g);
            if (i < shown.Count - 1) wrap.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Rows.Res("DividerStrokeColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(44, 0, 0, 0) });
            list.Children.Add(wrap);
        }
        s.Children.Add(Card(list, 12));
        return s;
    }

    Grid RecoveryRow()
    {
        var g = new Grid();
        var left = Rows.H(12, SectionTitle("Recovery"), Rows.Secondary($"Mode: {(Connected || firmware.Mode != RecoveryMode.None ? firmware.Mode.Text() : "–")}"),
            Rows.Small("Enter Recovery…", () => _ = firmware.EnterRecovery(session.Udid), Connected && !firmware.Running && Tools.Has("ideviceenterrecovery")),
            Rows.Small("Exit Recovery", () => _ = firmware.ExitRecovery(), !firmware.Running && Tools.Has("irecovery")),
            Rows.Small("Check", () => _ = firmware.RefreshMode(), !firmware.Running));
        ((FrameworkElement)left.Children[0]).Width = 112;
        g.Children.Add(left);
        var log = Rows.Small("Show Log", () => window.ShowTab("tools"));
        log.HorizontalAlignment = HorizontalAlignment.Right;
        g.Children.Add(log);
        return g;
    }

    /// One quiet line under Recovery: whether Update and Restore can run on this PC, and what to install if not.
    TextBlock RestoreReadiness()
    {
        var blocker = Requirements.RestoreBlocker();
        return new TextBlock
        {
            Text = blocker == null ? "Restores ready: idevicerestore, irecovery and Apple's USB driver are on this PC" : "Restores unavailable: " + blocker,
            FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap,
        };
    }

    // MARK: Actions

    async void ChangeRoot()
    {
        var p = await Rows.PickFolder(window.Hwnd, Root);
        if (p == null) return;
        Root = p; firmware.ScanBlobs(Root, Ecid); Render();
    }

    async void AddGenerator()
    {
        var box = new TextBox { PlaceholderText = "0x…", Width = 260 };
        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(box);
        body.Children.Add(new TextBlock { Text = "Only for a jailbroken phone that already boots with a fixed custom generator. Blobs for the default generator are still saved; a blob for a generator the phone cannot be set to is useless.", FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
        var d = new ContentDialog { XamlRoot = XamlRoot, Title = "Save blobs for a second generator", Content = body, PrimaryButtonText = "Add", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false, DefaultButton = ContentDialogButton.Primary };
        box.TextChanged += (_, _) => d.IsPrimaryButtonEnabled = FirmwareService.ValidGenerator(box.Text.Trim());
        if (await d.ShowAsync() == ContentDialogResult.Primary) { ExtraGenerator = box.Text.Trim(); Render(); }
    }

    async void ConfirmRestore(Firmware fw, bool erase, bool future)
    {
        var title = future ? $"Restore to unsigned iOS {fw.Version}?" : erase ? $"Erase and restore to iOS {fw.Version}?" : $"Update to iOS {fw.Version}?";
        var message = future ? "futurerestore will use your saved blob with the latest signed SEP and baseband. The phone's nonce must already match the blob's generator or it will fail with APNonce mismatch. All data is erased."
            : erase ? "All data on the iPhone is erased. Make a backup first if you have not." : $"Your data stays; the system is replaced with iOS {fw.Version}.";
        if (!await Rows.Confirm(XamlRoot, title, message, "Continue")) return;
        if (!await Rows.Confirm(XamlRoot, "Last check", "Keep the cable connected until the iPhone finishes and shows the Hello screen or your lock screen.", erase ? "Erase and Restore" : "Update")) return;
        var ipsw = FirmwareService.IpswPath(Root, fw);
        if (!File.Exists(ipsw)) return;
        var blob = firmware.Blobs.FirstOrDefault(b => b.Build == fw.BuildId);
        if (future && blob != null) await firmware.FutureRestore(blob.Path, ipsw, true);
        else await firmware.Restore(ipsw, erase);
    }
}
