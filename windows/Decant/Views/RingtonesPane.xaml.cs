using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Decant.Engine;

namespace Decant.Views;

public sealed class ToneRow
{
    public Ringtone Tone = null!;
    public string Name => Tone.Name;
    public string Length => Tone.Duration > 0 ? RingtoneService.Clock(Tone.Duration) : "–";
    public string File => Tone.File;
}

public sealed partial class RingtonesPane : UserControl
{
    public static readonly RingtoneService Service = new();
    Session session = null!;
    MainWindow window = null!;
    readonly ObservableCollection<ToneRow> rows = new();
    string rowKey = "";

    public RingtonesPane() { InitializeComponent(); Table.ItemsSource = rows; Table.ContainerContentChanging += FilesPage.Stripe; }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        Service.Log = s.Note;
        Service.Changed += () => DispatcherQueue.TryEnqueue(Render);
        s.Changed += () => DispatcherQueue.TryEnqueue(() => { LoadIfNeeded(); Render(); });
    }

    public void Shown() { LoadIfNeeded(); Render(); }

    bool Ready => session.Ready && (Session.Demo || Tools.Available);

    void LoadIfNeeded()
    {
        if (Visibility != Visibility.Visible && !(session.Ready && Service.Loaded == false)) return;
        if (Ready && !Service.Loaded && !Service.Loading) _ = Service.Load(session.Udid);
    }

    void Render()
    {
        var ready = Ready;
        var n = Service.Tones.Count;
        CountText.Text = $"{n} {(n == 1 ? "tone" : "tones")}";
        Spinner.Visibility = Service.Loading ? Visibility.Visible : Visibility.Collapsed;
        RemoveButton.IsEnabled = Table.SelectedItems.Count > 0 && !Service.Running;
        AddButton.IsEnabled = ready && !Service.Running;
        NotReady.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        NotReadyText.Text = session.Phone == null ? session.Status : "This build is missing the file service";
        Table.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        var key = string.Join("|", Service.Tones.Select(t => t.File + t.Name + t.Duration));
        if (key != rowKey) { rowKey = key; rows.Clear(); foreach (var t in Service.Tones) rows.Add(new ToneRow { Tone = t }); }
        EmptyPanel.Visibility = ready && Service.Loaded && !Service.Loading && n == 0 ? Visibility.Visible : Visibility.Collapsed;
        var showBar = Service.Running || Service.Phase.Length > 0;
        StatusBar.Visibility = showBar ? Visibility.Visible : Visibility.Collapsed;
        StatusSpinner.Visibility = Service.Running ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = Service.Phase;
    }

    void Table_SelectionChanged(object sender, SelectionChangedEventArgs e) => Render();

    async void Add_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = "Choose" };
        foreach (var ext in new[] { ".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".mp4", ".m4v", ".mov", ".caf", ".flac" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window.Hwnd);
        var f = await picker.PickSingleFileAsync();
        if (f != null) await NewRingtone(f.Path);
    }

    async Task NewRingtone(string path)
    {
        var sheet = new NewRingtoneDialog(path) { XamlRoot = XamlRoot };
        if (await sheet.ShowAsync() == ContentDialogResult.Primary && sheet.Result is var (name, start, length))
            await Service.Add(session.Udid, path, name, start, length);
    }

    async void Remove_Click(object sender, RoutedEventArgs e)
    {
        var sel = Table.SelectedItems.OfType<ToneRow>().Select(r => r.Tone).ToList();
        if (sel.Count == 0) return;
        var what = sel.Count == 1 ? (sel[0].Name.Length > 0 ? sel[0].Name : "this tone") : $"{sel.Count} tones";
        var d = new ContentDialog
        {
            Title = $"Remove {what} from the iPhone?",
            Content = "The tone is deleted from the phone. Keep the original audio file if you want it back.",
            PrimaryButtonText = "Remove", CloseButtonText = "Cancel", XamlRoot = XamlRoot,
        };
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        Table.SelectedItems.Clear();
        foreach (var t in sel) await Service.Remove(session.Udid, t);
    }

    // MARK: Drag and drop (one audio file)

    void Pane_DragOver(object sender, DragEventArgs e)
    {
        if (!Ready || !e.DataView.Contains(StandardDataFormats.StorageItems)) { e.AcceptedOperation = DataPackageOperation.None; return; }
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.IsCaptionVisible = false;
        DropOverlay.Background = new SolidColorBrush(((SolidColorBrush)Application.Current.Resources["AccentFillColorDefaultBrush"]).Color) { Opacity = 0.06 };
        DropOverlay.Visibility = Visibility.Visible;
    }

    void Pane_DragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    async void Pane_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var f = (await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>().FirstOrDefault();
        if (f != null) await NewRingtone(f.Path);
    }
}
