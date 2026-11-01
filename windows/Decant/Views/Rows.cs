// Small builders the Backup and Firmware pages share: the Mac's 32 px label/value rows with a hairline under each,
// link-style buttons, status dots and the two-step confirm dialogs.
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Decant.Views;

public static class Rows
{
    public static Brush Res(string key) => (Brush)Application.Current.Resources[key];
    public static TextBlock Secondary(string text, double size = 13) => new() { Text = text, FontSize = size, Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
    public static TextBlock Tertiary(string text, double size = 13) => new() { Text = text, FontSize = size, Foreground = Res("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
    public static TextBlock Value(string text, bool mono = false) => new()
    {
        Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis, FontFamily = mono ? (FontFamily)Application.Current.Resources["MonoFont"] : FontFamily.XamlAutoFontFamily,
    };

    /// A 32 px row: label (secondary, fixed width), content, hairline below unless `last`.
    public static Grid Row(string label, UIElement content, double labelWidth = 128, bool last = false)
    {
        var g = new Grid { Height = 32, BorderBrush = Res("DividerStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, last ? 0 : 1) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(labelWidth) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = Secondary(label);
        g.Children.Add(l);
        Grid.SetColumn((FrameworkElement)content, 1);
        if (content is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(content);
        return g;
    }

    public static Grid Row(string label, string value, double labelWidth = 128, bool last = false, bool mono = false) => Row(label, Value(value, mono), labelWidth, last);

    public static HyperlinkButton Link(string text, Action click, double size = 13)
    {
        var b = new HyperlinkButton { Content = text, FontSize = size, Padding = new Thickness(4, 2, 4, 2), VerticalAlignment = VerticalAlignment.Center };
        b.Click += (_, _) => click();
        return b;
    }

    public static Button Small(string text, Action click, bool enabled = true)
    {
        var b = new Button { Content = text, IsEnabled = enabled, FontSize = 12, Padding = new Thickness(10, 3, 10, 4), MinHeight = 26 };
        b.Click += (_, _) => click();
        return b;
    }

    public static Ellipse Dot(bool on) => new() { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center, Fill = on ? new SolidColorBrush(Tone.Ready) : Res("TextFillColorTertiaryBrush") };

    public static StackPanel H(double spacing, params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing, VerticalAlignment = VerticalAlignment.Center };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    public static Rectangle Divider() => new() { Height = 1, Fill = Res("DividerStrokeColorDefaultBrush"), HorizontalAlignment = HorizontalAlignment.Stretch };

    /// A confirm dialog; returns true when the primary (destructive) button was chosen.
    public static async Task<bool> Confirm(XamlRoot root, string title, string message, string primary, UIElement? extra = null)
    {
        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        if (extra != null) body.Children.Add(extra);
        var d = new ContentDialog { XamlRoot = root, Title = title, Content = body, PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        return await d.ShowAsync() == ContentDialogResult.Primary;
    }

    public static async Task Info(XamlRoot root, string title, string message)
    {
        var d = new ContentDialog { XamlRoot = root, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, CloseButtonText = "OK" };
        await d.ShowAsync();
    }

    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            else if (Directory.Exists(path)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
            else if (System.IO.Path.GetDirectoryName(path) is string parent && Directory.Exists(parent)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{parent}\"") { UseShellExecute = true });
        }
        catch { }
    }

    public static async Task<string?> PickFolder(nint hwnd, string? start = null)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add("*");
        var f = await picker.PickSingleFolderAsync();
        return f?.Path;
    }
}
