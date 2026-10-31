// Thumbnails for the grid and the phone's screen: the phone's own JPEG previews, or in demo mode one of nine square
// windows into a wallpaper so one picture reads as many.
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Decant.Engine;

namespace Decant.Views;

public static class Thumbnails
{
    static readonly Dictionary<string, ImageSource> cache = new();

    public static async Task<ImageSource?> Load(IPhone phone, MediaItem item, int size = 320)
    {
        var key = $"{item.RemotePath}|{item.ThumbnailCrop}|{size}";
        if (cache.TryGetValue(key, out var hit)) return hit;
        try
        {
            IRandomAccessStream stream;
            if (item.ThumbnailCrop != null && item.ThumbnailPath != null && File.Exists(item.ThumbnailPath))
                stream = File.OpenRead(item.ThumbnailPath).AsRandomAccessStream();
            else
            {
                var bytes = await phone.Thumbnail(item);
                if (bytes == null) return null;
                var ms = new InMemoryRandomAccessStream();
                await ms.WriteAsync(bytes.AsBuffer());
                ms.Seek(0);
                stream = ms;
            }
            using (stream)
            {
                var decoder = await BitmapDecoder.CreateAsync(stream);
                var w = decoder.OrientedPixelWidth; var h = decoder.OrientedPixelHeight;
                var t = new BitmapTransform();
                if (item.ThumbnailCrop is int c)
                {
                    var side = Math.Min(w, h) * 42 / 100;
                    var i = c % 9;
                    t.Bounds = new BitmapBounds { X = (w - side) * (uint)(i % 3) / 2, Y = (h - side) * (uint)(i / 3) / 2, Width = side, Height = side };
                    var scale = (double)size / side;
                    t.ScaledWidth = (uint)Math.Max(1, Math.Round(w * scale)); t.ScaledHeight = (uint)Math.Max(1, Math.Round(h * scale));
                    t.Bounds = new BitmapBounds { X = (uint)(t.Bounds.X * scale), Y = (uint)(t.Bounds.Y * scale), Width = (uint)(side * scale), Height = (uint)(side * scale) };
                }
                else if (Math.Max(w, h) > size)
                {
                    var scale = (double)size / Math.Max(w, h);
                    t.ScaledWidth = (uint)Math.Max(1, Math.Round(w * scale)); t.ScaledHeight = (uint)Math.Max(1, Math.Round(h * scale));
                }
                var sb = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, t, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
                var src = new SoftwareBitmapSource();
                await src.SetBitmapAsync(sb);
                cache[key] = src;
                return src;
            }
        }
        catch { return null; }
    }
}
