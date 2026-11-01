using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Decant.Engine;

namespace Decant.Views;

public sealed class FilterRow
{
    public string Title = ""; public string Glyph = ""; public int Count; public int? Year; public string Kind = "all";
    public string CountText => Count.ToString("N0");
}

public sealed class Tile : INotifyPropertyChanged
{
    public MediaItem Item = null!;
    ImageSource? thumb;
    public ImageSource? Thumb { get => thumb; set { thumb = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumb))); } }
    public string Badge => Item.IsVideo ? Format.Duration(Item.Duration) : Item.Format;
    public Visibility BadgeVisible => Item.IsVideo || Item.Format != "HEIC" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LiveVisible => Item.IsLivePhoto ? Visibility.Visible : Visibility.Collapsed;
    public event PropertyChangedEventHandler? PropertyChanged;
}

public sealed partial class PhotosPage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;
    readonly ObservableCollection<FilterRow> filters = new();
    readonly ObservableCollection<Tile> tiles = new();
    string itemsKey = "";
    bool shown;

    public PhotosPage() { InitializeComponent(); Filters.ItemsSource = filters; Items.ItemsSource = tiles; }

    public void Attach(Session s, MainWindow w)
    {
        session = s; window = w;
        s.Changed += () => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    public void Shown() { shown = true; Render(); }

    void Render()
    {
        var s = session;
        var key = s.Phone?.Udid + "|" + string.Join(",", s.Items.Select(i => i.Name));
        if (key != itemsKey)
        {
            itemsKey = key;
            var selected = (Filters.SelectedItem as FilterRow);
            filters.Clear();
            filters.Add(new FilterRow { Title = "All items", Glyph = "\uE8B9", Count = s.Items.Count, Kind = "all" });
            filters.Add(new FilterRow { Title = "Photos", Glyph = "\uEB9F", Count = s.PhotoCount, Kind = "photos" });
            filters.Add(new FilterRow { Title = "Videos", Glyph = "\uE714", Count = s.VideoCount, Kind = "videos" });
            filters.Add(new FilterRow { Title = "Live Photos", Glyph = "\uE9D9", Count = s.LiveCount, Kind = "live" });
            foreach (var g in s.Items.Where(i => i.Date != null).GroupBy(i => i.Date!.Value.Year).OrderByDescending(g => g.Key))
                filters.Add(new FilterRow { Title = g.Key.ToString(), Glyph = "\uE787", Count = g.Count(), Year = g.Key, Kind = "year" });
            Filters.SelectedItem = filters.FirstOrDefault(f => f.Kind == selected?.Kind && f.Year == selected?.Year) ?? filters[0];
            Fill();
        }
        EmptyGrid.Visibility = s.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = s.Info == null ? (s.Status == "Device tools not found" ? "Device tools not found" : "No iPhone connected") : s.Loading ? "Reading the camera roll" : "No photos";
        EmptyText.Text = s.Info == null ? "The camera roll appears here once a phone is connected" : s.Loading ? "This takes a moment" : "The camera roll is empty";
        var busy = s.Busy;
        ProgressPanel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SelectionText.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        CancelButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        foreach (var b in new[] { DeleteButton, MoveButton, CopyButton }) b.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        if (s.Progress is OffloadProgress p)
        {
            Progress.Maximum = Math.Max(1, p.Total); Progress.Value = p.Done;
            ProgressText.Text = $"{p.Current}, {p.Done + 1:N0} of {p.Total:N0}";
        }
        RenderSelection();
    }

    IEnumerable<MediaItem> Filtered()
    {
        var f = Filters.SelectedItem as FilterRow;
        return f?.Kind switch
        {
            "photos" => session.Items.Where(i => !i.IsVideo),
            "videos" => session.Items.Where(i => i.IsVideo),
            "live" => session.Items.Where(i => i.IsLivePhoto),
            "year" => session.Items.Where(i => i.Date?.Year == f.Year),
            _ => session.Items,
        };
    }

    void Fill()
    {
        tiles.Clear();
        var list = Filtered().ToList();
        foreach (var i in list) tiles.Add(new Tile { Item = i });
        Summary.Text = $"{list.Count:N0} items, {Format.Gb(list.Sum(i => i.Size))}";
        _ = LoadThumbs(list);
        RenderSelection();
    }

    async Task LoadThumbs(List<MediaItem> list)
    {
        var phone = session.Phone;
        if (phone == null) return;
        var snapshot = tiles.ToList();
        foreach (var t in snapshot)
        {
            if (!tiles.Contains(t)) return;
            if (t.Thumb != null) continue;
            t.Thumb = await Thumbnails.Load(phone, t.Item, 320);
        }
    }

    IEnumerable<MediaItem> Selected() => Items.SelectedItems.OfType<Tile>().Select(t => t.Item);

    void RenderSelection()
    {
        var sel = Selected().ToList();
        SelectionText.Text = sel.Count == 0 ? "" : $"{sel.Count:N0} selected, {Format.Gb(sel.Sum(i => i.Size))}";
        var can = sel.Count > 0 && session.Ready && !session.Busy;
        DeleteButton.IsEnabled = MoveButton.IsEnabled = CopyButton.IsEnabled = can;
    }

    void Filters_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (session != null) Fill(); }
    void Items_SelectionChanged(object sender, SelectionChangedEventArgs e) => RenderSelection();
    void SelectAll_Click(object sender, RoutedEventArgs e) => Items.SelectAll();
    void SelectNone_Click(object sender, RoutedEventArgs e) => Items.SelectedItems.Clear();
    void Cancel_Click(object sender, RoutedEventArgs e) => session.CancelOffload();
    void Copy_Click(object sender, RoutedEventArgs e) => _ = session.Offload(Selected().ToList(), move: false);

    async void Move_Click(object sender, RoutedEventArgs e)
    {
        var sel = Selected().ToList();
        if (await Confirm($"Move {sel.Count:N0} items to this PC?", $"They will be copied to {session.Settings.PhotosFolder}, each one checked against the phone, and then deleted from the phone", "Move"))
            _ = session.Offload(sel, move: true);
    }

    async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var sel = Selected().ToList();
        if (session.Phone == null || !await Confirm($"Delete {sel.Count:N0} items from the iPhone?", "They are not copied first", "Delete")) return;
        foreach (var i in sel) { var err = await session.Phone.Delete(i); session.Note(err == null ? $"{i.Name}: deleted from the phone" : $"{i.Name}: {err}"); }
        _ = session.Refresh(true);
    }

    async void Items_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((Items.SelectedItem as Tile)?.Item is not MediaItem item || session.Phone == null) return;
        // The viewer: the item is fetched to a temporary folder and opened with whatever Windows uses for it.
        var tmp = Path.Combine(Path.GetTempPath(), "Decant", "view");
        Directory.CreateDirectory(tmp);
        var local = Path.Combine(tmp, item.Name);
        var err = File.Exists(local) && new FileInfo(local).Length == item.Size ? null : await session.Phone.Copy(item, local);
        if (err != null) { session.Note($"{item.Name}: {err}"); return; }
        try { await Windows.System.Launcher.LaunchFileAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(local)); } catch (Exception ex) { session.Note(ex.Message); }
    }

    async Task<bool> Confirm(string title, string text, string action)
    {
        var d = new ContentDialog { Title = title, Content = text, PrimaryButtonText = action, CloseButtonText = "Cancel", XamlRoot = XamlRoot };
        return await d.ShowAsync() == ContentDialogResult.Primary;
    }
}
