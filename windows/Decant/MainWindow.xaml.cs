using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics;
using Decant.Engine;

namespace Decant;

public sealed partial class MainWindow : Window
{
    public static Session Session { get; } = new();
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(5) };

    public MainWindow()
    {
        InitializeComponent();
        var plain = Environment.GetEnvironmentVariable("DECANT_PLAIN") == "1";
        if (!plain)
        {
            SystemBackdrop = new MicaBackdrop();
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(TopBar);
        }
        AppWindow.Title = "Decant";
        var size = Environment.GetEnvironmentVariable("DECANT_WINDOW")?.Split('x');
        var w = size?.Length == 2 && int.TryParse(size[0], out var sw) ? sw : 1000;
        var h = size?.Length == 2 && int.TryParse(size[1], out var sh) ? sh : 835;
        AppWindow.ResizeClient(new SizeInt32(w, h));
        if (size != null) AppWindow.Move(new PointInt32(40, 40));
        if (AppWindow.Presenter is OverlappedPresenter p) p.PreferredMinimumWidth = 900;
        TopBar.SizeChanged += (_, _) => UpdatePassthrough();
        Tabs.SizeChanged += (_, _) => UpdatePassthrough();

        Device.Attach(Session, this);
        Photos.Attach(Session, this);
        if (Environment.GetEnvironmentVariable("DECANT_TAB") == "photos") { DeviceTab.IsSelected = false; PhotosTab.IsSelected = true; Tabs.SelectedItem = PhotosTab; ShowTab(true); }
        Session.Changed += () => DispatcherQueue.TryEnqueue(RenderChip);
        RenderChip();
        _ = Session.Refresh();
        timer.Tick += (_, _) =>
        {
            if (Session.Busy || Session.Loading) return;
            // Look for a phone every 5 s while there is none; re-read battery and storage every 30 s while there is one.
            if (Session.Phone == null) _ = Session.Refresh();
            else if (DateTime.Now.Second % 30 < 5) _ = Session.Refresh(false);
        };
        timer.Start();
        // DECANT_SHOT=<file.png>: lay the window out at the DECANT_WINDOW size whatever the display allows, render
        // the tree to a PNG (the README screenshots come from a small virtual display), then quit.
        var shot = Environment.GetEnvironmentVariable("DECANT_SHOT");
        if (shot != null)
        {
            Root.Width = w; Root.Height = h;
            Caption.Visibility = Visibility.Visible;
            Root.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            t.Tick += async (_, _) => { t.Stop(); await SaveShot(shot); Close(); };
            t.Start();
        }
    }

    async Task SaveShot(string path)
    {
        try
        {
            var rtb = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
            await rtb.RenderAsync(Root);
            var pixels = (await rtb.GetPixelsAsync()).ToArray();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            var enc = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
            enc.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, pixels);
            await enc.FlushAsync();
            var bytes = new byte[stream.Size];
            await stream.ReadAsync(bytes.AsBuffer(), (uint)stream.Size, Windows.Storage.Streams.InputStreamOptions.None);
            File.WriteAllBytes(path, bytes);
            App.Trace($"shot: {rtb.PixelWidth}x{rtb.PixelHeight} -> {path}");
        }
        catch (Exception e) { App.Trace("shot failed: " + e); }
    }

    /// Controls inside the title bar must be excluded from the drag region or they would not take clicks.
    void UpdatePassthrough()
    {
        try
        {
            var scale = Content.XamlRoot?.RasterizationScale ?? 1;
            RectInt32 R(FrameworkElement e)
            {
                var t = e.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(0, 0));
                return new RectInt32((int)(t.X * scale), (int)(t.Y * scale), (int)(e.ActualWidth * scale), (int)(e.ActualHeight * scale));
            }
            InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, new[] { R(Tabs), R(Chip) });
        }
        catch { }
    }

    void Tabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowTab(sender.SelectedItem == PhotosTab);

    void ShowTab(bool photos)
    {
        Device.Visibility = photos ? Visibility.Collapsed : Visibility.Visible;
        Photos.Visibility = photos ? Visibility.Visible : Visibility.Collapsed;
        if (photos) Photos.Shown();
    }

    void RenderChip()
    {
        var s = Session;
        if (s.Info != null)
        {
            ChipName.Text = s.Info.Name;
            ChipBattery.Text = s.Battery?.Level is int l ? $"{l}%" : "";
            ChipDot.Fill = new SolidColorBrush(s.Status == "Ready" ? Tone.Ready : Tone.Warning);
        }
        else
        {
            ChipName.Text = s.Status == "Device tools not found" ? "No device tools" : "No iPhone";
            ChipBattery.Text = "";
            ChipDot.Fill = new SolidColorBrush(s.Status == "Device tools not found" ? Tone.Warning : Tone.Idle);
        }
    }

    public nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);
}

/// Semantic colours, toned down, used only for meaning (DESIGN.md).
public static class Tone
{
    public static readonly Windows.UI.Color Ready = ColorHelper.FromArgb(255, 0x4C, 0xC3, 0x8A);
    public static readonly Windows.UI.Color Warning = ColorHelper.FromArgb(255, 0xE0, 0x9A, 0x2E);
    public static readonly Windows.UI.Color Idle = ColorHelper.FromArgb(255, 0x8E, 0x8E, 0x93);
}
