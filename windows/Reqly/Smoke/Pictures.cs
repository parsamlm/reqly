using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Reqly.Smoke;

/// <summary>Pictures of what a window shows, for the self-check, as WinUI draws them.</summary>
internal static class Pictures
{
    /// <summary>Saves a picture of an element as a PNG file, and says how it went, for the self-check's report.</summary>
    public static async Task<string> SaveAsync(UIElement element, string path)
    {
        try
        {
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(element);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            using var reader = new DataReader(stream.GetInputStreamAt(0));
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
            await File.WriteAllBytesAsync(path, bytes);
            return $"picture: {Path.GetFileName(path)}, {bitmap.PixelWidth}x{bitmap.PixelHeight}";
        }
        catch (Exception error)
        {
            return $"picture {Path.GetFileName(path)} failed: {error.Message}";
        }
    }
}
