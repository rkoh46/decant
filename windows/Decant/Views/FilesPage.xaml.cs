using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Decant.Engine;

namespace Decant.Views;

/// A sidebar line: a section header, a selectable location, or a note.
public sealed class SideRow
{
    public string Title = "", Glyph = "", Kind = "item";     // header | item | note
    public FileRoot? Root;
    public Visibility HeaderVisible => Kind == "header" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility NoteVisible => Kind == "note" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ItemVisible => Kind == "item" ? Visibility.Visible : Visibility.Collapsed;
}

public sealed class FileRow
{
    public RemoteEntry Entry = null!;
    public string Name => Entry.Name;
    public string Size => Entry.IsDirectory ? "–" : Format.Gb(Entry.Size);
    public string Modified => Entry.Modified is DateTime d ? d.ToString("MMM d, yyyy 'at' h:mm tt") : "–";
    public string Glyph
    {
        get
        {
            if (Entry.IsDirectory) return "";
            return Path.GetExtension(Entry.Name).ToLowerInvariant() switch
            {
                ".heic" or ".jpg" or ".jpeg" or ".png" or ".gif" or ".webp" => "",
                ".mov" or ".mp4" or ".m4v" => "",
                ".mp3" or ".m4a" or ".aac" or ".wav" or ".caf" => "",
                ".pdf" => "",
                ".zip" or ".ipa" => "",
                _ => "",
            };
        }
    }
    public Brush GlyphBrush => (Brush)Application.Current.Resources[Entry.IsDirectory ? "AccentFillColorDefaultBrush" : "TextFillColorSecondaryBrush"];
}

public sealed partial class FilesPage : UserControl, ITabPage
{
    public static FilesPage? Current;
    public static readonly FilesService Service = new();
    Session session = null!;
    MainWindow window = null!;
    readonly ObservableCollection<SideRow> side = new();
    readonly ObservableCollection<FileRow> rows = new();
    bool shown, settingSelection;
    string sideKey = "";

    public FilesPage() { InitializeComponent(); Side.ItemsSource = side; Table.ItemsSource = rows; Table.ContainerContentChanging += Stripe; }

    /// Every second row gets a faint fill, as the Mac's tables do.
    public static void Stripe(ListViewBase sender, ContainerContentChangingEventArgs e)
    {
        if (e.ItemContainer is ListViewItem c)
            c.Background = e.ItemIndex % 2 == 1 ? (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"] : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    public void Attach(Session s, MainWindow w)
    {
        Current = this;
        session = s; window = w;
        Service.Log = s.Note;
        Ringtones.Attach(s, w);
        if (Environment.GetEnvironmentVariable("DECANT_FILES") == "ringtones") Service.Root = new FileRoot.Ringtones();   // screenshot aid
        Service.Changed += () => DispatcherQueue.TryEnqueue(Render);
        AppsPage.Service.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { LoadIfNeeded(); Render(); });
        DispatcherQueue.TryEnqueue(Render);
    }

    public void Shown() { shown = true; LoadIfNeeded(); Render(); if (Service.Root is FileRoot.Ringtones) Ringtones.Shown(); }

    bool Ready => session.Ready && (Session.Demo || Tools.Available);

    void LoadIfNeeded()
    {
        if (!shown || !Ready) return;
        if (Service.Entries.Count == 0 && !Service.Loading && Service.Root is not FileRoot.Ringtones) { Service.Path_ = Service.HomePath; _ = Service.List(session.Udid); }
        if (AppsPage.Service.Apps.Count == 0 && !AppsPage.Service.Loading) _ = AppsPage.Service.Load(session.Udid, false);
    }

    /// The Apps tab's "Files" button lands here.
    public void OpenAppDocuments(string bundleId, string name)
    {
        Service.Root = new FileRoot.AppDocuments(bundleId, name);
        Service.Path_ = Service.HomePath;
        Table.SelectedItems.Clear();
        _ = Service.List(session.Udid);
        Render();
    }

    string Crumb_()
    {
        var home = Service.HomePath;
        var rel = Service.Path_ == home ? "" : Service.Path_[(home == "/" ? 0 : home.Length)..];
        return Service.Root.Title + rel;
    }

    void Render()
    {
        // Sidebar
        var sharing = AppsPage.Service.Apps.Where(a => a.FileSharing).ToList();
        var key = string.Join("|", sharing.Select(a => a.BundleId));
        if (key != sideKey)
        {
            sideKey = key;
            settingSelection = true;
            side.Clear();
            side.Add(new SideRow { Title = "Locations", Kind = "header" });
            side.Add(new SideRow { Title = "Media", Glyph = "", Root = new FileRoot.Media() });
            side.Add(new SideRow { Title = "Ringtones", Glyph = "", Root = new FileRoot.Ringtones() });
            side.Add(new SideRow { Title = "App documents", Kind = "header" });
            if (sharing.Count == 0) side.Add(new SideRow { Title = "Apps that share files appear here", Kind = "note" });
            foreach (var a in sharing) side.Add(new SideRow { Title = a.Name, Glyph = "", Root = new FileRoot.AppDocuments(a.BundleId, a.Name) });
            settingSelection = false;
        }
        var want = side.FirstOrDefault(r => r.Root != null && RootKey(r.Root) == RootKey(Service.Root));
        if (Side.SelectedItem != want) { settingSelection = true; Side.SelectedItem = want; settingSelection = false; }

        var ringtones = Service.Root is FileRoot.Ringtones;
        Ringtones.Visibility = ringtones ? Visibility.Visible : Visibility.Collapsed;
        Browser.Visibility = ringtones ? Visibility.Collapsed : Visibility.Visible;
        if (ringtones) return;

        var ready = Ready;
        BackButton.IsEnabled = Service.Path_ != Service.HomePath && !Service.Loading;
        Crumb.Text = Crumb_();
        Spinner.Visibility = Service.Loading ? Visibility.Visible : Visibility.Collapsed;
        CountText.Text = $"{Service.Entries.Count:N0} items";
        NewFolderButton.IsEnabled = ready && !Service.Running;
        UploadButton.IsEnabled = ready && !Service.Running;
        DownloadButton.IsEnabled = Table.SelectedItems.Count > 0 && !Service.Running;
        DeleteButton.IsEnabled = Table.SelectedItems.Count > 0 && !Service.Running;
        NotReady.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        NotReadyText.Text = session.Phone == null ? session.Status : "This build is missing the file service";
        Table.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        var rowKey = string.Join("|", Service.Entries.Select(e => e.Name + e.Size));
        if (rowKey != lastRowKey)
        {
            lastRowKey = rowKey;
            rows.Clear();
            foreach (var e in Service.Entries) rows.Add(new FileRow { Entry = e });
        }
        EmptyFolder.Visibility = ready && Service.Entries.Count == 0 && !Service.Loading ? Visibility.Visible : Visibility.Collapsed;
        MediaHelp.Visibility = Service.Root is FileRoot.Media ? Visibility.Visible : Visibility.Collapsed;
        var showBar = Service.Running || Service.Phase.Length > 0;
        StatusBar.Visibility = showBar ? Visibility.Visible : Visibility.Collapsed;
        StatusSpinner.Visibility = Service.Running ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = Service.Phase;
    }
    string lastRowKey = "";

    static string RootKey(FileRoot r) => r is FileRoot.AppDocuments a ? "app:" + a.BundleId : r.Title;

    // MARK: Sidebar and table

    void Side_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (settingSelection) return;
        if (Side.SelectedItem is not SideRow r || r.Root == null) { settingSelection = true; Side.SelectedItem = side.FirstOrDefault(x => x.Root != null && RootKey(x.Root) == RootKey(Service.Root)); settingSelection = false; return; }
        if (RootKey(r.Root) == RootKey(Service.Root)) return;
        Service.Root = r.Root;
        Service.Path_ = Service.HomePath;
        Table.SelectedItems.Clear();
        if (r.Root is FileRoot.Ringtones) { Ringtones.Shown(); Render(); return; }
        if (Ready) _ = Service.List(session.Udid);
        Render();
    }

    void Table_SelectionChanged(object sender, SelectionChangedEventArgs e) => Render();

    List<RemoteEntry> Selected => Table.SelectedItems.OfType<FileRow>().Select(r => r.Entry).ToList();

    void Table_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var sel = Selected;
        if (sel.Count == 1 && sel[0].IsDirectory) { Table.SelectedItems.Clear(); _ = Service.Open(session.Udid, sel[0]); }
    }

    void Table_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not FileRow row) return;
        if (!Table.SelectedItems.Contains(row)) { Table.SelectedItems.Clear(); Table.SelectedItems.Add(row); }
        var menu = new MenuFlyout();
        var sel = Selected;
        if (sel.Count == 1 && sel[0].IsDirectory)
        {
            var open = new MenuFlyoutItem { Text = "Open" };
            open.Click += (_, _) => { Table.SelectedItems.Clear(); _ = Service.Open(session.Udid, sel[0]); };
            menu.Items.Add(open);
        }
        var dl = new MenuFlyoutItem { Text = "Download…" }; dl.Click += (_, _) => Download_Click(this, new RoutedEventArgs()); menu.Items.Add(dl);
        var del = new MenuFlyoutItem { Text = "Delete…" }; del.Click += (_, _) => Delete_Click(this, new RoutedEventArgs()); menu.Items.Add(del);
        menu.ShowAt(Table, e.GetPosition(Table));
    }

    // MARK: Actions

    void Back_Click(object sender, RoutedEventArgs e) => _ = Service.Up(session.Udid);

    async void NewFolder_Click(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { PlaceholderText = "Name", MinWidth = 280 };
        var d = new ContentDialog { Title = "New Folder", Content = box, PrimaryButtonText = "Create", CloseButtonText = "Cancel", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false };
        box.TextChanged += (_, _) => d.IsPrimaryButtonEnabled = box.Text.Trim().Length > 0;
        if (await d.ShowAsync() == ContentDialogResult.Primary && box.Text.Trim().Length > 0) await Service.NewFolder(session.Udid, box.Text.Trim());
    }

    async void Upload_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, CommitButtonText = "Upload" };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0) await Service.Upload(session.Udid, files.Select(f => f.Path).ToList());
    }

    async void Download_Click(object sender, RoutedEventArgs e)
    {
        var sel = Selected;
        if (sel.Count == 0) return;
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Downloads, CommitButtonText = "Download here" };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        var folder = await picker.PickSingleFolderAsync();
        if (folder != null) await Service.Download(session.Udid, sel, folder.Path);
    }

    async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var sel = Selected;
        if (sel.Count == 0) return;
        var d = new ContentDialog
        {
            Title = $"Delete {sel.Count} {(sel.Count == 1 ? "item" : "items")} from the iPhone?",
            Content = "Files deleted here are gone; there is no Recently Deleted for them.",
            PrimaryButtonText = "Delete", CloseButtonText = "Cancel", XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() == ContentDialogResult.Primary) { Table.SelectedItems.Clear(); await Service.Delete(session.Udid, sel); }
    }

    // MARK: Drag and drop (upload)

    void Browser_DragOver(object sender, DragEventArgs e)
    {
        if (!Ready || !e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.None; return; }
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.IsCaptionVisible = false;
        DropOverlay.Background = new SolidColorBrush(((SolidColorBrush)Application.Current.Resources["AccentFillColorDefaultBrush"]).Color) { Opacity = 0.06 };
        DropOverlay.Visibility = Visibility.Visible;
    }

    void Browser_DragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    async void Browser_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var paths = (await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).Where(p => p.Length > 0).ToList();
        if (paths.Count > 0) await Service.Upload(session.Udid, paths);
    }
}
