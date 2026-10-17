using System.Runtime.InteropServices;

namespace Reqly;

/// <summary>Flashes a window's taskbar button until you come back to it, as when a breakpoint holds a request.</summary>
public static partial class Attention
{
    private const uint FlashTray = 0x2;
    private const uint FlashUntilForeground = 0xC;

    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo
    {
        public uint Size;
        public nint Window;
        public uint Flags;
        public uint Count;
        public uint Timeout;
    }

    public static void Ask(nint window)
    {
        if (GetForegroundWindow() == window)
        {
            return;
        }
        var info = new FlashInfo
        {
            Size = (uint)Marshal.SizeOf<FlashInfo>(),
            Window = window,
            Flags = FlashTray | FlashUntilForeground,
        };
        FlashWindowEx(ref info);
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool FlashWindowEx(ref FlashInfo info);

    [LibraryImport("user32.dll")]
    private static partial nint GetForegroundWindow();
}
