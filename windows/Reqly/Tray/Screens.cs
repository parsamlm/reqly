using System.Runtime.InteropServices;
using Windows.Graphics;

namespace Reqly.Tray;

/// <summary>The screens' scaling, as Settings › System › Display sets it for each one.</summary>
internal static partial class Screens
{
    private const uint NearestMonitor = 2;
    private const uint PrimaryMonitor = 1;
    private const int EffectiveDpi = 0;

    /// <summary>The scaling of the screen with this point on it, or of the nearest one: 1 at 100%.</summary>
    public static double ScaleAt(PointInt32 point) => Dpi(MonitorFromPoint(new Point { X = point.X, Y = point.Y }, NearestMonitor)) / 96.0;

    /// <summary>The DPI of the main screen, the one with the notification area: 96 at 100%.</summary>
    public static uint MainDpi() => Dpi(MonitorFromPoint(new Point(), PrimaryMonitor));

    private static uint Dpi(IntPtr monitor) => GetDpiForMonitor(monitor, EffectiveDpi, out var x, out _) == 0 ? x : 96;

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll")]
    private static partial IntPtr MonitorFromPoint(Point point, uint flags);

    [LibraryImport("shcore.dll")]
    private static partial int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
}
