using System.Runtime.InteropServices;
using Microsoft.Win32;
using Windows.Graphics;

namespace Reqly.Tray;

/// <summary>
/// Reqly's icon in the notification area, at the end of the taskbar, through Windows' own
/// Shell_NotifyIcon. A hidden window of its own hears the icon's clicks, and what Windows says
/// about the taskbar: when Explorer starts again, the icon is added again, and when the taskbar
/// turns light or dark, or its scaling changes, the icon is drawn for it again.
/// </summary>
internal sealed unsafe partial class NotifyIcon : IDisposable
{
    private const string ClassName = "ReqlyNotifyIcon";
    private const uint IconID = 1;
    /// <summary>The message the icon's clicks come in, WM_APP + 1.</summary>
    private const uint CallbackMessage = 0x8001;

    private const uint AddIcon = 0;
    private const uint ModifyIcon = 1;
    private const uint DeleteIcon = 2;
    private const uint SetVersion = 4;
    private const uint HasMessage = 0x1;
    private const uint HasIcon = 0x2;
    private const uint HasTip = 0x4;
    private const uint HasInfo = 0x10;
    private const uint ShowsTip = 0x80;
    /// <summary>NOTIFYICON_VERSION_4: clicks come with where they were, and the icon has its own tooltip.</summary>
    private const uint Version4 = 4;
    private const uint InfoRespectsQuietTime = 0x80;

    private const uint Select = 0x400;
    private const uint KeySelect = 0x401;
    private const uint ContextMenu = 0x7B;
    private const uint DoubleClick = 0x203;
    private const uint SettingChange = 0x1A;
    private const uint DisplayChange = 0x7E;
    private const uint DpiChanged = 0x2E0;

    /// <summary>The one icon, for the window procedure, which Windows calls with no object.</summary>
    private static NotifyIcon? current;
    private static readonly uint TaskbarCreated = RegisterWindowMessage("TaskbarCreated");

    private readonly IntPtr window;
    private IntPtr icon;
    /// <summary>What the icon was drawn for: its size in pixels, and whether the taskbar was light.</summary>
    private (int Size, bool IsLight) drawnFor;
    private bool isAdded;
    /// <summary>Whether the icon should be in the notification area, as when the taskbar isn't there yet.</summary>
    private bool isWanted;
    private string tip = "Reqly";
    /// <summary>When Enter last chose the icon, in ms since Windows started: Windows says so twice for one press.</summary>
    private long keySelected = -10_000;

    /// <summary>The icon was clicked or chosen with the keyboard, at this point on the screen, in pixels.</summary>
    public event Action<PointInt32>? Invoked;

    /// <summary>The icon was double-clicked, which opens an app's window on Windows.</summary>
    public event Action? DoubleClicked;

    public NotifyIcon()
    {
        current = this;
        var instance = GetModuleHandle(IntPtr.Zero);
        fixed (char* name = ClassName)
        {
            var windowClass = new WindowClass
            {
                Size = (uint)sizeof(WindowClass),
                Procedure = &WindowProcedure,
                Instance = instance,
                ClassName = name,
            };
            // A second icon in the same run finds the class there already, which is fine.
            RegisterClassEx(ref windowClass);
        }
        // A top-level window, never shown, since a message-only one doesn't hear that Explorer started again.
        window = CreateWindowEx(ToolWindow, ClassName, "Reqly", Popup, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        // Reqly run as administrator hears it from a taskbar that isn't, too.
        ChangeWindowMessageFilterEx(window, TaskbarCreated, AllowMessage, IntPtr.Zero);
    }

    /// <summary>Whether the icon is in the notification area now.</summary>
    public bool IsAdded => isAdded;

    /// <summary>The icon's size in pixels and the taskbar it's drawn for, for the self-check.</summary>
    public string Describe() => $"{drawnFor.Size} px, for a {(drawnFor.IsLight ? "light" : "dark")} taskbar";

    /// <summary>What shows over the icon under the pointer: a line or two.</summary>
    public string Tip
    {
        get => tip;
        set
        {
            tip = value;
            if (isAdded)
            {
                Change(ModifyIcon, HasTip | ShowsTip);
            }
        }
    }

    /// <summary>
    /// Puts the icon in the notification area, if it isn't there yet. Without a taskbar, as just
    /// after you sign in, it goes there once the taskbar is.
    /// </summary>
    public bool Add()
    {
        isWanted = true;
        if (isAdded)
        {
            return true;
        }
        Draw();
        if (!Change(AddIcon, HasMessage | HasIcon | HasTip | ShowsTip))
        {
            AppLog.Write("couldn't add Reqly's icon to the notification area yet");
            return false;
        }
        var data = Data(0);
        data.TimeoutOrVersion = Version4;
        Shell_NotifyIcon(SetVersion, ref data);
        isAdded = true;
        return true;
    }

    public void Remove()
    {
        isWanted = false;
        if (isAdded)
        {
            Change(DeleteIcon, 0);
            isAdded = false;
        }
    }

    /// <summary>A notification from the icon, which Windows shows as its own, as it shows other apps'.</summary>
    public void Notify(string title, string text)
    {
        if (!isAdded)
        {
            return;
        }
        var data = Data(HasInfo);
        Copy(title, data.InfoTitle, 64);
        Copy(text, data.Info, 256);
        data.InfoFlags = InfoRespectsQuietTime;
        Shell_NotifyIcon(ModifyIcon, ref data);
    }

    /// <summary>Where the icon is on the screen, in pixels, while it shows.</summary>
    public RectInt32? Bounds
    {
        get
        {
            var identifier = new IconIdentifier { Size = (uint)sizeof(IconIdentifier), Window = window, ID = IconID };
            return isAdded && Shell_NotifyIconGetRect(ref identifier, out var rect) == 0
                ? new RectInt32(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top)
                : null;
        }
    }

    /// <summary>Says the icon was clicked, as Windows does, for the self-check: the mouse stays where it is.</summary>
    public void PostClick()
    {
        var bounds = Bounds ?? default;
        var x = bounds.X + bounds.Width / 2;
        var y = bounds.Y + bounds.Height / 2;
        PostMessage(window, CallbackMessage, ((y & 0xFFFF) << 16) | (x & 0xFFFF), (nint)((IconID << 16) | Select));
    }

    public void Dispose()
    {
        Remove();
        DestroyWindow(window);
        if (icon != IntPtr.Zero)
        {
            DestroyIcon(icon);
            icon = IntPtr.Zero;
        }
        if (current == this)
        {
            current = null;
        }
    }

    /// <summary>
    /// Loads the icon for the taskbar as it is: the glyph in black on a light taskbar and in white
    /// on a dark one, at the size Windows draws small icons at on the main screen.
    /// </summary>
    private void Draw()
    {
        var target = (Size: IconSize(), IsLight: TaskbarIsLight());
        if (icon != IntPtr.Zero && target == drawnFor)
        {
            return;
        }
        var file = Path.Combine(AppContext.BaseDirectory, "Assets", target.IsLight ? "NotificationIcon-on-light.ico" : "NotificationIcon-on-dark.ico");
        var loaded = LoadImage(IntPtr.Zero, file, ImageIcon, target.Size, target.Size, LoadFromFile);
        if (loaded == IntPtr.Zero)
        {
            AppLog.Write($"couldn't load the notification area's icon from {file}: error {Marshal.GetLastPInvokeError()}");
            return;
        }
        var old = icon;
        icon = loaded;
        drawnFor = target;
        if (isAdded)
        {
            Change(ModifyIcon, HasIcon);
        }
        if (old != IntPtr.Zero)
        {
            DestroyIcon(old);
        }
    }

    /// <summary>Whether Windows' own parts, the taskbar among them, are light, as Settings › Personalization › Colors chooses.</summary>
    private static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
    }

    /// <summary>The size of small icons on the main screen, which has the notification area: 16 pixels at 100%.</summary>
    private static int IconSize() => GetSystemMetricsForDpi(SmallIconWidth, Screens.MainDpi());

    private bool Change(uint change, uint flags)
    {
        var data = Data(flags);
        return Shell_NotifyIcon(change, ref data);
    }

    private NotifyIconData Data(uint flags)
    {
        var data = new NotifyIconData
        {
            Size = (uint)sizeof(NotifyIconData),
            Window = window,
            ID = IconID,
            Flags = flags,
            CallbackMessage = CallbackMessage,
            Icon = icon,
        };
        Copy(tip, data.Tip, 128);
        return data;
    }

    private static void Copy(string text, char* buffer, int capacity)
    {
        var length = Math.Min(text.Length, capacity - 1);
        text.AsSpan(0, length).CopyTo(new Span<char>(buffer, capacity));
        buffer[length] = '\0';
    }

    [UnmanagedCallersOnly]
    private static nint WindowProcedure(IntPtr window, uint message, nint wParam, nint lParam)
    {
        try
        {
            if (current is { } icon && icon.window == window && icon.Handle(message, wParam, lParam))
            {
                return 0;
            }
        }
        catch (Exception error)
        {
            // Nothing may go back through Windows' own code.
            AppLog.Write($"the notification area's icon failed: {error}");
        }
        return DefWindowProc(window, message, wParam, lParam);
    }

    private bool Handle(uint message, nint wParam, nint lParam)
    {
        if (message == CallbackMessage)
        {
            // With version 4, the event is in lParam's low word, and where it happened in wParam.
            var happened = (uint)(lParam & 0xFFFF);
            if (happened == KeySelect)
            {
                var now = Environment.TickCount64;
                var isRepeat = now - keySelected < 300;
                keySelected = now;
                if (isRepeat)
                {
                    return true;
                }
            }
            if (happened is Select or KeySelect or ContextMenu)
            {
                Invoked?.Invoke(new PointInt32((short)(wParam & 0xFFFF), (short)((wParam >> 16) & 0xFFFF)));
            }
            else if (happened == DoubleClick)
            {
                DoubleClicked?.Invoke();
            }
            return true;
        }
        if (message == TaskbarCreated)
        {
            // Explorer started, or started again, with a taskbar that hasn't heard of the icon.
            if (isWanted)
            {
                isAdded = false;
                Add();
            }
            return true;
        }
        if (message is SettingChange or DisplayChange or DpiChanged)
        {
            // Light or dark, or the scaling, may have changed; drawing again does nothing if neither did.
            Draw();
        }
        return false;
    }

    // MARK: Windows

    private const uint ToolWindow = 0x80;
    private const uint Popup = 0x80000000;
    private const uint AllowMessage = 1;
    private const uint ImageIcon = 1;
    private const uint LoadFromFile = 0x10;
    private const int SmallIconWidth = 49;

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowClass
    {
        public uint Size;
        public uint Style;
        public delegate* unmanaged<IntPtr, uint, nint, nint, nint> Procedure;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public char* MenuName;
        public char* ClassName;
        public IntPtr SmallIcon;
    }

    /// <summary>NOTIFYICONDATAW.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint ID;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        public fixed char Tip[128];
        public uint State;
        public uint StateMask;
        public fixed char Info[256];
        public uint TimeoutOrVersion;
        public fixed char InfoTitle[64];
        public uint InfoFlags;
        public Guid Item;
        public IntPtr BalloonIcon;
    }

    /// <summary>NOTIFYICONIDENTIFIER.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct IconIdentifier
    {
        public uint Size;
        public IntPtr Window;
        public uint ID;
        public Guid Item;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [LibraryImport("shell32.dll", EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

    [LibraryImport("shell32.dll")]
    private static partial int Shell_NotifyIconGetRect(ref IconIdentifier identifier, out Rect location);

    [LibraryImport("user32.dll", EntryPoint = "RegisterClassExW")]
    private static partial ushort RegisterClassEx(ref WindowClass windowClass);

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial IntPtr CreateWindowEx(
        uint extendedStyle, string className, string title, uint style, int x, int y, int width, int height,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr window);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessage(IntPtr window, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW")]
    private static partial nint DefWindowProc(IntPtr window, uint message, nint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "RegisterWindowMessageW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint RegisterWindowMessage(string name);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ChangeWindowMessageFilterEx(IntPtr window, uint message, uint action, IntPtr status);

    [LibraryImport("user32.dll", EntryPoint = "LoadImageW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyIcon(IntPtr icon);

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetricsForDpi(int index, uint dpi);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW")]
    private static partial IntPtr GetModuleHandle(IntPtr name);
}
