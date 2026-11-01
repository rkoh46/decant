// The New Ringtone sheet: name, length, start point with a preview, as on the Mac. Built in code (one dialog, few controls).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Decant.Engine;

namespace Decant.Views;

public sealed class NewRingtoneDialog : ContentDialog
{
    readonly string path;
    readonly TextBlock subtitle = new() { FontSize = 12 };
    readonly TextBox nameBox = new() { PlaceholderText = "Name shown in Settings", Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
    readonly RadioButtons lengths = new();
    readonly Slider startSlider = new() { Minimum = 0, Maximum = 0.001, Width = 300, StepFrequency = 0.5, IsEnabled = false };
    readonly TextBlock startText = new() { FontSize = 12, Width = 48, VerticalAlignment = VerticalAlignment.Center };
    readonly Border track = new() { Height = 8, CornerRadius = new CornerRadius(3), Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Border segment = new() { Height = 8, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock range = new() { FontSize = 12 };
    readonly Button preview = new() { Content = "Preview", IsEnabled = false };
    double total;
    MediaPlayer? player;
    DispatcherTimer? stopTimer;

    public (string name, double start, double length)? Result { get; private set; }

    double Length => lengths.SelectedIndex switch { 1 => 40, 2 => 3600, _ => 30 };
    double EffLen => Math.Min(Length, Math.Max(1, total - startSlider.Value));

    public NewRingtoneDialog(string path)
    {
        this.path = path;
        var res = Application.Current.Resources;
        Title = "New Ringtone";
        PrimaryButtonText = "Add to iPhone"; CloseButtonText = "Cancel"; DefaultButton = ContentDialogButton.Primary;
        IsPrimaryButtonEnabled = false;
        subtitle.Foreground = (Brush)res["TextFillColorSecondaryBrush"];
        subtitle.Text = $"{Path.GetFileName(path)} · reading…";
        nameBox.Text = Path.GetFileNameWithoutExtension(path);
        foreach (var l in new[] { "30 seconds", "40 seconds", "Whole file" }) lengths.Items.Add(l);
        lengths.SelectedIndex = 0; lengths.MaxColumns = 3;
        track.Background = (Brush)res["ControlFillColorSecondaryBrush"];
        segment.Background = (Brush)res["ControlStrongFillColorDefaultBrush"];
        track.Child = segment;
        range.Foreground = (Brush)res["TextFillColorSecondaryBrush"];
        startText.Foreground = (Brush)res["TextFillColorSecondaryBrush"];
        Label("Name", nameBox, out var nameRow); Label("Length", lengths, out var lengthRow);
        var startPanel = new StackPanel { Spacing = 6 };
        startPanel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { startSlider, startText } });
        startPanel.Children.Add(track); startPanel.Children.Add(range);
        Label("Start at", startPanel, out var startRow);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { preview } };
        Content = new StackPanel { Spacing = 16, Width = 440, Children = { subtitle, nameRow, lengthRow, startRow, buttons } };
        nameBox.TextChanged += (_, _) => Update();
        lengths.SelectionChanged += (_, _) => Update();
        startSlider.ValueChanged += (_, _) => { Update(); if (player != null && player.CurrentState == MediaPlayerState.Playing) Play(); };
        preview.Click += (_, _) => { if (player?.CurrentState == MediaPlayerState.Playing) Stop(); else Play(); };
        PrimaryButtonClick += (_, _) => { Stop(); Result = (nameBox.Text.Trim(), startSlider.Value, EffLen); };
        CloseButtonClick += (_, _) => Stop();
        Loaded += async (_, _) => await ReadDuration();
    }

    static void Label(string text, FrameworkElement control, out Grid row)
    {
        row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = new TextBlock { Text = text, FontSize = 13, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0) };
        Grid.SetColumn(control, 1);
        row.Children.Add(l); row.Children.Add(control);
    }

    async Task ReadDuration()
    {
        try
        {
            var f = await StorageFile.GetFileFromPathAsync(path);
            var props = await f.Properties.GetMusicPropertiesAsync();
            var d = props.Duration.TotalSeconds;
            if (d <= 0) d = (await f.Properties.GetVideoPropertiesAsync()).Duration.TotalSeconds;
            total = d;
        }
        catch { total = 0; }
        subtitle.Text = $"{Path.GetFileName(path)} · {(total > 0 ? RingtoneService.Clock(total) : "reading…")}";
        startSlider.Maximum = Math.Max(total - 1, 0.001);
        startSlider.IsEnabled = total > 0;
        if (total > 0 && total < Length && total < 30) lengths.SelectedIndex = 2;
        Update();
    }

    void Update()
    {
        startText.Text = RingtoneService.Clock(startSlider.Value);
        var eff = EffLen;
        if (total > 0)
        {
            segment.Width = Math.Max(4, 300 * eff / total);
            segment.Margin = new Thickness(300 * startSlider.Value / total, 0, 0, 0);
        }
        range.Text = $"Tone: {RingtoneService.Clock(startSlider.Value)} to {RingtoneService.Clock(startSlider.Value + eff)}";
        preview.IsEnabled = total > 0;
        IsPrimaryButtonEnabled = nameBox.Text.Trim().Length > 0 && total > 0;
    }

    void Play()
    {
        Stop();
        player = new MediaPlayer { Source = MediaSource.CreateFromUri(new Uri(path)) };
        player.PlaybackSession.Position = TimeSpan.FromSeconds(startSlider.Value);
        player.Play();
        preview.Content = "Stop";
        var end = TimeSpan.FromSeconds(startSlider.Value + EffLen);
        stopTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        stopTimer.Tick += (_, _) => { if (player == null || player.PlaybackSession.Position >= end) Stop(); };
        stopTimer.Start();
    }

    void Stop()
    {
        stopTimer?.Stop(); stopTimer = null;
        if (player != null) { player.Pause(); player.Dispose(); player = null; }
        preview.Content = "Preview";
    }
}
