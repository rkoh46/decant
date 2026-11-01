// A small line chart for the battery history: faint gridlines, a secondary line through the samples, the accent
// colour on the last point, 10 px labels. Drawn with plain XAML shapes, as the Mac's Swift Charts version looks.
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace Decant.Views;

public sealed class LineChart : Grid
{
    readonly Canvas canvas = new() { Height = 120 };
    readonly TextBlock title = new() { FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
    readonly TextBlock last = new() { FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium };
    List<(DateTime date, double value)> points = new();
    string format = "0";

    public LineChart(string name)
    {
        title.Text = name;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 0, 0, 8) };
        head.Children.Add(title); head.Children.Add(last);
        Children.Add(head);
        Grid.SetRow(canvas, 1);
        Children.Add(canvas);
        canvas.SizeChanged += (_, _) => Draw();
    }

    public void Set(IEnumerable<(DateTime, double)> data, string valueFormat)
    {
        points = data.ToList(); format = valueFormat;
        last.Text = points.Count > 0 ? points[^1].value.ToString(format) + (format.EndsWith("%") ? "" : "") : "–";
        Draw();
    }

    public string Suffix = "";

    void Draw()
    {
        canvas.Children.Clear();
        var w = canvas.ActualWidth; var h = canvas.Height;
        if (w <= 0 || points.Count < 2) return;
        var res = Application.Current.Resources;
        var grid = (Brush)res["DividerStrokeColorDefaultBrush"];
        var line = (Brush)res["TextFillColorSecondaryBrush"];
        var faint = (Brush)res["TextFillColorTertiaryBrush"];
        var accent = (Brush)res["AccentFillColorDefaultBrush"];
        const double left = 34, bottom = 18, top = 6;
        var plotW = w - left; var plotH = h - bottom - top;
        var min = points.Min(p => p.value); var max = points.Max(p => p.value);
        if (max - min < 1e-9) { min -= 1; max += 1; }
        // Three "nice" ticks spanning the data, as the Mac's automatic axis does.
        var step = Nice((max - min) / 2);
        var lo = Math.Floor(min / step) * step; var hi = Math.Ceiling(max / step) * step;
        if ((hi - lo) / step > 3) { step = Nice(step * 2); lo = Math.Floor(min / step) * step; hi = Math.Ceiling(max / step) * step; }
        if (hi - lo < step * 2) hi = lo + step * 2;
        var t0 = points[0].date; var t1 = points[^1].date; var span = Math.Max(1, (t1 - t0).TotalSeconds);
        double X(DateTime d) => left + plotW * (d - t0).TotalSeconds / span;
        double Y(double v) => top + plotH * (1 - (v - lo) / (hi - lo));
        for (var v = lo; v <= hi + step / 2; v += step)
        {
            var y = Y(v);
            var l = new Line { X1 = left, X2 = w, Y1 = y, Y2 = y, Stroke = grid, StrokeThickness = 1 };
            canvas.Children.Add(l);
            var tb = new TextBlock { Text = v.ToString("0"), FontSize = 10, Foreground = faint };
            Canvas.SetLeft(tb, 0); Canvas.SetTop(tb, y - 7);
            canvas.Children.Add(tb);
        }
        for (int i = 0; i < 4; i++)
        {
            var d = t0.AddSeconds(span * (i + 0.5) / 4);
            var x = X(d);
            canvas.Children.Add(new Line { X1 = x, X2 = x, Y1 = top, Y2 = top + plotH, Stroke = grid, StrokeThickness = 1 });
            var tb = new TextBlock { Text = d.ToString("MMM yy"), FontSize = 10, Foreground = faint };
            Canvas.SetLeft(tb, x - 16); Canvas.SetTop(tb, h - bottom + 4);
            canvas.Children.Add(tb);
        }
        var poly = new Polyline { Stroke = line, StrokeThickness = 1.5, StrokeLineJoin = PenLineJoin.Round };
        foreach (var p in points) poly.Points.Add(new Point(X(p.date), Y(p.value)));
        canvas.Children.Add(poly);
        var dot = new Ellipse { Width = 7, Height = 7, Fill = accent };
        Canvas.SetLeft(dot, X(t1) - 3.5); Canvas.SetTop(dot, Y(points[^1].value) - 3.5);
        canvas.Children.Add(dot);
    }

    static double Nice(double x)
    {
        if (x <= 0) return 1;
        var p = Math.Pow(10, Math.Floor(Math.Log10(x)));
        var f = x / p;
        return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p;
    }
}
