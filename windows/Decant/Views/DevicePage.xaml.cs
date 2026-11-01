using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Storage.Pickers;
using Decant.Engine;

namespace Decant.Views;

public sealed partial class DevicePage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;
    readonly System.Collections.ObjectModel.ObservableCollection<ImageSource> screen = new();
    string screenKey = "";

    public DevicePage() { InitializeComponent(); Screen.ItemsSource = screen; }

    public void Shown() { }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        s.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Logged += l => DispatcherQueue.TryEnqueue(() => { LogText.Text += (LogText.Text.Length > 0 ? "\n" : "") + l; });
        LogText.Text = string.Join("\n", s.Log);
        Render();
    }

    // MARK: Rendering

    void Render()
    {
        try { RenderInner(); } catch (Exception e) { App.Trace("DevicePage.Render: " + e); }
    }

    void RenderInner()
    {
        var s = session;
        var ready = s.Info != null;
        Content.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        Empty.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        if (!ready)
        {
            if (s.Status == "Device tools not found")
            {
                EmptyTitle.Text = "Device tools not found";
                EmptyText.Text = "Decant talks to the phone through libimobiledevice. Put its Windows build in the Tools folder next to Decant.exe, or on the PATH, and install the Apple Devices app for the USB driver";
                EmptyDetail.Text = "missing: " + string.Join(", ", Tools.Missing);
                EmptyDetail.Visibility = Visibility.Visible;
            }
            else
            {
                EmptyTitle.Text = s.Status == "Locked" ? "iPhone is locked" : s.Loading ? "Looking for an iPhone" : "No iPhone connected";
                EmptyText.Text = s.Status == "Locked" ? "Unlock it and tap Trust" : "Connect the iPhone with a cable, unlock it, and tap Trust on the phone if it asks";
                EmptyDetail.Visibility = Visibility.Collapsed;
            }
            RenderBottom();
            return;
        }
        var i = s.Info!;
        ModelName.Text = i.MarketingName;
        Capacity.Text = s.Storage != null ? Format.Gb(s.Storage.Capacity) : "";
        PhoneTitle.Text = i.MarketingName;
        PhoneStatus.Text = s.Loading ? "Reading" : s.Status;
        Island.Visibility = i.HasIsland ? Visibility.Visible : Visibility.Collapsed;
        Island.Width = i.HasIsland ? 46 : 70; Island.Height = i.HasIsland ? 13 : 20;
        if (!i.HasIsland) { Island.Visibility = Visibility.Visible; Island.Margin = new Thickness(0, 8, 0, 0); Island.CornerRadius = new CornerRadius(0, 0, 10, 10); }

        Table(InfoLeft, new[]
        {
            ("Device name", i.Name), ("iOS version", i.Version), ("Model", i.Model), ("Serial number", Mask(i.Serial)),
            ("Connection", "USB"), ("Photos", Format.Count(s.PhotoCount)), ("Live Photos", Format.Count(s.LiveCount)),
        });
        if (i.Serial.Length > 0) SerialRow(InfoLeft, 3, i.Serial);
        Table(InfoRight, new[]
        {
            ("Wi-Fi address", i.WifiAddress), ("Bluetooth address", i.BluetoothAddress), ("Model number", i.ModelNumber), ("Region", i.Region),
            ("Status", s.Status), ("Videos", Format.Count(s.VideoCount)), ("Camera roll", Format.Gb(s.TotalBytes)),
        });

        var b = s.Battery;
        BatteryState.Text = b == null ? "" : b.Charging ? "Charging" : b.ExternalConnected ? "Plugged in" : "On battery";
        var rows = new List<(string, string)>();
        if (b?.Level is int lv) rows.Add(("Level", $"{lv}%"));
        if (b?.Health is int hp) rows.Add(("Health", $"{hp}%"));
        if (b?.CycleCount is int cc) rows.Add(("Cycles", cc.ToString("N0")));
        if (b?.MaxCapacity is int mc && b.DesignCapacity is int dc) rows.Add(("Capacity", $"{mc:N0} of {dc:N0} mAh"));
        if (b?.Watts is double w) rows.Add(("Power", $"{w:0.#} W in"));
        if (b?.AdapterWatts is int aw) rows.Add(("Charger", $"{aw} W · {b.AdapterName ?? "USB"}"));
        if (b?.Temperature is double t) rows.Add(("Temperature", $"{t:0.#} °C"));
        Table(BatteryTable, rows.ToArray(), valueRight: true);

        RenderStorage();
        RenderBottom();
        _ = RenderScreen();
    }

    static string Mask(string serial) => serial.Length == 0 ? "" : new string('•', Math.Min(12, serial.Length));
    bool serialShown;

    /// The serial number row gets an eye button that reveals the value (hidden by default so screenshots are safe).
    void SerialRow(Grid g, int row, string serial)
    {
        var v = (TextBlock)g.Children.First(c => Grid.GetRow((FrameworkElement)c) == row && Grid.GetColumn((FrameworkElement)c) == 1);
        v.Text = serialShown ? serial : Mask(serial);
        var eye = new Button { Content = new FontIcon { Glyph = serialShown ? "\uED1A" : "\uE7B3", FontSize = 12 }, Padding = new Thickness(4),
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
        ToolTipService.SetToolTip(eye, serialShown ? "Hide serial number" : "Show serial number");
        eye.Click += (_, _) => { serialShown = !serialShown; Render(); };
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        g.Children.Remove(v); panel.Children.Add(v); panel.Children.Add(eye);
        Grid.SetRow(panel, row); Grid.SetColumn(panel, 1); g.Children.Add(panel);
    }

    void RenderStorage()
    {
        var st = session.Storage;
        StorageBar.Children.Clear(); StorageBar.ColumnDefinitions.Clear(); Legend.Children.Clear();
        if (st == null) { StorageUsed.Text = ""; return; }
        StorageUsed.Text = $"{Format.Gb(st.Used)} of {Format.Gb(st.Capacity)} used";
        // Settings' own colours, in Settings' order: apps, music, messages, photos, mail, iOS, free.
        var parts = new List<(string, long, Windows.UI.Color)>();
        void Add(string n, long? v, byte r, byte g, byte b2) { if (v is long x && x > 0) parts.Add((n, x, ColorHelper.FromArgb(255, r, g, b2))); }
        Add("Applications", st.Apps, 0xFF, 0x3B, 0x30); Add("Music", st.Music, 0xFF, 0x95, 0x00); Add("Messages", st.Messages, 0xFF, 0xCC, 0x00);
        Add("Photos", st.Photos, 0x34, 0xC7, 0x59); Add("Mail", st.Mail, 0x00, 0x7A, 0xFF); Add("iOS", st.System, 0x8E, 0x8E, 0x93);
        var other = st.Used - parts.Sum(p => p.Item2);
        if (st.Apps == null && other > 0) parts.Insert(0, ("Apps and other", other, ColorHelper.FromArgb(255, 0xFF, 0x3B, 0x30)));
        parts.Add(("Free", st.Free, Colors.Transparent));
        int col = 0;
        foreach (var (name, bytes, color) in parts)
        {
            StorageBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(bytes, 1), GridUnitType.Star) });
            if (color != Colors.Transparent)
            {
                var r = new Rectangle { Fill = new SolidColorBrush(color), Margin = new Thickness(0, 0, 1, 0) };
                Grid.SetColumn(r, col);
                StorageBar.Children.Add(r);
            }
            col++;
            var dot = new Ellipse { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center,
                Fill = color == Colors.Transparent ? (Brush)Application.Current.Resources["ControlStrongFillColorDisabledBrush"] : new SolidColorBrush(color) };
            var lbl = new TextBlock { Text = name, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            Legend.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { dot, lbl } });
        }
        var rows = new List<(string, string)>();
        if (st.Apps is long a) rows.Add(("Applications and their data", Format.Gb(a)));
        if (st.Music is long m) rows.Add(("Music", Format.Gb(m)));
        if (st.Messages is long ms) rows.Add(("Messages", Format.Gb(ms)));
        if (st.Photos is long ph) rows.Add(("Photos and videos", Format.Gb(ph)));
        if (st.Mail is long ml) rows.Add(("Mail", Format.Gb(ml)));
        if (st.System is long sy) rows.Add(("iOS", Format.Gb(sy)));
        rows.Add(("Free", Format.Gb(st.Free)));
        Table(Breakdown, rows.ToArray(), valueRight: true);
        AppsPanel.Visibility = session.Apps.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Table(AppsTable, session.Apps.Take(8).Select(x => (x.Name, Format.Gb(x.Bytes))).ToArray(), valueRight: true);
    }

    void RenderBottom()
    {
        var s = session;
        var dest = s.Settings.PhotosFolder;
        var parts = dest.TrimEnd('\\').Split('\\');
        DestPath.Text = string.Join(" › ", parts.Skip(Math.Max(0, parts.Length - 2)));
        DestFree.Text = Settings.FreeSpace(dest) is long f ? $"{Format.Gb(f)} free" : "";
        var busy = s.Busy;
        ProgressPanel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        DestPanel.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        CancelButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        MoveAll.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        CopyAll.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        MoveAll.IsEnabled = CopyAll.IsEnabled = s.Ready && s.Items.Count > 0 && !s.Loading;
        if (s.Progress is OffloadProgress p)
        {
            Progress.Maximum = Math.Max(1, p.Total); Progress.Value = p.Done;
            ProgressText.Text = $"{p.Current}, {p.Done + 1:N0} of {p.Total:N0}";
        }
    }

    async Task RenderScreen()
    {
        var s = session;
        if (s.Phone == null) { screen.Clear(); screenKey = ""; return; }
        var items = s.Items.Where(i => !i.IsVideo).Take(21).ToList();
        var key = string.Join("|", items.Select(i => i.Name));
        if (key == screenKey) return;
        screenKey = key;
        screen.Clear();
        foreach (var item in items)
        {
            var src = await Thumbnails.Load(s.Phone, item, 160);
            if (screenKey != key) return;
            if (src != null) screen.Add(src);
        }
    }

    /// A two-column table of 32 pt rows with a hairline under each: label in the secondary colour, value in the text colour.
    static void Table(Grid g, (string, string)[] rows, bool valueRight = false)
    {
        g.Children.Clear(); g.RowDefinitions.Clear(); g.ColumnDefinitions.Clear();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = valueRight ? GridLength.Auto : new GridLength(120) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var hair = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"];
        for (int r = 0; r < rows.Length; r++)
        {
            g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
            var line = new Border { BorderBrush = hair, BorderThickness = new Thickness(0, 0, 0, r == rows.Length - 1 ? 0 : 1) };
            Grid.SetRow(line, r); Grid.SetColumnSpan(line, 2); g.Children.Add(line);
            var l = new TextBlock { Text = rows[r].Item1, Style = (Style)Application.Current.Resources["Label"] };
            var v = new TextBlock { Text = rows[r].Item2, Style = (Style)Application.Current.Resources["Value"],
                HorizontalAlignment = valueRight ? HorizontalAlignment.Right : HorizontalAlignment.Left, FontWeight = Microsoft.UI.Text.FontWeights.Medium };
            Grid.SetRow(l, r); Grid.SetRow(v, r); Grid.SetColumn(v, 1);
            g.Children.Add(l); g.Children.Add(v);
        }
    }

    // MARK: Actions

    void Refresh_Click(object sender, RoutedEventArgs e) => _ = session.Refresh();
    void Cancel_Click(object sender, RoutedEventArgs e) => session.CancelOffload();
    void CopyAll_Click(object sender, RoutedEventArgs e) => _ = session.Offload(session.Items, move: false);

    async void MoveAll_Click(object sender, RoutedEventArgs e)
    {
        var n = session.Items.Count;
        if (await Confirm("Move everything to this PC?", $"{n:N0} items will be copied to {session.Settings.PhotosFolder}, each one checked against the phone, and then deleted from the phone", "Move")) 
            _ = session.Offload(session.Items, move: true);
    }

    async void Restart_Click(object sender, RoutedEventArgs e)
    {
        if (session.Phone != null && await Confirm("Restart the iPhone?", "It will be back in about a minute", "Restart"))
            session.Note(await session.Phone.Restart() ?? "Restarting the iPhone");
    }

    async void ShutDown_Click(object sender, RoutedEventArgs e)
    {
        if (session.Phone != null && await Confirm("Shut the iPhone down?", "You will need to press its side button to turn it on again", "Shut down"))
            session.Note(await session.Phone.ShutDown() ?? "Shutting the iPhone down");
    }

    async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (session.Phone == null) return;
        var box = new TextBox { Text = session.Info?.Name ?? "", PlaceholderText = "Name" };
        var d = new ContentDialog { Title = "Rename the iPhone", Content = box, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary };
        if (await d.ShowAsync() == ContentDialogResult.Primary && box.Text.Trim().Length > 0)
        {
            var err = await session.Phone.Rename(box.Text.Trim());
            session.Note(err ?? $"Renamed the iPhone to {box.Text.Trim()}");
            _ = session.Refresh(false);
        }
    }

    async void Change_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        var folder = await picker.PickSingleFolderAsync();
        if (folder == null) return;
        session.Settings.PhotosFolder = folder.Path;
        session.Settings.Save();
        session.Note($"Photos go to {folder.Path}");
        RenderBottom();
    }

    async void Reveal_Click(object sender, RoutedEventArgs e)
    {
        try { Directory.CreateDirectory(session.Settings.PhotosFolder); await Windows.System.Launcher.LaunchFolderPathAsync(session.Settings.PhotosFolder); } catch { }
    }

    async Task<bool> Confirm(string title, string text, string action)
    {
        var d = new ContentDialog { Title = title, Content = text, PrimaryButtonText = action, CloseButtonText = "Cancel", XamlRoot = XamlRoot };
        return await d.ShowAsync() == ContentDialogResult.Primary;
    }
}
