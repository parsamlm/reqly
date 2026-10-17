using System.Runtime.InteropServices;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Reqly.Smoke;

/// <summary>
/// A picture of part of the screen as it shows, for the self-check: what a window's own picture
/// leaves out, such as its backdrop, its corners and where it sits.
/// </summary>
internal static partial class ScreenPicture
{
    public static async Task SaveAsync(RectInt32 area, string path)
    {
        var pixels = Capture(area);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)area.Width, (uint)area.Height, 96, 96, pixels);
        await encoder.FlushAsync();
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
        await File.WriteAllBytesAsync(path, bytes);
    }

    /// <summary>The area's pixels, top row first, in blue, green, red and an unused byte.</summary>
    private static unsafe byte[] Capture(RectInt32 area)
    {
        var screen = GetDC(IntPtr.Zero);
        var memory = CreateCompatibleDC(screen);
        var bitmap = CreateCompatibleBitmap(screen, area.Width, area.Height);
        var previous = SelectObject(memory, bitmap);
        // With layered windows, such as tooltips, too.
        BitBlt(memory, 0, 0, area.Width, area.Height, screen, area.X, area.Y, CopySource | CaptureLayered);
        SelectObject(memory, previous);
        var header = new BitmapInfoHeader { Size = (uint)sizeof(BitmapInfoHeader), Width = area.Width, Height = -area.Height, Planes = 1, BitCount = 32 };
        var pixels = new byte[area.Width * area.Height * 4];
        fixed (byte* bits = pixels)
        {
            GetDIBits(memory, bitmap, 0, (uint)area.Height, bits, ref header, 0);
        }
        DeleteObject(bitmap);
        DeleteDC(memory);
        ReleaseDC(IntPtr.Zero, screen);
        return pixels;
    }

    private const uint CopySource = 0x00CC0020;
    private const uint CaptureLayered = 0x40000000;

    /// <summary>BITMAPINFOHEADER, with no color table after it, for 32-bit pixels.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetDC(IntPtr window);

    [LibraryImport("user32.dll")]
    private static partial int ReleaseDC(IntPtr window, IntPtr context);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateCompatibleDC(IntPtr context);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateCompatibleBitmap(IntPtr context, int width, int height);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr SelectObject(IntPtr context, IntPtr item);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);

    [LibraryImport("gdi32.dll")]
    private static unsafe partial int GetDIBits(IntPtr context, IntPtr bitmap, uint start, uint lines, byte* bits, ref BitmapInfoHeader header, uint usage);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteObject(IntPtr item);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteDC(IntPtr context);
}
