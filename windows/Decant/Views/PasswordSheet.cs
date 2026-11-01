// Turn On / Turn Off Backup Encryption and Change Backup Password, as a ContentDialog (the Mac's PasswordSheet).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Decant.Views;

public enum PasswordMode { TurnOn, TurnOff, Change }

public sealed record PasswordResult(PasswordMode Mode, string Current, string New);

public static class PasswordSheet
{
    public static async Task<PasswordResult?> Show(XamlRoot root, PasswordMode mode)
    {
        var title = mode switch { PasswordMode.TurnOn => "Turn On Backup Encryption", PasswordMode.TurnOff => "Turn Off Backup Encryption", _ => "Change Backup Password" };
        var description = mode == PasswordMode.TurnOff
            ? "Future backups leave out Health data, saved passwords and Wi-Fi settings. Existing encrypted backups keep their password."
            : "Encrypted backups include Health data, saved passwords and Wi-Fi settings. Apple cannot recover a forgotten backup password; write it down.";
        var body = new StackPanel { Spacing = 16, Width = 412 };
        body.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, FontSize = 13, Foreground = Rows.Res("TextFillColorSecondaryBrush") });
        var fields = new Grid { ColumnSpacing = 12, RowSpacing = 8 };
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        PasswordBox? current = null, fresh = null, verify = null;
        int row = 0;
        PasswordBox Add(string label)
        {
            fields.RowDefinitions.Add(new RowDefinition());
            var l = Rows.Secondary(label); Grid.SetRow(l, row); fields.Children.Add(l);
            var p = new PasswordBox { Width = 260 }; Grid.SetRow(p, row); Grid.SetColumn(p, 1); fields.Children.Add(p);
            row++;
            return p;
        }
        if (mode != PasswordMode.TurnOn) current = Add("Current password");
        if (mode != PasswordMode.TurnOff) { fresh = Add(mode == PasswordMode.Change ? "New password" : "Password"); verify = Add("Verify"); }
        body.Children.Add(fields);
        var mismatch = new TextBlock { Text = "The passwords do not match", FontSize = 12, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Tone.Warning), Visibility = Visibility.Collapsed };
        body.Children.Add(mismatch);
        body.Children.Add(new TextBlock { Text = "The iPhone asks for its passcode to confirm.", FontSize = 12, Foreground = Rows.Res("TextFillColorSecondaryBrush") });
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = title, Content = body, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            PrimaryButtonText = mode switch { PasswordMode.TurnOn => "Turn On", PasswordMode.TurnOff => "Turn Off", _ => "Change" },
        };
        void Validate()
        {
            string cur = current?.Password ?? "", nw = fresh?.Password ?? "", vf = verify?.Password ?? "";
            mismatch.Visibility = mode != PasswordMode.TurnOff && vf != "" && vf != nw ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = mode switch
            {
                PasswordMode.TurnOn => nw != "" && nw == vf,
                PasswordMode.TurnOff => cur != "",
                _ => cur != "" && nw != "" && nw == vf,
            };
        }
        foreach (var p in new[] { current, fresh, verify }) if (p != null) p.PasswordChanged += (_, _) => Validate();
        Validate();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return new PasswordResult(mode, current?.Password ?? "", fresh?.Password ?? "");
    }
}
