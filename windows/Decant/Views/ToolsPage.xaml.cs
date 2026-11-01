// The Tools tab: a sidebar of tools in four sections and, on the right, the selected tool's title, blurb and controls.
// Mirrors Sources/Tools.swift on the Mac (ToolsPane, ToolDetail, SyslogView, BatteryHistoryView, DiagnosticsView).
using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using Decant.Engine;

namespace Decant.Views;

public sealed partial class ToolsPage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;
    DeviceTools tools = null!;

    sealed record Tool(string Key, string Section, string Title, string Glyph, string Blurb);

    static readonly Tool[] All =
    {
        new("restart", "Power", "Restart", "", "Reboots the iPhone. It reconnects by itself about a minute later."),
        new("shutDown", "Power", "Shut Down", "", "Turns the iPhone off. It stays off until its side button is held."),
        new("enterRecovery", "Power", "Enter Recovery", "", "Puts the iPhone in recovery mode, the state a firmware restore starts from. Nothing is changed by entering it."),
        new("exitRecovery", "Power", "Exit Recovery", "", "Boots an iPhone that is sitting in recovery mode back into iOS."),
        new("rename", "Device", "Rename", "", "The name the phone shows in Explorer, AirDrop, Bluetooth and at the top of Settings."),
        new("identifiers", "Device", "Identifiers", "#", "The numbers that identify this exact phone. Masked until you reveal them; each one can be copied."),
        new("report", "Device", "Device Report", "", "Every value the phone reports about itself, saved as a property list you can open or send."),
        new("unpair", "Device", "Unpair This PC", "", "Removes this PC from the phone's trusted computers. The phone asks to trust it again on the next connection."),
        new("battery", "Diagnostics", "Battery", "", "What the phone's battery reports about itself, and how its health and cycle count have moved since Decant first saw it."),
        new("diagnostics", "Diagnostics", "Diagnostics", "", "The phone's own self-tests (battery gauge, storage, Wi-Fi) and what it is drawing from the charger right now."),
        new("crashReports", "Diagnostics", "Crash Reports", "", "Copies the phone's crash logs to a folder on the PC, for reading or for sending to a developer."),
        new("systemLog", "Diagnostics", "System Log", "", "The phone's live system log, the same stream Event Viewer would show, with a filter."),
        new("screenshot", "Diagnostics", "Screenshot", "", "Captures the phone's screen into your Pictures folder. iOS 17 and later require Developer Mode (Settings → Privacy & Security)."),
        new("appLog", "Decant", "Decant Log", "", "Everything Decant did in this session, with times."),
        new("reread", "Decant", "Re-read Library", "", "Reads the camera roll again from the open connection, without reconnecting."),
    };

    readonly Dictionary<string, Button> rows = new();
    string selected = "battery";
    bool shown;

    public ToolsPage() { InitializeComponent(); }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        tools = new DeviceTools(s);
        var start = Environment.GetEnvironmentVariable("DECANT_TOOL");
        if (start != null && All.Any(t => t.Key == start)) selected = start;
        BuildSidebar();
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { if (!shown) return; Render(); if (session.Ready) _ = tools.RunDiagnostics(force: false); });
        s.Logged += _ => DispatcherQueue.TryEnqueue(() => { if (shown && selected == "appLog") RenderLog(); });
        tools.Changed += () => DispatcherQueue.TryEnqueue(() => { if (shown) Render(); });
        tools.SyslogChanged += () => DispatcherQueue.TryEnqueue(SyslogTick);
    }

    public void Shown()
    {
        shown = true;
        Render();
        if (session.Ready) _ = tools.RunDiagnostics(force: false);
    }

    // MARK: Sidebar

    void BuildSidebar()
    {
        Sidebar.Children.Clear();
        var res = Application.Current.Resources;
        string? section = null;
        foreach (var t in All)
        {
            if (t.Section != section)
            {
                section = t.Section;
                Sidebar.Children.Add(new TextBlock { Text = section, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    Foreground = (Brush)res["TextFillColorSecondaryBrush"], Margin = new Thickness(12, Sidebar.Children.Count == 0 ? 0 : 20, 0, 6) });
            }
            var icon = Icon(t, 16);
            icon.Width = 20;
            var label = new TextBlock { Text = t.Title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            content.Children.Add(icon); content.Children.Add(label);
            var b = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                MinHeight = 34, Padding = new Thickness(12, 0, 12, 0), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(0, 1, 0, 1), Tag = t.Key };
            b.Click += (_, _) => Select((string)b.Tag);
            rows[t.Key] = b;
            Sidebar.Children.Add(b);
        }
    }

    FrameworkElement Icon(Tool t, double size)
    {
        var fg = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        if (t.Glyph == "#") return new TextBlock { Text = "#", FontSize = size + 2, FontWeight = Microsoft.UI.Text.FontWeights.Light, Foreground = fg, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        return new FontIcon { Glyph = t.Glyph, FontSize = size, Foreground = fg, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    }

    void Select(string key)
    {
        if (selected == "systemLog" && key != "systemLog") tools.StopSyslog();
        selected = key;
        Render();
    }

    // MARK: Rendering

    bool Ready => session.Ready && !session.Busy && session.Status != "Locked" && (Session.Demo || Tools.Available);

    string StatusText => session.Info == null ? (session.Status == "Device tools not found" ? "No iPhone connected" : session.Status)
        : session.Status == "Locked" ? "Locked: unlock and tap Trust" : session.Loading ? "Reading library…" : "Ready";

    void Render()
    {
        var res = Application.Current.Resources;
        foreach (var (k, b) in rows)
        {
            var on = k == selected;
            b.Background = on ? (Brush)res["ControlFillColorSecondaryBrush"] : new SolidColorBrush(Colors.Transparent);
            ((StackPanel)b.Content).Children[1].SetValue(TextBlock.FontWeightProperty, on ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal);
        }
        var t = All.First(x => x.Key == selected);
        var big = Icon(t, 26);
        if (big is FontIcon fi) fi.FontWeight = Microsoft.UI.Text.FontWeights.Light;
        HeaderIcon.Content = big;
        Title.Text = t.Title;
        Blurb.Text = t.Blurb;
        Body.Content = selected switch
        {
            "restart" => Destructive("Restart iPhone", "Restart the iPhone?", "It disconnects while rebooting and comes back on its own.", async () => { session.Note("Restarting the iPhone"); var e = Session.Demo ? null : await session.Phone!.Restart(); session.Note(e == null ? "Restarting the iPhone: done" : "Restarting the iPhone: failed (is the iPhone unlocked and trusted?)"); }),
            "shutDown" => Destructive("Shut Down iPhone", "Shut down the iPhone?", "You will need to hold its side button to turn it on again.", async () => { session.Note("Shutting the iPhone down"); var e = Session.Demo ? null : await session.Phone!.ShutDown(); session.Note(e == null ? "Shutting the iPhone down: done" : "Shutting the iPhone down: failed (is the iPhone unlocked and trusted?)"); }),
            "enterRecovery" => EnterRecovery(),
            "exitRecovery" => ExitRecovery(),
            "rename" => Rename(),
            "identifiers" => Identifiers(),
            "report" => Report(),
            "unpair" => Destructive("Unpair This PC", "Unpair this PC from the iPhone?", "Decant and Apple Devices lose access until you tap Trust on the phone again.", tools.Unpair, Ready && (Session.Demo || Tools.Has("idevicepair"))),
            "battery" => Battery(),
            "diagnostics" => Diagnostics(),
            "crashReports" => CrashReports(),
            "systemLog" => Syslog(),
            "screenshot" => Screenshot(),
            "appLog" => AppLog(),
            "reread" => Reread(),
            _ => null,
        };
        Footer.Text = session.Info == null ? StatusText : (!Session.Demo && !Tools.Available ? "This build is missing the device services, so most tools cannot run" : "");
        Footer.Visibility = Footer.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: Shared pieces

    static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    /// Label 160 wide in secondary, value medium with tabular digits, 32 high, hairline below.
    static Grid RowGrid() { var g = new Grid(); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) }); g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); return g; }

    static void AddRow(Grid g, string label, string? value, FrameworkElement? trailing = null, bool mono = false)
    {
        int r = g.RowDefinitions.Count;
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        var line = new Border { BorderBrush = Res("DividerStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        Grid.SetRow(line, r); Grid.SetColumnSpan(line, 2); g.Children.Add(line);
        var l = new TextBlock { Text = label, FontSize = 13, Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetRow(l, r); g.Children.Add(l);
        var v = new TextBlock { Text = value ?? "–", FontSize = 13, VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = mono,
            FontWeight = mono ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.Medium };
        if (mono) v.FontFamily = (FontFamily)Application.Current.Resources["MonoFont"];
        FrameworkElement cell = v;
        if (trailing != null)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(trailing, 1);
            row.Children.Add(v); row.Children.Add(trailing);
            cell = row;
        }
        Grid.SetRow(cell, r); Grid.SetColumn(cell, 1); g.Children.Add(cell);
    }

    static TextBlock Caption(string text) => new() { Text = text, FontSize = 12, Foreground = Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap };
    static TextBlock Heading(string text) => new() { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium };

    FrameworkElement Destructive(string label, string confirm, string message, Func<Task> action, bool? enabled = null)
    {
        var b = new Button { Content = label, IsEnabled = enabled ?? Ready, HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += async (_, _) =>
        {
            var d = new ContentDialog { Title = confirm, Content = message, PrimaryButtonText = label, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot };
            if (await d.ShowAsync() == ContentDialogResult.Primary) await action();
        };
        return b;
    }

    static FrameworkElement Framed(FrameworkElement inner) => new Border
    {
        Child = inner, Height = 440, HorizontalAlignment = HorizontalAlignment.Stretch, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
        BorderBrush = Res("CardStrokeColorDefaultBrush"), Background = Res("CardBackgroundFillColorDefaultBrush"),
    };

    static void Reveal(string path) { try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true }); } catch { } }

    static FrameworkElement SavedLine(string text, string path)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        p.Children.Add(new TextBlock { Text = text, FontSize = 12, Foreground = Res("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 560, VerticalAlignment = VerticalAlignment.Center });
        var link = new HyperlinkButton { Content = "Show in Explorer", FontSize = 12, Padding = new Thickness(0) };
        link.Click += (_, _) => Reveal(path);
        p.Children.Add(link);
        return p;
    }

    // MARK: Tools

    FrameworkElement EnterRecovery()
    {
        var p = new StackPanel { Spacing = 12 };
        var g = RowGrid(); AddRow(g, "Current mode", tools.Mode); p.Children.Add(g);
        p.Children.Add(Destructive("Enter Recovery Mode", "Put the iPhone in recovery mode?", "The screen shows the restore symbol. Exit Recovery brings it back without changing anything.",
            tools.EnterRecovery, Ready && (Session.Demo || Tools.Has("ideviceenterrecovery")) && !tools.Running));
        return p;
    }

    FrameworkElement ExitRecovery()
    {
        var p = new StackPanel { Spacing = 12 };
        var g = RowGrid(); AddRow(g, "Current mode", tools.Mode); p.Children.Add(g);
        var h = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var exit = new Button { Content = "Exit Recovery Mode", IsEnabled = (Session.Demo || Tools.Has("irecovery")) && !tools.Running };
        exit.Click += async (_, _) => await tools.ExitRecovery();
        var check = new Button { Content = "Check Mode", IsEnabled = !tools.Running };
        check.Click += async (_, _) => await tools.RefreshMode();
        h.Children.Add(exit); h.Children.Add(check);
        p.Children.Add(h);
        return p;
    }

    FrameworkElement Rename()
    {
        var h = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var current = session.Info?.Name ?? "";
        var box = new TextBox { PlaceholderText = "Name", Width = 280, Text = current };
        var b = new Button { Content = "Rename", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        void Update() => b.IsEnabled = Ready && box.Text.Trim().Length > 0 && box.Text != current;
        box.TextChanged += (_, _) => Update();
        Update();
        b.Click += async (_, _) =>
        {
            var name = box.Text.Trim();
            session.Note($"Renaming the iPhone to {name}");
            string? err = null;
            if (Session.Demo) { if (session.Info != null) session.Info.Name = name; }
            else err = await session.Phone!.Rename(name);
            session.Note(err == null ? $"Renaming the iPhone to {name}: done" : $"Renaming the iPhone to {name}: failed (is the iPhone unlocked and trusted?)");
            if (err == null) _ = session.Refresh(false);
        };
        h.Children.Add(box); h.Children.Add(b);
        return h;
    }

    bool reveal;

    FrameworkElement Identifiers()
    {
        var i = session.Info;
        if (i == null) return Caption("Connect an iPhone to read its identifiers");
        var p = new StackPanel { Spacing = 12 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new TextBlock { Text = "Reveal", FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var sw = new ToggleSwitch { IsOn = reveal, OnContent = "", OffContent = "", MinWidth = 0, Margin = new Thickness(0, -4, 0, -4) };
        sw.Toggled += (_, _) => { reveal = sw.IsOn; Render(); };
        head.Children.Add(sw);
        p.Children.Add(head);
        var g = RowGrid();
        p.Children.Add(g);
        p.Children.Add(Caption("Treat these like passwords: together they identify this exact phone."));
        _ = FillIdentifiers(g, i);
        return p;
    }

    async Task FillIdentifiers(Grid g, DeviceInfo i)
    {
        var id = await tools.ReadIdentity();
        var pairs = new (string, string)[]
        {
            ("Serial number", i.Serial), ("UDID", i.Udid), ("ECID", i.Ecid), ("IMEI", id.Imei), ("IMEI 2", id.Imei2), ("MEID", id.Meid),
            ("Wi‑Fi address", i.WifiAddress), ("Bluetooth address", i.BluetoothAddress), ("Model", i.Model), ("Model number", i.ModelNumber + i.Region), ("Baseband serial", id.BasebandSerial),
        };
        g.Children.Clear(); g.RowDefinitions.Clear();
        foreach (var (label, value) in pairs)
        {
            if (value.Length == 0) continue;
            var copy = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(4), BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent), Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(copy, "Copy");
            var real = value;
            copy.Click += (_, _) => { var d = new DataPackage(); d.SetText(real); Clipboard.SetContent(d); };
            AddRow(g, label, reveal ? value : new string('•', Math.Min(value.Length, 24)), copy, mono: true);
        }
    }

    FrameworkElement Report()
    {
        var p = new StackPanel { Spacing = 12 };
        var b = new Button { Content = "Save Device Report…", Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = Ready, HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += async (_, _) =>
        {
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = $"{session.Info?.Name ?? "iPhone"} device report" };
            picker.FileTypeChoices.Add("Property list", new List<string> { ".plist" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
            var f = await picker.PickSaveFileAsync();
            if (f == null) return;
            if (await tools.SaveReport(f.Path)) Render();
        };
        p.Children.Add(b);
        if (tools.LastReport != null) p.Children.Add(SavedLine($"Saved to {tools.LastReport}", tools.LastReport));
        return p;
    }

    FrameworkElement CrashReports()
    {
        var p = new StackPanel { Spacing = 12 };
        var b = new Button { Content = "Copy Crash Reports…", Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Left,
            IsEnabled = Ready && (Session.Demo || Tools.Has("idevicecrashreport")) };
        b.Click += async (_, _) =>
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, CommitButtonText = "Save crash reports here" };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
            var f = await picker.PickSingleFolderAsync();
            if (f == null) return;
            if (await tools.CopyCrashReports(f.Path)) Render();
        };
        p.Children.Add(b);
        if (tools.LastCrashExport is (string dir, int n)) p.Children.Add(SavedLine($"{n} reports in {dir}", dir));
        return p;
    }

    FrameworkElement Screenshot()
    {
        var p = new StackPanel { Spacing = 12 };
        var b = new Button { Content = "Take Screenshot", Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Left,
            IsEnabled = Ready && (Session.Demo || Tools.Has("idevicescreenshot")) };
        b.Click += async (_, _) => { await tools.Screenshot(); Render(); };
        p.Children.Add(b);
        if (tools.LastScreenshot != null && File.Exists(tools.LastScreenshot))
        {
            var img = new Image { MaxHeight = 420, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
            img.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(tools.LastScreenshot));
            p.Children.Add(new Border { Child = img, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), BorderBrush = Res("CardStrokeColorDefaultBrush"), HorizontalAlignment = HorizontalAlignment.Left });
            p.Children.Add(SavedLine(Path.GetFileName(tools.LastScreenshot), tools.LastScreenshot));
        }
        else if (tools.LastScreenshotError != null)
            p.Children.Add(new TextBlock { Text = tools.LastScreenshotError, FontSize = 12, Foreground = new SolidColorBrush(Tone.Warning), TextWrapping = TextWrapping.Wrap });
        return p;
    }

    FrameworkElement Battery()
    {
        var b = session.Battery;
        if (b == null) return Caption("Connect an iPhone to read its battery");
        var p = new StackPanel { Spacing = 12 };
        var g = RowGrid();
        AddRow(g, "Charge", b.Level is int l ? $"{l}%" : null);
        AddRow(g, "State", b.Charging ? "Charging" : "On battery");
        AddRow(g, "Health", b.Health is int h ? $"{h}% of design capacity" : null);
        AddRow(g, "Cycle count", b.CycleCount?.ToString("N0"));
        AddRow(g, "Design capacity", b.DesignCapacity is int dc ? $"{dc:N0} mAh" : null);
        AddRow(g, "Current full capacity", b.MaxCapacity is int mc ? $"{mc:N0} mAh" : null);
        AddRow(g, "Temperature", b.Temperature is double t ? $"{t:0.0} °C" : null);
        p.Children.Add(g);
        p.Children.Add(Caption("Apple replaces batteries under warranty below 80% health. Figures refresh every 30 seconds while connected."));
        p.Children.Add(History());
        return p;
    }

    FrameworkElement History()
    {
        var samples = tools.History;
        var p = new StackPanel { Spacing = 12, Margin = new Thickness(0, 8, 0, 0) };
        var head = new Grid();
        head.Children.Add(Heading("History"));
        head.Children.Add(new TextBlock { Text = DeviceTools.HistorySpan(samples), FontSize = 12, Foreground = Res("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Right });
        p.Children.Add(head);
        var health = samples.Where(s => s.Health != null).ToList();
        if (health.Count >= 2)
        {
            var charts = new Grid { ColumnSpacing = 24 };
            charts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            charts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var hc = new LineChart("Health"); hc.Set(health.Select(s => (s.Date, s.Health!.Value)), "0'%'");
            var cc = new LineChart("Cycles"); cc.Set(health.Where(s => s.CycleCount != null).Select(s => (s.Date, (double)s.CycleCount!.Value)), "0");
            Grid.SetColumn(cc, 1);
            charts.Children.Add(hc); charts.Children.Add(cc);
            p.Children.Add(charts);
            var cycles = health[^1].CycleCount?.ToString("N0") ?? "–";
            p.Children.Add(Caption($"{health[0].Health:0}% health when Decant first saw this phone, {health[^1].Health:0}% now · {cycles} cycles"));
        }
        else p.Children.Add(Caption("Each time the iPhone connects, Decant notes its health and cycle count here. After a few weeks the trend shows whether the battery is ageing normally (about 1% of health per 25 cycles is typical)."));
        return p;
    }

    FrameworkElement Diagnostics()
    {
        var p = new StackPanel { Spacing = 20 };
        var b = session.Battery;
        var charging = new StackPanel { Spacing = 6 };
        charging.Children.Add(Heading("Charging"));
        var g = RowGrid();
        string? state = b == null ? null : b.Charging ? "Charging" : b.ExternalConnected ? "Plugged in, not charging" : "On battery";
        AddRow(g, "State", state);
        string? charger = b?.AdapterWatts is int w ? $"{w} W" + (b.AdapterName != null ? $" · {b.AdapterName}" : "") : b != null && !b.ExternalConnected ? "None" : null;
        AddRow(g, "Charger", charger);
        string? power = null;
        if (b?.Voltage is double v && b.Amperage is double a)
        {
            var watts = v * a;
            power = Math.Abs(watts) < 0.05 ? "Idle" : $"{Math.Abs(watts):0.0} W {(watts > 0 ? "into the battery" : "from the battery")}";
        }
        AddRow(g, "Power now", power);
        AddRow(g, "Voltage", b?.Voltage is double vv ? $"{vv:0.00} V" : null);
        AddRow(g, "Current", b?.Amperage is double aa ? $"{aa:0.00} A" : null);
        AddRow(g, "Temperature", b?.Temperature is double t ? $"{t:0.0} °C" : null);
        charging.Children.Add(g);
        charging.Children.Add(Caption("A 20 W charger on a good cable shows 15 to 20 W into the battery below 80%. A few watts means a weak cable, a USB-A port or a hot phone."));
        p.Children.Add(charging);

        var tests = new StackPanel { Spacing = 6 };
        var head = new Grid();
        head.Children.Add(Heading("Self-tests"));
        var again = new Button { Content = "Run Again", HorizontalAlignment = HorizontalAlignment.Right, IsEnabled = session.Info != null && !session.Busy, Padding = new Thickness(10, 4, 10, 4), FontSize = 12 };
        again.Click += async (_, _) => { await tools.RunDiagnostics(); Render(); };
        head.Children.Add(again);
        tests.Children.Add(head);
        var tg = RowGrid();
        AddRow(tg, "Battery gauge", tools.DiagStatus("GasGauge"));
        AddRow(tg, "Gauge cycle count", tools.DiagLong("GasGauge", "CycleCount")?.ToString("N0"));
        AddRow(tg, "Gauge full charge", tools.DiagLong("GasGauge", "FullChargeCapacity") is long fc ? $"{fc:N0} mAh" : null);
        AddRow(tg, "Storage (NAND)", tools.DiagStatus("NAND"));
        AddRow(tg, "Wi-Fi", tools.DiagStatus("WiFi"));
        AddRow(tg, "Video out", tools.DiagStatus("HDMI"));
        tests.Children.Add(tg);
        tests.Children.Add(Caption(tools.Diagnostics == null ? "The self-tests run when the phone connects." : "These are the checks iOS runs on itself; Decant only asks for the results. Deeper storage or logic-board diagnostics need Apple's tools."));
        p.Children.Add(tests);
        return p;
    }

    // MARK: System log

    TextBox? filterBox; CheckBox? pauseBox; TextBlock? countLabel; Button? startButton; ListView? logList; TextBlock? logEmpty;
    readonly DispatcherTimer syslogTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    bool syslogDirty;

    FrameworkElement Syslog()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var bar = new Grid { Padding = new Thickness(12), ColumnSpacing = 12, BorderBrush = Res("DividerStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        filterBox = new TextBox { PlaceholderText = "Filter", Width = 220 };
        filterBox.TextChanged += (_, _) => SyslogTick(true);
        pauseBox = new CheckBox { Content = "Pause", IsChecked = false, VerticalAlignment = VerticalAlignment.Center };
        var clear = new Button { Content = "Clear" };
        clear.Click += (_, _) => tools.ClearSyslog();
        countLabel = new TextBlock { Text = "0 lines", FontSize = 13, Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        startButton = new Button { Content = tools.SyslogRunning ? "Stop" : "Start", Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            IsEnabled = session.Info != null && (Session.Demo || Tools.Has("idevicesyslog")) };
        startButton.Click += (_, _) => { if (tools.SyslogRunning) tools.StopSyslog(); else tools.StartSyslog(); startButton.Content = tools.SyslogRunning ? "Stop" : "Start"; SyslogTick(true); };
        Grid.SetColumn(pauseBox, 1); Grid.SetColumn(clear, 2); Grid.SetColumn(countLabel, 4); Grid.SetColumn(startButton, 5);
        bar.Children.Add(filterBox); bar.Children.Add(pauseBox); bar.Children.Add(clear); bar.Children.Add(countLabel); bar.Children.Add(startButton);
        root.Children.Add(bar);
        var body = new Grid();
        logList = new ListView { SelectionMode = ListViewSelectionMode.None, Padding = new Thickness(8), IsItemClickEnabled = false };
        logList.ItemContainerStyle = new Style(typeof(ListViewItem)) { Setters = { new Setter(ListViewItem.MinHeightProperty, 0), new Setter(ListViewItem.PaddingProperty, new Thickness(4, 1, 4, 1)) } };
        logList.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><TextBlock Text=\"{Binding}\" FontSize=\"11\" FontFamily=\"Cascadia Mono, Consolas\" IsTextSelectionEnabled=\"True\" TextWrapping=\"NoWrap\" /></DataTemplate>");
        logEmpty = new TextBlock { Text = "Press Start to stream the phone's log", FontSize = 13, Foreground = Res("TextFillColorSecondaryBrush"), Margin = new Thickness(16, 12, 16, 12), VerticalAlignment = VerticalAlignment.Top };
        body.Children.Add(logList); body.Children.Add(logEmpty);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        syslogTimer.Tick -= SyslogTimerTick; syslogTimer.Tick += SyslogTimerTick;
        syslogTimer.Start();
        SyslogTick(true);
        return Framed(root);
    }

    void SyslogTick() => syslogDirty = true;
    void SyslogTick(bool now) { syslogDirty = true; if (now) SyslogTimerTick(null, null!); }

    void SyslogTimerTick(object? s, object e)
    {
        if (!syslogDirty || logList == null || selected != "systemLog") return;
        syslogDirty = false;
        var filter = filterBox?.Text ?? "";
        List<string> lines;
        lock (tools.Syslog) lines = filter.Length == 0 ? tools.Syslog.ToList() : tools.Syslog.Where(l => l.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
        countLabel!.Text = $"{lines.Count:N0} lines";
        var shownLines = lines.Count > 2000 ? lines.GetRange(lines.Count - 2000, 2000) : lines;
        logList.ItemsSource = shownLines;
        logEmpty!.Text = tools.SyslogRunning ? "Waiting for log lines…" : "Press Start to stream the phone's log";
        logEmpty.Visibility = shownLines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        startButton!.Content = tools.SyslogRunning ? "Stop" : "Start";
        if (pauseBox?.IsChecked != true && shownLines.Count > 0) logList.ScrollIntoView(shownLines[^1]);
    }

    // MARK: Decant log, re-read

    TextBlock? appLogText; ScrollViewer? appLogScroll;

    FrameworkElement AppLog()
    {
        appLogText = new TextBlock { FontSize = 12, FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, LineHeight = 18 };
        appLogScroll = new ScrollViewer { Content = appLogText, Padding = new Thickness(12) };
        RenderLog();
        return Framed(appLogScroll);
    }

    void RenderLog()
    {
        if (appLogText == null) return;
        appLogText.Text = string.Join("\n", session.Log);
        appLogScroll?.UpdateLayout();
        appLogScroll?.ChangeView(null, appLogScroll.ScrollableHeight, null, true);
    }

    FrameworkElement Reread()
    {
        var h = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var b = new Button { Content = "Re-read Library", Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = session.Info != null && !session.Busy };
        b.Click += async (_, _) => { await session.Refresh(true); session.Note($"Library re-read: {session.Items.Count:N0} items"); Render(); };
        h.Children.Add(b);
        h.Children.Add(new TextBlock { Text = $"{session.Items.Count:N0} items · {Format.Gb(session.TotalBytes)}", FontSize = 13, Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        return h;
    }
}
