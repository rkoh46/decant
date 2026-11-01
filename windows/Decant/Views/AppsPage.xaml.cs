using System.Collections.ObjectModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Decant.Engine;

namespace Decant.Views;

/// One app as the list shows it.
public sealed class AppRow
{
    public InstalledApp App = null!;
    public bool Measuring, Running;
    public ImageSource? Icon;
    public string Name => App.Name;
    public string BundleId => App.BundleId;
    public string Subtitle
    {
        get
        {
            var parts = new List<string> { App.Developer.Length > 0 ? App.Developer : App.BundleId };
            if (App.Version.Length > 0) parts.Add(App.Version);
            if (App.Purchased is DateTime d) parts.Add("added " + d.ToString("MMM yyyy"));
            return string.Join(" · ", parts);
        }
    }
    public string Total => Format.Gb(App.TotalSize);
    public string SizeDetail => $"app {Format.Gb(App.StaticSize)} · data {Format.Gb(App.DynamicSize)}";
    public Visibility SizeVisible => App.TotalSize > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility MeasuringVisible => App.TotalSize == 0 && Measuring ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FilesVisible => App.FileSharing ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PlaceholderVisible => Icon == null ? Visibility.Visible : Visibility.Collapsed;
    public string PlaceholderGlyph => App.System ? "" : "";
    public bool CanUninstall => !App.System && !Running;
}

public sealed partial class AppsPage : UserControl, ITabPage
{
    /// Shared with the Files sidebar (app documents) and the Device dashboard.
    public static readonly AppsService Service = new();
    Session session = null!;
    MainWindow window = null!;
    readonly ObservableCollection<AppRow> rows = new();
    readonly Dictionary<string, BitmapImage> iconCache = new();
    string sort = "size";
    bool shown, loadedOnce;
    string lastUdid = "";

    public AppsPage() { InitializeComponent(); List.ItemsSource = rows; }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        Service.Log = s.Note;
        sort = s.Settings.AppsSort;
        Service.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { LoadIfNeeded(); Render(); });
        // Deferred: looking theme brushes up from code before the window has a theme pins the whole app to Light.
        DispatcherQueue.TryEnqueue(Render);
    }

    public void Shown() { shown = true; LoadIfNeeded(); Render(); }

    bool Ready => session.Ready && (Session.Demo || Tools.Available);

    /// Loads the list once per phone, the first time it is needed (the Files sidebar asks for it too).
    public void LoadIfNeeded(bool force = false)
    {
        if (!(shown || force) || !Ready) return;
        if (session.Udid != lastUdid) { lastUdid = session.Udid; loadedOnce = false; }
        if (loadedOnce || Service.Loading) return;
        loadedOnce = true;
        _ = Service.Load(session.Udid, SystemApps.IsChecked == true);
    }

    static readonly Comparer<string> byName = Natural.Comparer;

    IEnumerable<InstalledApp> ShownApps()
    {
        var q = Search.Text.Trim();
        IEnumerable<InstalledApp> apps = Service.Apps;
        if (q.Length > 0) apps = apps.Where(a => a.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || a.BundleId.Contains(q, StringComparison.OrdinalIgnoreCase));
        return sort switch
        {
            "name" => apps.OrderBy(a => a.Name, byName),
            "date" => apps.OrderByDescending(a => a.Purchased ?? DateTime.MinValue).ThenBy(a => a.Name, byName),
            "data" => apps.OrderByDescending(a => a.DynamicSize).ThenBy(a => a.Name, byName),
            _ => apps,
        };
    }

    ImageSource? IconFor(string id)
    {
        string? path;
        lock (Service.Icons) { if (!Service.Icons.TryGetValue(id, out path)) return null; }
        if (!iconCache.TryGetValue(id, out var img)) { img = new BitmapImage(new Uri(path)); iconCache[id] = img; }
        return img;
    }

    void Render()
    {
        var res = Application.Current.Resources;
        foreach (var b in SortBar.Children.OfType<Button>())
        {
            var on = (string)b.Tag == sort;
            b.Background = on ? (Brush)res["ControlFillColorSecondaryBrush"] : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            b.Foreground = (Brush)res[on ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"];
        }
        var ready = Ready;
        InstallButton.IsEnabled = ready && !Service.Running;
        RefreshButton.IsEnabled = ready && !Service.Loading;
        if (!ready)
        {
            List.Visibility = Visibility.Collapsed; LoadingPanel.Visibility = Visibility.Collapsed; Empty.Visibility = Visibility.Visible;
            EmptyText.Text = session.Phone == null ? session.Status : "This build is missing the app service";
            CountText.Text = "";
        }
        else if (Service.Loading && Service.Apps.Count == 0)
        {
            List.Visibility = Visibility.Collapsed; Empty.Visibility = Visibility.Collapsed; LoadingPanel.Visibility = Visibility.Visible;
            CountText.Text = "";
        }
        else
        {
            Empty.Visibility = Visibility.Collapsed; LoadingPanel.Visibility = Visibility.Collapsed; List.Visibility = Visibility.Visible;
            var apps = ShownApps().ToList();
            rows.Clear();
            foreach (var a in apps) rows.Add(new AppRow { App = a, Measuring = Service.Measuring, Running = Service.Running, Icon = IconFor(a.BundleId) });
            CountText.Text = Service.Measuring ? $"{apps.Count:N0} apps · measuring sizes…" : $"{apps.Count:N0} apps · {Format.Gb(apps.Sum(a => a.TotalSize))}";
        }
        var showBar = Service.Running || Service.Phase.Length > 0;
        StatusBar.Visibility = showBar ? Visibility.Visible : Visibility.Collapsed;
        StatusBar.Height = Service.Running ? 52 : 40;
        StatusSpinner.Visibility = Service.Running && Service.Progress == null ? Visibility.Visible : Visibility.Collapsed;
        StatusProgress.Visibility = Service.Running && Service.Progress != null ? Visibility.Visible : Visibility.Collapsed;
        if (Service.Progress is double p) StatusProgress.Value = p * 100;
        StatusText.Text = Service.Phase;
    }

    // MARK: Actions

    void Search_TextChanged(object sender, TextChangedEventArgs e) => Render();

    void Sort_Click(object sender, RoutedEventArgs e)
    {
        sort = (string)((Button)sender).Tag;
        session.Settings.AppsSort = sort; session.Settings.Save();
        Render();
    }

    void SystemApps_Toggled(object sender, RoutedEventArgs e)
    {
        if (session == null || !Ready) return;
        _ = Service.Load(session.Udid, SystemApps.IsChecked == true);
    }

    void Refresh_Click(object sender, RoutedEventArgs e) { if (Ready) _ = Service.Load(session.Udid, SystemApps.IsChecked == true); }

    async void Install_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads, CommitButtonText = "Install" };
        picker.FileTypeFilter.Add(".ipa");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        var f = await picker.PickSingleFileAsync();
        if (f != null) await Service.Install(session.Udid, f.Path);
    }

    void Files_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not AppRow r) return;
        window.ShowTab("files");
        FilesPage.Current?.OpenAppDocuments(r.App.BundleId, r.App.Name);
    }

    async void Uninstall_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not AppRow r) return;
        var d = new ContentDialog
        {
            Title = $"Uninstall {r.App.Name}?",
            Content = $"The app and its data ({Format.Gb(r.App.DynamicSize)}) are removed from the iPhone. Purchases can be downloaded again from the App Store.",
            PrimaryButtonText = "Uninstall", CloseButtonText = "Cancel", XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) await Service.Uninstall(session.Udid, r.App);
    }

    // MARK: Drag and drop (.ipa)

    void Page_DragOver(object sender, DragEventArgs e)
    {
        if (!Ready || !e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.None; return; }
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.IsCaptionVisible = false;
        DropOverlay.Background = new SolidColorBrush(((SolidColorBrush)Application.Current.Resources["AccentFillColorDefaultBrush"]).Color) { Opacity = 0.06 };
        DropOverlay.Visibility = Visibility.Visible;
    }

    void Page_DragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    async void Page_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        foreach (var item in await e.DataView.GetStorageItemsAsync())
            if (item is StorageFile f && f.Path.EndsWith(".ipa", StringComparison.OrdinalIgnoreCase)) await Service.Install(session.Udid, f.Path);
    }
}
